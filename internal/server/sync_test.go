package server

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
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
