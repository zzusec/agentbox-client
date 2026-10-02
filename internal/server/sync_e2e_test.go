package server

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"agentbox/internal/store"
	"agentbox/internal/syncclient"
)

// syncTestHTTP serves the real sync routes with a fixed request user, so the
// real client can be driven against the real handlers. Bugs in the handshake
// between the two halves (a query escaped into the path, a content type a
// CDN rewrites) are invisible to unit tests of either side alone.
func syncTestHTTP(t *testing.T, s *Server, sess store.Session) *syncclient.Client {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/sync/projects/{project}/manifest", s.handleSyncManifest)
	mux.HandleFunc("POST /api/sync/projects/{project}/lease", s.handleSyncLease)
	mux.HandleFunc("DELETE /api/sync/projects/{project}/lease", s.handleSyncLease)
	mux.HandleFunc("GET /api/sync/projects/{project}/file", s.handleSyncFile)
	mux.HandleFunc("PUT /api/sync/projects/{project}/file", s.handleSyncFile)
	mux.HandleFunc("DELETE /api/sync/projects/{project}/file", s.handleSyncFile)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user := store.User{Name: sess.User, Role: store.RoleUser}
		mux.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ctxUser, user)))
	}))
	t.Cleanup(server.Close)
	client, err := syncclient.NewClient(server.URL, "token")
	if err != nil {
		t.Fatal(err)
	}
	return client
}

func TestSyncClientAgainstRealHandlers(t *testing.T) {
	s, sess := newTestServer(t)
	project := syncTestProject(t, s, sess)
	client := syncTestHTTP(t, s, sess)
	remote := filepath.Join(s.workspaceDir(sess), "alpha")
	stateRoot := t.TempDir()
	local := filepath.Join(stateRoot, "alpha")

	write := func(path, body string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	read := func(path string) string {
		t.Helper()
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		return string(raw)
	}

	var transfers []syncclient.Transfer
	var lastProgress syncclient.Progress
	engine := &syncclient.Engine{
		Client: client, DeviceID: "mac", DeviceName: "Mac",
		OnTransfer: func(tr syncclient.Transfer) { transfers = append(transfers, tr) },
		OnProgress: func(p syncclient.Progress) { lastProgress = p },
	}
	target := syncclient.ProjectTarget{
		Project:   syncclient.Project{ID: project.ID, Name: project.Name},
		LocalDir:  local,
		StateRoot: stateRoot,
	}
	sync := func() syncclient.SyncResult {
		t.Helper()
		result, err := engine.SyncProject(context.Background(), target)
		if err != nil {
			t.Fatal(err)
		}
		if !result.InSync {
			t.Fatalf("pass ended out of sync: %+v", result)
		}
		return result
	}

	// Server -> local: a nested path that needs query escaping, an HTML page
	// (the type a CDN likes to rewrite) and a file large enough to tick.
	write(filepath.Join(remote, "src", "main file.go"), "package main")
	write(filepath.Join(remote, "site", "index.html"), "<html><body>hi</body></html>")
	write(filepath.Join(remote, "big.bin"), strings.Repeat("z", 256<<10))
	sync()
	if read(filepath.Join(local, "src", "main file.go")) != "package main" {
		t.Fatal("download content mismatch")
	}
	if read(filepath.Join(local, "site", "index.html")) != "<html><body>hi</body></html>" {
		t.Fatal("html did not round-trip byte for byte")
	}
	if lastProgress.Phase != syncclient.PhaseDone || lastProgress.Percent != 100 {
		t.Fatalf("last progress = %+v", lastProgress)
	}

	// Local -> server.
	transfers = nil
	write(filepath.Join(local, "notes.md"), "from the mac")
	sync()
	if read(filepath.Join(remote, "notes.md")) != "from the mac" {
		t.Fatal("upload content mismatch")
	}
	if len(transfers) != 1 || transfers[0].Phase != syncclient.PhaseUpload || transfers[0].Path != "notes.md" {
		t.Fatalf("transfers = %+v", transfers)
	}

	// The agent deletes one file: the local copy is rescued into the trash.
	if err := os.Remove(filepath.Join(remote, "notes.md")); err != nil {
		t.Fatal(err)
	}
	result := sync()
	if result.DeletedLocal != 1 || read(filepath.Join(result.TrashDir, "notes.md")) != "from the mac" {
		t.Fatalf("trash result = %+v", result)
	}

	// The agent wipes the project: the pass refuses instead of following.
	for i := 0; i < 6; i++ {
		write(filepath.Join(remote, "gen", string(rune('a'+i))+".txt"), "x")
	}
	sync()
	entries, _ := os.ReadDir(remote)
	for _, entry := range entries {
		_ = os.RemoveAll(filepath.Join(remote, entry.Name()))
	}
	_, err := engine.SyncProject(context.Background(), target)
	var bulk *syncclient.BulkDeleteError
	if !errors.As(err, &bulk) || bulk.Side != "local" {
		t.Fatalf("wipe err = %v", err)
	}
	if read(filepath.Join(local, "src", "main file.go")) != "package main" {
		t.Fatal("local copy was touched after the server was wiped")
	}
}
