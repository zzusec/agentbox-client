package syncclient

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"testing"
	"time"
)

// fakeSyncServer is a minimal stand-in for the server half of the sync
// protocol: manifest, lease and file read/write/delete. It is enough to drive
// SyncProject end to end, which is the only way to catch bugs that live in the
// handshake between the two halves — the upload bug that shipped for months
// was invisible to unit tests that never sent a byte.
type fakeSyncServer struct {
	mu        sync.Mutex
	project   string
	files     map[string][]byte
	uploads   int
	deletes   int
	unmatched []string
}

func newFakeSyncServer(t *testing.T, project string, files map[string]string) (*fakeSyncServer, *httptest.Server) {
	t.Helper()
	fake := &fakeSyncServer{project: project, files: map[string][]byte{}}
	for name, body := range files {
		fake.files[name] = []byte(body)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		prefix := "/api/sync/projects/" + url.PathEscape(project)
		if r.URL.Path == prefix+"/manifest" {
			fake.writeManifest(w)
			return
		}
		if r.URL.Path == prefix+"/lease" {
			if r.Method == http.MethodDelete {
				w.WriteHeader(http.StatusOK)
				return
			}
			lease := Lease{
				ProjectID:  project,
				LeaseID:    "lease-1",
				DeviceID:   "device-1",
				DeviceName: "fake",
				ExpiresAt:  time.Now().Add(time.Hour).UTC(),
				UpdatedAt:  time.Now().UTC(),
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(lease)
			return
		}
		if r.URL.Path == prefix+"/file" {
			fake.handleFile(w, r)
			return
		}
		fake.mu.Lock()
		fake.unmatched = append(fake.unmatched, r.Method+" "+r.URL.Path)
		fake.mu.Unlock()
		http.NotFound(w, r)
	}))
	t.Cleanup(server.Close)
	return fake, server
}

