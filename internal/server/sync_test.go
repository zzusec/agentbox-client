package server

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"agentbox/internal/store"
)

func syncTestProject(t *testing.T, s *Server, sess store.Session) store.SyncProject {
	t.Helper()
	if err := s.store.Put(sess); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(s.workspaceDir(sess), "alpha"), 0o755); err != nil {
		t.Fatal(err)
	}
	projects, err := s.store.ReconcileSyncProjects(sess.ID, s.workspaceDir(sess), []string{"alpha"})
	if err != nil {
		t.Fatal(err)
	}
	return projects[0]
}

func TestSyncManifestLeaseAndFile(t *testing.T) {
	s, sess := newTestServer(t)
	project := syncTestProject(t, s, sess)
	if err := os.WriteFile(
		filepath.Join(s.workspaceDir(sess), "alpha", "hello.txt"),
		[]byte("hello"),
		0o644,
	); err != nil {
		t.Fatal(err)
	}

	manifestReq := accessRequest(sess.User, http.MethodGet, "/manifest", "")
	manifestReq.SetPathValue("project", project.ID)
	manifestRecorder := httptest.NewRecorder()
	s.handleSyncManifest(manifestRecorder, manifestReq)
	if manifestRecorder.Code != http.StatusOK {
		t.Fatalf("manifest status = %d body=%s", manifestRecorder.Code, manifestRecorder.Body.String())
	}
	var manifest syncManifest
	if err := json.Unmarshal(manifestRecorder.Body.Bytes(), &manifest); err != nil {
		t.Fatal(err)
	}
	if len(manifest.Entries) != 1 || manifest.Entries[0].Path != "hello.txt" {
		t.Fatalf("manifest = %+v", manifest)
	}
	if manifest.Entries[0].SHA256 != "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" {
		t.Fatalf("sha = %s", manifest.Entries[0].SHA256)
	}

	leaseReq := accessRequest(
		sess.User,
		http.MethodPost,
		"/lease",
		`{"device_id":"mac-a","device_name":"Mac A"}`,
	)
	leaseReq.SetPathValue("project", project.ID)
	leaseRecorder := httptest.NewRecorder()
	s.handleSyncLease(leaseRecorder, leaseReq)
	if leaseRecorder.Code != http.StatusOK {
		t.Fatalf("lease status = %d body=%s", leaseRecorder.Code, leaseRecorder.Body.String())
	}
	var lease store.SyncLease
	if err := json.Unmarshal(leaseRecorder.Body.Bytes(), &lease); err != nil {
		t.Fatal(err)
	}

	putReq := accessRequest(sess.User, http.MethodPut, "/file?path=sub/new.txt", "new")
	putReq.SetPathValue("project", project.ID)
	putReq.Header.Set(syncLeaseHeader, lease.LeaseID)
	putReq.Header.Set(syncDeviceHeader, lease.DeviceID)
	putReq.Header.Set(syncFileModeHeader, "0755")
	putRecorder := httptest.NewRecorder()
	s.handleSyncFile(putRecorder, putReq)
	if putRecorder.Code != http.StatusOK {
		t.Fatalf("put status = %d body=%s", putRecorder.Code, putRecorder.Body.String())
	}
	info, err := os.Stat(filepath.Join(s.workspaceDir(sess), "alpha", "sub", "new.txt"))
	if err != nil || info.Mode().Perm() != 0o755 {
		t.Fatalf("uploaded file mode=%v err=%v", info, err)
	}

	getReq := accessRequest(sess.User, http.MethodGet, "/file?path=sub/new.txt", "")
	getReq.SetPathValue("project", project.ID)
	getRecorder := httptest.NewRecorder()
	s.handleSyncFile(getRecorder, getReq)
	if getRecorder.Code != http.StatusOK || getRecorder.Body.String() != "new" {
		t.Fatalf("get status=%d body=%q", getRecorder.Code, getRecorder.Body.String())
	}
}

func TestSyncLeaseRejectsSecondDeviceWrites(t *testing.T) {
	s, sess := newTestServer(t)
	project := syncTestProject(t, s, sess)
	first, ok, err := s.store.AcquireSyncLease(project.ID, "mac-a", "Mac A", syncLeaseTTL, time.Now())
	if err != nil || !ok {
		t.Fatalf("lease: %+v %v %v", first, ok, err)
	}
	req := accessRequest(sess.User, http.MethodPut, "/file?path=x.txt", "x")
	req.SetPathValue("project", project.ID)
	req.Header.Set(syncLeaseHeader, first.LeaseID)
	req.Header.Set(syncDeviceHeader, "mac-b")
	recorder := httptest.NewRecorder()
	s.handleSyncFile(recorder, req)
	if recorder.Code != http.StatusLocked {
		t.Fatalf("status = %d body=%s", recorder.Code, recorder.Body.String())
	}
	if bytes.Contains(recorder.Body.Bytes(), []byte("x")) {
		t.Fatal("unexpected write result")
	}
}

