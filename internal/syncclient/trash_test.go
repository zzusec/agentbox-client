package syncclient

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func trashTestEngine(t *testing.T, serverURL string) *Engine {
	t.Helper()
	client, err := NewClient(serverURL, "synthetic-token")
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	return &Engine{Client: client, DeviceID: "device-1", DeviceName: "fake"}
}

func trashTestTarget(stateRoot string) ProjectTarget {
	return ProjectTarget{
		Project:   Project{ID: "p1", Name: "demo"},
		LocalDir:  filepath.Join(stateRoot, "demo"),
		StateRoot: stateRoot,
	}
}

// An agent deleting a file on the server must not cost the user their local
// copy: the pass still mirrors the deletion, but into the trash.
func TestRemoteDeletionGoesToTheTrash(t *testing.T) {
	fake, server := newFakeSyncServer(t, "p1", map[string]string{
		"keep.txt": "keep",
		"draft.md": "precious",
	})
	stateRoot := t.TempDir()
	engine := trashTestEngine(t, server.URL)
	target := trashTestTarget(stateRoot)
	if _, err := engine.SyncProject(context.Background(), target); err != nil {
		t.Fatalf("bootstrap: %v", err)
	}

	fake.mu.Lock()
	delete(fake.files, "draft.md")
	fake.mu.Unlock()
	result, err := engine.SyncProject(context.Background(), target)
	if err != nil {
		t.Fatalf("sync: %v", err)
	}
	if result.DeletedLocal != 1 || result.TrashDir == "" || !result.InSync {
		t.Fatalf("result = %+v", result)
	}
	if _, err := os.Stat(filepath.Join(stateRoot, "demo", "draft.md")); !os.IsNotExist(err) {
		t.Fatalf("file still in the project: %v", err)
	}
	rescued, err := os.ReadFile(filepath.Join(result.TrashDir, "draft.md"))
	if err != nil || string(rescued) != "precious" {
		t.Fatalf("trash copy = %q, %v", rescued, err)
	}
	if rel, _ := filepath.Rel(stateDir(stateRoot), result.TrashDir); strings.HasPrefix(rel, "..") {
		t.Fatalf("trash %s escaped the state directory", result.TrashDir)
	}
	// A rescued file must never come back as a new upload.
	if again, err := engine.SyncProject(context.Background(), target); err != nil || again.Actions != 0 {
		t.Fatalf("follow-up pass = %+v, %v", again, err)
	}
}

func TestMassRemoteDeletionPausesTheProject(t *testing.T) {
	files := map[string]string{}
	for _, name := range []string{"a", "b", "c", "d", "e", "f"} {
		files[name+".txt"] = name
	}
	fake, server := newFakeSyncServer(t, "p1", files)
	stateRoot := t.TempDir()
	engine := trashTestEngine(t, server.URL)
	target := trashTestTarget(stateRoot)
	if _, err := engine.SyncProject(context.Background(), target); err != nil {
		t.Fatalf("bootstrap: %v", err)
	}

	// `rm -rf *` in the container.
	fake.mu.Lock()
	fake.files = map[string][]byte{}
	fake.mu.Unlock()
	_, err := engine.SyncProject(context.Background(), target)
	var bulk *BulkDeleteError
	if !errors.As(err, &bulk) || bulk.Side != "local" || bulk.Deletes != 6 {
		t.Fatalf("err = %v", err)
	}
	if readLocal(t, stateRoot, "a.txt") != "a" {
		t.Fatal("local copy was touched")
	}

	// Recovery: "local wins" puts the wiped server back from the Mac.
	restore := target
	restore.ForcePolicy = "local"
	if _, err := engine.SyncProject(context.Background(), restore); err != nil {
		t.Fatalf("restore pass: %v", err)
	}
	if body, ok := fake.contents("f.txt"); !ok || body != "f" {
		t.Fatalf("server not restored: %q %v", body, ok)
	}

	// Someone who really meant it can opt out; the copies still land in the
	// trash rather than being removed.
	fake.mu.Lock()
	fake.files = map[string][]byte{}
	fake.mu.Unlock()
	engine.AllowBulkDelete = true
	result, err := engine.SyncProject(context.Background(), target)
	if err != nil {
		t.Fatalf("allowed pass: %v", err)
	}
	if result.DeletedLocal != 6 {
		t.Fatalf("allowed result = %+v", result)
	}
	if body, _ := os.ReadFile(filepath.Join(result.TrashDir, "f.txt")); string(body) != "f" {
		t.Fatalf("allowed delete lost the trash copy: %q", body)
	}
}

