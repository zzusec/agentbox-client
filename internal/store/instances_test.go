package store

import (
	"path/filepath"
	"testing"
	"time"
)

// instanceColumns are the additive columns v11 introduced. Every one of them
// has a benign default so a v11 database stays readable by anything that only
// knows the older columns.
var instanceColumns = []struct{ table, name string }{
	{"sessions", "claude_account_id"},
	{"sessions", "codex_account_id"},
	{"sessions", "proxy_id"},
	{"sessions", "default_model_claude"},
	{"sessions", "default_model_codex"},
	{"sync_projects", "agent"},
	{"sync_projects", "path"},
}

func TestInstanceMigrationV11AddsColumns(t *testing.T) {
	st, err := Open(filepath.Join(t.TempDir(), "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	for _, c := range instanceColumns {
		var found int
		if err := st.db.QueryRow("SELECT COUNT(*) FROM pragma_table_info(?) WHERE name=?", c.table, c.name).Scan(&found); err != nil {
			t.Fatal(err)
		}
		if found != 1 {
			t.Fatalf("column %s.%s missing after migration", c.table, c.name)
		}
	}
}

// Re-running on an already-migrated database must be a no-op rather than an
// "duplicate column name" error. This is the case that matters if someone
// hand-edits user_version: the migration guards on pragma_table_info instead
// of trusting the version number alone.
func TestInstanceMigrationV11IsIdempotent(t *testing.T) {
	st, err := Open(filepath.Join(t.TempDir(), "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	// A second pass plus a value we must not clobber.
	if _, err := st.db.Exec("UPDATE sessions SET proxy_id='p1' WHERE 1=0"); err != nil {
		t.Fatal(err)
	}
	if err := migrate(st.db); err != nil {
		t.Fatalf("second migration pass: %v", err)
	}
}

func TestSessionRoundTripsInstanceFields(t *testing.T) {
	st, err := Open(filepath.Join(t.TempDir(), "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	want := Session{
		ID: "s1", User: "alice", Name: "box", Agent: "claude",
		AccountID: "acct-1", ClaudeAccountID: "claude-1", CodexAccountID: "codex-1",
		ProxyID: "p1", DefaultModel: "m", DefaultModelClaude: "mc", DefaultModelCodex: "mx",
		Status: StatusStopped,
	}
	if err := st.Put(want); err != nil {
		t.Fatal(err)
	}
	got, ok := st.Get("s1")
	if !ok {
		t.Fatal("session not found")
	}
	if got.ClaudeAccountID != want.ClaudeAccountID || got.CodexAccountID != want.CodexAccountID ||
		got.ProxyID != want.ProxyID || got.DefaultModelClaude != want.DefaultModelClaude ||
		got.DefaultModelCodex != want.DefaultModelCodex {
		t.Fatalf("round trip lost instance fields: %+v", got)
	}
}

// An instance deleted outright must not leave sync rows behind; usage_events is
// the money trail and has to survive.
func TestDeleteCascadesSyncRowsButKeepsUsage(t *testing.T) {
	st, err := Open(filepath.Join(t.TempDir(), "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.Put(Session{ID: "s1", User: "alice", Name: "box", Agent: "claude", Status: StatusStopped}); err != nil {
		t.Fatal(err)
	}
	projects, err := st.ReconcileSyncProjects("s1", "/srv/s1/workspace", []string{"alpha"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.Exec(`INSERT INTO usage_events (session_id, user, agent, account_id, kind, ts, cost_micro_usd)
		VALUES ('s1','alice','claude','a1','chat','2026-01-01T00:00:00Z',100)`); err != nil {
		t.Fatal(err)
	}
	if _, _, err := st.AcquireSyncLease(projects[0].ID, "dev", "Dev", time.Minute, time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := st.Delete("s1"); err != nil {
		t.Fatal(err)
	}
	for _, check := range []struct{ query, label string }{
		{"SELECT COUNT(*) FROM sync_projects WHERE session_id='s1'", "sync_projects"},
		{"SELECT COUNT(*) FROM sync_leases WHERE project_id='" + projects[0].ID + "'", "sync_leases"},
		{"SELECT COUNT(*) FROM sessions WHERE id='s1'", "sessions"},
	} {
		var left int
		if err := st.db.QueryRow(check.query).Scan(&left); err != nil {
			t.Fatal(err)
		}
		if left != 0 {
			t.Fatalf("%s rows survived delete: %d", check.label, left)
		}
	}
	var usage int
	if err := st.db.QueryRow("SELECT COUNT(*) FROM usage_events WHERE session_id='s1'").Scan(&usage); err != nil {
		t.Fatal(err)
	}
	if usage != 1 {
		t.Fatalf("usage_events deleted with the instance: %d", usage)
	}
}

func TestReconcileRecordsProjectPathAndRenameMovesIt(t *testing.T) {
	st, err := Open(filepath.Join(t.TempDir(), "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	dir := "/srv/instances/s1/workspace"
	projects, err := st.ReconcileSyncProjects("s1", dir, []string{"alpha"})
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(dir, "alpha")
	if projects[0].Path != want {
		t.Fatalf("path = %q want %q", projects[0].Path, want)
	}
	renamed, err := st.RenameSyncProject(projects[0].ID, "beta")
	if err != nil {
		t.Fatal(err)
	}
	if renamed.Path != filepath.Join(dir, "beta") {
		t.Fatalf("path after rename = %q want %q", renamed.Path, filepath.Join(dir, "beta"))
	}
	// A row that predates the path column must stay empty rather than gain a
	// half-derived path; the server-layer backfill owns those.
	if _, err := st.db.Exec("UPDATE sync_projects SET path='' WHERE id=?", renamed.ID); err != nil {
		t.Fatal(err)
	}
	again, err := st.RenameSyncProject(renamed.ID, "gamma")
	if err != nil {
		t.Fatal(err)
	}
	if again.Path != "" {
		t.Fatalf("empty path became %q", again.Path)
	}
}

func TestSetSyncProjectAgent(t *testing.T) {
	st, err := Open(filepath.Join(t.TempDir(), "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	projects, err := st.ReconcileSyncProjects("s1", "/srv/s1/workspace", []string{"alpha"})
	if err != nil {
		t.Fatal(err)
	}
	pinned, err := st.SetSyncProjectAgent(projects[0].ID, "codex")
	if err != nil {
		t.Fatal(err)
	}
	if pinned.Agent != "codex" {
		t.Fatalf("agent = %q", pinned.Agent)
	}
	cleared, err := st.SetSyncProjectAgent(projects[0].ID, "")
	if err != nil {
		t.Fatal(err)
	}
	if cleared.Agent != "" {
		t.Fatalf("agent not cleared: %q", cleared.Agent)
	}
}
