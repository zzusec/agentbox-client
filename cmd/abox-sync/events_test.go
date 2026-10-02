package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"agentbox/internal/syncclient"
)

type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) events(kind string) []map[string]any {
	b.mu.Lock()
	defer b.mu.Unlock()
	var out []map[string]any
	for _, line := range strings.Split(b.buf.String(), "\n") {
		var event map[string]any
		if json.Unmarshal([]byte(line), &event) == nil && event["type"] == kind {
			out = append(out, event)
		}
	}
	return out
}

func testReporter() (*reporter, *lockedBuffer) {
	out := &lockedBuffer{}
	r := newReporter(true)
	r.out = out
	return r, out
}

func TestReporterOnlyRepeatsAnUnchangedVerdictOnTheHeartbeat(t *testing.T) {
	r, out := testReporter()
	project := syncclient.Project{ID: "p1", Name: "demo"}
	ok := syncclient.SyncResult{InSync: true}

	r.status(project, ok, nil)
	r.status(project, ok, nil)
	if got := len(out.events("status")); got != 1 {
		t.Fatalf("identical verdicts emitted %d events, want 1", got)
	}
	r.status(project, syncclient.SyncResult{InSync: true, Actions: 2}, nil)
	if got := len(out.events("status")); got != 2 {
		t.Fatalf("applied work was not reported: %d events", got)
	}
	r.status(project, syncclient.SyncResult{}, errors.New("boom"))
	statuses := out.events("status")
	if len(statuses) != 3 || statuses[2]["in_sync"] != false || statuses[2]["error"] != "boom" {
		t.Fatalf("error verdict = %+v", statuses)
	}

	// Past the heartbeat an unchanged verdict goes out again.
	r.mu.Lock()
	memo := r.statuses["p1"]
	memo.at = time.Now().Add(-statusHeartbeat)
	r.statuses["p1"] = memo
	r.mu.Unlock()
	r.status(project, syncclient.SyncResult{}, errors.New("boom"))
	if got := len(out.events("status")); got != 4 {
		t.Fatalf("heartbeat not emitted: %d events", got)
	}
}

// dirAPI serves one project, "demo", out of a directory: enough of the API
// for syncOnce to run a real pass.
func dirAPI(t *testing.T, remote string) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/sessions/s1/projects", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode([]syncclient.Project{{ID: "p1", Name: "demo"}})
	})
	mux.HandleFunc("GET /api/sync/projects/p1/manifest", func(w http.ResponseWriter, r *http.Request) {
		manifest, _ := syncclient.BuildLocalManifest(remote)
		_ = json.NewEncoder(w).Encode(manifest)
	})
	mux.HandleFunc("POST /api/sync/projects/p1/lease", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(syncclient.Lease{LeaseID: "l", DeviceID: "dev"})
	})
	mux.HandleFunc("DELETE /api/sync/projects/p1/lease", func(w http.ResponseWriter, r *http.Request) {})
	mux.HandleFunc("GET /api/sync/projects/p1/file", func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, filepath.Join(remote, r.URL.Query().Get("path")))
	})
	mux.HandleFunc("PUT /api/sync/projects/p1/file", func(w http.ResponseWriter, r *http.Request) {
		target := filepath.Join(remote, r.URL.Query().Get("path"))
		if r.Header.Get("X-Agentbox-Kind") == "dir" {
			_ = os.MkdirAll(target, 0o755)
			return
		}
		raw, _ := io.ReadAll(r.Body)
		_ = os.WriteFile(target, raw, 0o644)
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	return server
}

func TestSyncOnceStreamsEventsForTheClient(t *testing.T) {
	remote := t.TempDir()
	if err := os.WriteFile(filepath.Join(remote, "big.bin"), bytes.Repeat([]byte("z"), 512<<10), 0o644); err != nil {
		t.Fatal(err)
	}
	server := dirAPI(t, remote)
	cfg := config{Server: server.URL, Token: "t", SessionID: "s1", LocalRoot: t.TempDir()}
	client, err := syncclient.NewClient(cfg.Server, cfg.Token)
	if err != nil {
		t.Fatal(err)
	}
	engine := &syncclient.Engine{Client: client, DeviceID: "dev", DeviceName: "test"}
	report, out := testReporter()

	if err := syncOnce(context.Background(), client, engine, report, cfg, "", false); err != nil {
		t.Fatal(err)
	}
	transfers := out.events("transfer")
	if len(transfers) != 1 || transfers[0]["path"] != "big.bin" || transfers[0]["phase"] != "download" ||
		transfers[0]["bytes"] != float64(512<<10) {
		t.Fatalf("transfers = %+v", transfers)
	}
	if _, ok := transfers[0]["duration_ms"]; !ok {
		t.Fatal("transfer has no duration")
	}
	progress := out.events("progress")
	if len(progress) < 2 || progress[len(progress)-1]["percent"] != float64(100) {
		t.Fatalf("progress = %+v", progress)
	}
	statuses := out.events("status")
	if len(statuses) != 1 || statuses[0]["in_sync"] != true || statuses[0]["applied"] != float64(1) {
		t.Fatalf("statuses = %+v", statuses)
	}

	// Local edit goes up on the next pass and is reported as an upload.
	local := filepath.Join(cfg.LocalRoot, "demo", "note.txt")
	if err := os.WriteFile(local, []byte("from the mac"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := syncOnce(context.Background(), client, engine, report, cfg, "", false); err != nil {
		t.Fatal(err)
	}
	if raw, _ := os.ReadFile(filepath.Join(remote, "note.txt")); string(raw) != "from the mac" {
		t.Fatalf("upload did not land: %q", raw)
	}
	last := out.events("transfer")
	if got := last[len(last)-1]; got["path"] != "note.txt" || got["phase"] != "upload" {
		t.Fatalf("last transfer = %+v", got)
	}
}