func TestMassLocalDeletionPausesTheProject(t *testing.T) {
	files := map[string]string{}
	for _, name := range []string{"a", "b", "c", "d", "e"} {
		files[name+".txt"] = name
	}
	fake, server := newFakeSyncServer(t, "p1", files)
	stateRoot := t.TempDir()
	engine := trashTestEngine(t, server.URL)
	target := trashTestTarget(stateRoot)
	if _, err := engine.SyncProject(context.Background(), target); err != nil {
		t.Fatalf("bootstrap: %v", err)
	}
	local := filepath.Join(stateRoot, "demo")
	if err := os.RemoveAll(local); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(local, 0o755); err != nil {
		t.Fatal(err)
	}
	_, err := engine.SyncProject(context.Background(), target)
	var bulk *BulkDeleteError
	if !errors.As(err, &bulk) || bulk.Side != "remote" {
		t.Fatalf("err = %v", err)
	}
	if _, deletes := fake.counters(); deletes != 0 {
		t.Fatalf("server saw %d deletes", deletes)
	}
}

func TestSmallDeletionsAreNotGuarded(t *testing.T) {
	fake, server := newFakeSyncServer(t, "p1", map[string]string{"a.txt": "a", "b.txt": "b"})
	stateRoot := t.TempDir()
	engine := trashTestEngine(t, server.URL)
	target := trashTestTarget(stateRoot)
	if _, err := engine.SyncProject(context.Background(), target); err != nil {
		t.Fatalf("bootstrap: %v", err)
	}
	fake.mu.Lock()
	delete(fake.files, "a.txt")
	fake.mu.Unlock()
	// Half the project, but below the minimum batch the guard looks at.
	result, err := engine.SyncProject(context.Background(), target)
	if err != nil || result.DeletedLocal != 1 {
		t.Fatalf("result = %+v err = %v", result, err)
	}
}

// A proxy that rewrites HTML in transit (Cloudflare's analytics injection)
// must not get its version written to disk — and, crucially, must not leave a
// local copy that a later merge would push back to the server.
func TestTamperedDownloadIsRejected(t *testing.T) {
	fake, server := newFakeSyncServer(t, "p1", map[string]string{
		"index.html": "<html><body>hi</body></html>",
	})
	// Forwards to the fake server and appends a script to file bodies, the
	// way an analytics-injecting CDN rewrites text/html.
	tamper := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		proxied := r.Clone(r.Context())
		proxied.URL.Scheme, proxied.URL.Host, proxied.RequestURI = "http", strings.TrimPrefix(server.URL, "http://"), ""
		resp, err := http.DefaultTransport.RoundTrip(proxied)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()
		raw, _ := io.ReadAll(resp.Body)
		out := string(raw)
		if strings.HasSuffix(r.URL.Path, "/file") {
			out = strings.Replace(out, "</body>", `<script src="https://beacon.example/b.js"></script></body>`, 1)
		}
		w.WriteHeader(resp.StatusCode)
		_, _ = w.Write([]byte(out))
	}))
	t.Cleanup(tamper.Close)

	stateRoot := t.TempDir()
	engine := trashTestEngine(t, tamper.URL)
	_, err := engine.SyncProject(context.Background(), trashTestTarget(stateRoot))
	var mismatch *DownloadMismatchError
	if !errors.As(err, &mismatch) || mismatch.Path != "index.html" {
		t.Fatalf("err = %v", err)
	}
	if _, err := os.Stat(filepath.Join(stateRoot, "demo", "index.html")); !os.IsNotExist(err) {
		t.Fatalf("tampered file reached the disk: %v", err)
	}
	if uploads, _ := fake.counters(); uploads != 0 {
		t.Fatalf("server received %d uploads", uploads)
	}
}

func TestLocalManifestCacheFollowsEdits(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("one"), 0o644); err != nil {
		t.Fatal(err)
	}
	engine := &Engine{}
	first, err := engine.localManifest(dir)
	if err != nil {
		t.Fatal(err)
	}
	again, err := engine.localManifest(dir)
	if err != nil || again.Revision != first.Revision {
		t.Fatalf("unchanged tree gave a different manifest: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("two!"), 0o644); err != nil {
		t.Fatal(err)
	}
	edited, err := engine.localManifest(dir)
	if err != nil || edited.Revision == first.Revision {
		t.Fatalf("edit was hidden by the cache: %v", err)
	}
}

func TestQuickLocalRevisionIgnoresExcludes(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "main.go"), []byte("package main"), 0o644); err != nil {
		t.Fatal(err)
	}
	before, err := QuickLocalRevision(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "node_modules", "pkg"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "node_modules", "pkg", "index.js"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if after, _ := QuickLocalRevision(root); after != before {
		t.Fatal("an excluded directory changed the revision")
	}
	if missing, err := QuickLocalRevision(filepath.Join(root, "absent")); err != nil || missing != "" {
		t.Fatalf("missing dir = %q, %v", missing, err)
	}
}