func TestSyncManifestIfRevisionAndCache(t *testing.T) {
	s, sess := newTestServer(t)
	project := syncTestProject(t, s, sess)
	if err := os.WriteFile(
		filepath.Join(s.workspaceDir(sess), "alpha", "hello.txt"),
		[]byte("hello"),
		0o644,
	); err != nil {
		t.Fatal(err)
	}

	fetch := func(ifRevision string) (*httptest.ResponseRecorder, syncManifest) {
		req := accessRequest(sess.User, http.MethodGet, "/manifest", "")
		req.SetPathValue("project", project.ID)
		if ifRevision != "" {
			req.Header.Set("X-Agentbox-If-Revision", ifRevision)
		}
		recorder := httptest.NewRecorder()
		s.handleSyncManifest(recorder, req)
		var manifest syncManifest
		_ = json.Unmarshal(recorder.Body.Bytes(), &manifest)
		return recorder, manifest
	}

	first, firstManifest := fetch("")
	if first.Code != http.StatusOK || firstManifest.Revision == "" {
		t.Fatalf("first manifest status=%d rev=%q", first.Code, firstManifest.Revision)
	}

	// Unchanged tree + matching If-Revision: a cheap 204 poll.
	notModified, _ := fetch(firstManifest.Revision)
	if notModified.Code != http.StatusNoContent {
		t.Fatalf("not modified status = %d body=%s", notModified.Code, notModified.Body.String())
	}

	// The tree changed: an old If-Revision must still return the new manifest.
	if err := os.WriteFile(
		filepath.Join(s.workspaceDir(sess), "alpha", "hello.txt"),
		[]byte("hello world"),
		0o644,
	); err != nil {
		t.Fatal(err)
	}
	changed, changedManifest := fetch(firstManifest.Revision)
	if changed.Code != http.StatusOK || changedManifest.Revision == firstManifest.Revision {
		t.Fatalf("changed manifest status=%d rev=%q", changed.Code, changedManifest.Revision)
	}

	// And the fresh revision hits the cached fast path again.
	second, _ := fetch(changedManifest.Revision)
	if second.Code != http.StatusNoContent {
		t.Fatalf("second not modified status = %d body=%s", second.Code, second.Body.String())
	}
}

// A CDN that rewrites text/html (Cloudflare's analytics injection) corrupted
// synced .html files. Sync downloads must be opaque and marked no-transform.
func TestSyncFileDownloadIsOpaque(t *testing.T) {
	s, sess := newTestServer(t)
	project := syncTestProject(t, s, sess)
	page := "<html><body>hi</body></html>"
	if err := os.WriteFile(filepath.Join(s.workspaceDir(sess), "alpha", "index.html"), []byte(page), 0o644); err != nil {
		t.Fatal(err)
	}
	req := accessRequest(sess.User, http.MethodGet, "/file?path=index.html", "")
	req.SetPathValue("project", project.ID)
	rec := httptest.NewRecorder()
	s.handleSyncFile(rec, req)
	if rec.Code != http.StatusOK || rec.Body.String() != page {
		t.Fatalf("status=%d body=%q", rec.Code, rec.Body.String())
	}
	if got := rec.Header().Get("Content-Type"); got != "application/octet-stream" {
		t.Fatalf("content-type = %q", got)
	}
	if got := rec.Header().Get("Cache-Control"); !strings.Contains(got, "no-transform") {
		t.Fatalf("cache-control = %q", got)
	}
}

// TestSyncDirectoryKeepsItsModeUnderAUmask pins the fix for a sync that never
// settled: the unit runs with UMask=0077, MkdirAll applies it, so a directory
// uploaded as 0755 landed as 0700. The manifest then reported 0700, the client
// saw a difference no transfer could fix, and the project's whole directory
// tree was re-uploaded on every pass.
func TestSyncDirectoryKeepsItsModeUnderAUmask(t *testing.T) {
	old := syscall.Umask(0o077)
	defer syscall.Umask(old)

	s, sess := newTestServer(t)
	project := syncTestProject(t, s, sess)
	leaseReq := accessRequest(sess.User, http.MethodPost, "/lease", `{"device_id":"mac-a","device_name":"Mac A"}`)
	leaseReq.SetPathValue("project", project.ID)
	leaseRecorder := httptest.NewRecorder()
	s.handleSyncLease(leaseRecorder, leaseReq)
	if leaseRecorder.Code != http.StatusOK {
		t.Fatalf("lease status = %d body=%s", leaseRecorder.Code, leaseRecorder.Body.String())
	}
	var lease store.SyncLease
	if err := json.Unmarshal(leaseRecorder.Body.Bytes(), &lease); err != nil {
		t.Fatal(err)
	}

	putReq := accessRequest(sess.User, http.MethodPut, "/file?path=sub/deep", "")
	putReq.SetPathValue("project", project.ID)
	putReq.Header.Set(syncLeaseHeader, lease.LeaseID)
	putReq.Header.Set(syncDeviceHeader, lease.DeviceID)
	putReq.Header.Set(syncKindHeader, "dir")
	putReq.Header.Set(syncFileModeHeader, "0755")
	putRecorder := httptest.NewRecorder()
	s.handleSyncFile(putRecorder, putReq)
	if putRecorder.Code != http.StatusOK {
		t.Fatalf("put status = %d body=%s", putRecorder.Code, putRecorder.Body.String())
	}

	info, err := os.Stat(filepath.Join(s.workspaceDir(sess), "alpha", "sub", "deep"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o755 {
		t.Fatalf("directory mode = %v, want 0755 (the umask must not strip it)", info.Mode().Perm())
	}

	// And the manifest has to report the same mode back, since that is what the
	// client compares against.
	manifestReq := accessRequest(sess.User, http.MethodGet, "/manifest", "")
	manifestReq.SetPathValue("project", project.ID)
	manifestRecorder := httptest.NewRecorder()
	s.handleSyncManifest(manifestRecorder, manifestReq)
	var manifest syncManifest
	if err := json.Unmarshal(manifestRecorder.Body.Bytes(), &manifest); err != nil {
		t.Fatal(err)
	}
	for _, entry := range manifest.Entries {
		if entry.Path == "sub/deep" && entry.Mode != 0o755 {
			t.Fatalf("manifest reports %o for the directory, want 755", entry.Mode)
		}
	}
}