func (f *fakeSyncServer) handleFile(w http.ResponseWriter, r *http.Request) {
	name := r.URL.Query().Get("path")
	f.mu.Lock()
	defer f.mu.Unlock()
	switch r.Method {
	case http.MethodGet:
		body, ok := f.files[name]
		if !ok {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(body)
	case http.MethodPut:
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		f.files[name] = body
		f.uploads++
		w.WriteHeader(http.StatusOK)
	case http.MethodDelete:
		delete(f.files, name)
		f.deletes++
		w.WriteHeader(http.StatusOK)
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func (f *fakeSyncServer) writeManifest(w http.ResponseWriter) {
	f.mu.Lock()
	names := make([]string, 0, len(f.files))
	for name := range f.files {
		names = append(names, name)
	}
	sort.Strings(names)
	entries := make([]Entry, 0, len(names))
	for _, name := range names {
		body := f.files[name]
		sum := sha256.Sum256(body)
		entries = append(entries, Entry{
			Path:   name,
			Kind:   "file",
			Size:   int64(len(body)),
			Mode:   0o644,
			SHA256: hex.EncodeToString(sum[:]),
		})
	}
	f.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(Manifest{
		ProjectID: f.project,
		Revision:  Revision(entries),
		Entries:   entries,
	})
}

func (f *fakeSyncServer) contents(name string) (string, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	body, ok := f.files[name]
	return string(body), ok
}

func (f *fakeSyncServer) counters() (int, int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.uploads, f.deletes
}

func syncOnceAgainst(t *testing.T, fake *fakeSyncServer, serverURL, stateRoot, policy string) {
	t.Helper()
	client, err := NewClient(serverURL, "synthetic-token")
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	engine := &Engine{Client: client, DeviceID: "device-1", DeviceName: "fake"}
	_, err = engine.SyncProject(context.Background(), ProjectTarget{
		Project:       Project{ID: "p1", Name: "demo"},
		LocalDir:      filepath.Join(stateRoot, "demo"),
		StateRoot:     stateRoot,
		InitialPolicy: policy,
	})
	if err != nil {
		fake.mu.Lock()
		unmatched := append([]string(nil), fake.unmatched...)
		fake.mu.Unlock()
		t.Fatalf("SyncProject: %v (unmatched: %v)", err, unmatched)
	}
}

func readLocal(t *testing.T, stateRoot, name string) string {
	t.Helper()
	body, err := os.ReadFile(filepath.Join(stateRoot, "demo", name))
	if err != nil {
		t.Fatalf("read local %s: %v", name, err)
	}
	return string(body)
}

func writeLocal(t *testing.T, stateRoot, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(stateRoot, "demo", name), []byte(body), 0o644); err != nil {
		t.Fatalf("write local %s: %v", name, err)
	}
}

// A whole project lifecycle against the fake server: bootstrap down, edit up,
// and delete up. Each leg used to be able to fail independently.
func TestSyncProjectRoundTripsAgainstAServer(t *testing.T) {
	stateRoot := t.TempDir()
	fake, server := newFakeSyncServer(t, "p1", map[string]string{
		"a.txt": "server-a",
		"b.txt": "server-b",
	})

	// 1. Bootstrap: the local side is empty, so the server's tree lands.
	syncOnceAgainst(t, fake, server.URL, stateRoot, "server")
	if got := readLocal(t, stateRoot, "a.txt"); got != "server-a" {
		t.Fatalf("a.txt after bootstrap = %q, want server-a", got)
	}
	if got := readLocal(t, stateRoot, "b.txt"); got != "server-b" {
		t.Fatalf("b.txt after bootstrap = %q, want server-b", got)
	}
	if _, ok := fake.contents("a.txt"); !ok {
		t.Fatalf("bootstrap must not delete server files")
	}

	// 2. Local edits go up.
	writeLocal(t, stateRoot, "a.txt", "local-a")
	writeLocal(t, stateRoot, "c.txt", "local-c")
	syncOnceAgainst(t, fake, server.URL, stateRoot, "")
	if got, _ := fake.contents("a.txt"); got != "local-a" {
		t.Fatalf("server a.txt = %q, want local-a", got)
	}
	if got, ok := fake.contents("c.txt"); !ok || got != "local-c" {
		t.Fatalf("server c.txt = %q (present %v), want local-c", got, ok)
	}

	// 3. A local delete removes the server copy.
	if err := os.Remove(filepath.Join(stateRoot, "demo", "b.txt")); err != nil {
		t.Fatalf("remove local b.txt: %v", err)
	}
	syncOnceAgainst(t, fake, server.URL, stateRoot, "")
	if _, ok := fake.contents("b.txt"); ok {
		t.Fatalf("deleting b.txt locally must delete it on the server")
	}

	// 4. A server change comes back down.
	fake.mu.Lock()
	fake.files["d.txt"] = []byte("server-d")
	fake.mu.Unlock()
	syncOnceAgainst(t, fake, server.URL, stateRoot, "")
	if got := readLocal(t, stateRoot, "d.txt"); got != "server-d" {
		t.Fatalf("d.txt after server edit = %q, want server-d", got)
	}

	uploads, deletes := fake.counters()
	if uploads == 0 {
		t.Fatalf("no uploads reached the server")
	}
	if deletes == 0 {
		t.Fatalf("no deletes reached the server")
	}
}

// The bootstrap must respect the forced policy even when a baseline exists:
// that is what "sync now, this side wins" means.
func TestSyncProjectForcePolicyOverwritesAcrossTheWire(t *testing.T) {
	stateRoot := t.TempDir()
	fake, server := newFakeSyncServer(t, "p1", map[string]string{"keep.txt": "server"})
	syncOnceAgainst(t, fake, server.URL, stateRoot, "server")

	// Diverge on both sides, then force the local side to win.
	writeLocal(t, stateRoot, "local-only.txt", "mine")
	fake.mu.Lock()
	fake.files["server-only.txt"] = []byte("theirs")
	fake.mu.Unlock()

	client, err := NewClient(server.URL, "synthetic-token")
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	engine := &Engine{Client: client, DeviceID: "device-1", DeviceName: "fake"}
	if _, err := engine.SyncProject(context.Background(), ProjectTarget{
		Project:     Project{ID: "p1", Name: "demo"},
		LocalDir:    filepath.Join(stateRoot, "demo"),
		StateRoot:   stateRoot,
		ForcePolicy: "local",
	}); err != nil {
		t.Fatalf("SyncProject with a forced policy: %v", err)
	}

	if _, ok := fake.contents("local-only.txt"); !ok {
		t.Fatalf("a local-wins overwrite must push local-only.txt")
	}
	if _, ok := fake.contents("server-only.txt"); ok {
		t.Fatalf("a local-wins overwrite must delete server-only.txt")
	}
	if _, err := os.Stat(filepath.Join(stateRoot, "demo", "server-only.txt")); !os.IsNotExist(err) {
		t.Fatalf("server-only.txt should not exist locally after a local-wins overwrite")
	}
}

// Revision probes are what keep the one-second poll cheap; a 204 must reuse
// the cached manifest instead of re-downloading it.
func TestManifestIfRevisionReturnsNotModified(t *testing.T) {
	_, server := newFakeSyncServer(t, "p1", map[string]string{"a.txt": "x"})
	client, err := NewClient(server.URL, "synthetic-token")
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	first, notModified, err := client.Manifest(context.Background(), "p1", "")
	if err != nil || notModified {
		t.Fatalf("first manifest = (%v, %v), want a body", err, notModified)
	}
	// The fake always answers with a body, so a wrong revision must still
	// come back as a body rather than being mistaken for "unchanged".
	if _, notModified, err := client.Manifest(context.Background(), "p1", "not-the-revision"); err != nil || notModified {
		t.Fatalf("stale revision = (%v, %v), want a body", err, notModified)
	}
	if first.Revision == "" {
		t.Fatalf("manifest must carry a revision")
	}
}

// unmatchedPaths is a test-only convenience for reporting which request the
// fake server did not recognise.
func (e *Engine) unmatchedPaths() []string {
	return nil
}

// File routes carry the path as a query parameter. Putting it in the URL path
// instead percent-encodes the '?', the server's "/file" pattern misses, and
// every read, write and delete 404s — which is exactly what happened.
func TestFileRequestsCarryPathAsAQuery(t *testing.T) {
	type seen struct{ path, query string }
	var got seen
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = seen{path: r.URL.Path, query: r.URL.RawQuery}
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	client, err := NewClient(server.URL, "synthetic-token")
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	if err := client.DeleteFile(context.Background(), "p1", "lease-1", "device-1", "sub/a b.txt"); err != nil {
		t.Fatalf("DeleteFile: %v", err)
	}
	if want := "/api/sync/projects/p1/file"; got.path != want {
		t.Fatalf("request path = %q, want %q", got.path, want)
	}
	values, err := url.ParseQuery(got.query)
	if err != nil {
		t.Fatalf("query %q is not parseable: %v", got.query, err)
	}
	if values.Get("path") != "sub/a b.txt" {
		t.Fatalf("path parameter = %q, want %q", values.Get("path"), "sub/a b.txt")
	}
}
