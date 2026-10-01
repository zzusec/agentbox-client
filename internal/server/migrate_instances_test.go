package server

import (
	"path/filepath"
	"testing"

	"agentbox/internal/config"
	"agentbox/internal/store"
)

func newMigrationServer(t *testing.T, accounts []config.Account, proxies []config.Proxy) *Server {
	t.Helper()
	dataDir := t.TempDir()
	st, err := store.Open(filepath.Join(dataDir, "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	return &Server{
		cfg:    &config.Config{DataDir: dataDir, Accounts: accounts, Proxies: proxies},
		store:  st,
		logins: newLoginGuard(),
	}
}

// An instance that predates v11 carries its account in the legacy single
// column; the backfill has to route it to the column matching the account's
// type and hand the instance the proxy that account was already using.
func TestMigrateInstancesSplitsAccountsAndInheritsProxy(t *testing.T) {
	s := newMigrationServer(t,
		[]config.Account{{ID: "a-claude", Type: config.AgentClaude, ProxyID: "p1"}},
		[]config.Proxy{{ID: "p1", Scheme: config.ProxyHTTP, Host: "10.0.0.1", Port: 3128}},
	)
	sess := store.Session{ID: "s1", User: "alice", Name: "demo",
		Agent: config.AgentClaude, AccountID: "a-claude", DefaultModel: "claude-sonnet-4-5"}
	if err := s.store.Put(sess); err != nil {
		t.Fatal(err)
	}
	if err := s.migrateInstances(); err != nil {
		t.Fatal(err)
	}
	got, ok := s.store.Get("s1")
	if !ok {
		t.Fatal("session vanished")
	}
	if got.ClaudeAccountID != "a-claude" {
		t.Fatalf("claude_account_id = %q", got.ClaudeAccountID)
	}
	if got.CodexAccountID != "" {
		t.Fatalf("codex_account_id = %q, want empty", got.CodexAccountID)
	}
	if got.ProxyID != "p1" {
		t.Fatalf("proxy_id = %q, want the account's p1", got.ProxyID)
	}
	if got.DefaultModelClaude != "claude-sonnet-4-5" || got.DefaultModelCodex != "" {
		t.Fatalf("models = claude:%q codex:%q", got.DefaultModelClaude, got.DefaultModelCodex)
	}
	// The legacy columns survive so a rolled-back binary still reads the row.
	if got.AccountID != "a-claude" || got.Agent != config.AgentClaude {
		t.Fatalf("legacy columns clobbered: %+v", got)
	}
}

// Choosing an exit IP on the operator's behalf is worse than refusing to start.
func TestMigrateInstancesNeverAssignsUnboundProxy(t *testing.T) {
	pool := []config.Proxy{
		{ID: "p1", Scheme: config.ProxyHTTP, Host: "10.0.0.1", Port: 3128},
		{ID: "p2", Scheme: config.ProxyHTTP, Host: "10.0.0.2", Port: 3128},
	}
	put := func(t *testing.T, s *Server) store.Session {
		sess := store.Session{ID: "s1", User: "alice", Name: "demo", Agent: config.AgentClaude, AccountID: "a1"}
		if err := s.store.Put(sess); err != nil {
			t.Fatal(err)
		}
		return sess
	}

	one := newMigrationServer(t, []config.Account{{ID: "a1", Type: config.AgentClaude}}, pool[:1])
	put(t, one)
	if err := one.migrateInstances(); err != nil {
		t.Fatal(err)
	}
	if got, _ := one.store.Get("s1"); got.ProxyID != "" {
		t.Fatalf("unbound proxy was assigned: %q", got.ProxyID)
	}

	two := newMigrationServer(t, []config.Account{{ID: "a1", Type: config.AgentClaude}}, pool)
	put(t, two)
	if err := two.migrateInstances(); err != nil {
		t.Fatal(err)
	}
	if got, _ := two.store.Get("s1"); got.ProxyID != "" {
		t.Fatalf("ambiguous pool assigned %q", got.ProxyID)
	}
}

// A disabled proxy is not inheritable: an instance must not keep an exit that
// the operator switched off.
func TestMigrateInstancesSkipsDisabledProxy(t *testing.T) {
	s := newMigrationServer(t,
		[]config.Account{{ID: "a1", Type: config.AgentClaude, ProxyID: "p-dead"}},
		[]config.Proxy{{ID: "p-dead", Scheme: config.ProxyHTTP, Host: "10.0.0.1", Port: 3128, Disabled: true}},
	)
	if err := s.store.Put(store.Session{ID: "s1", User: "alice", Name: "demo", Agent: config.AgentClaude, AccountID: "a1"}); err != nil {
		t.Fatal(err)
	}
	if err := s.migrateInstances(); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.store.Get("s1"); got.ProxyID != "" {
		t.Fatalf("inherited a disabled proxy: %q", got.ProxyID)
	}
}

// Running twice must not move anything: values already filled stay put.
func TestMigrateInstancesIsIdempotent(t *testing.T) {
	s := newMigrationServer(t,
		[]config.Account{{ID: "a1", Type: config.AgentClaude}},
		[]config.Proxy{{ID: "p1", Scheme: config.ProxyHTTP, Host: "10.0.0.1", Port: 3128}},
	)
	if err := s.store.Put(store.Session{ID: "s1", User: "alice", Name: "demo", Agent: config.AgentClaude, AccountID: "a1"}); err != nil {
		t.Fatal(err)
	}
	if err := s.migrateInstances(); err != nil {
		t.Fatal(err)
	}
	first, _ := s.store.Get("s1")
	if _, err := s.store.Update("s1", func(x *store.Session) { x.ProxyID = "manual" }); err != nil {
		t.Fatal(err)
	}
	if err := s.migrateInstances(); err != nil {
		t.Fatal(err)
	}
	second, _ := s.store.Get("s1")
	if second.ProxyID != "manual" {
		t.Fatalf("second pass overwrote a chosen proxy: %q", second.ProxyID)
	}
	if second.ClaudeAccountID != first.ClaudeAccountID {
		t.Fatalf("claude account changed: %q -> %q", first.ClaudeAccountID, second.ClaudeAccountID)
	}
}

// Project paths are derived from the instance workspace so a path shown in a
// terminal is valid on the host and inside the container.
func TestMigrateInstancesBackfillsProjectPaths(t *testing.T) {
	s := newMigrationServer(t,
		[]config.Account{{ID: "a1", Type: config.AgentClaude}},
		[]config.Proxy{{ID: "p1", Scheme: config.ProxyHTTP, Host: "10.0.0.1", Port: 3128}},
	)
	sess := store.Session{ID: "s1", User: "alice", Name: "demo", Agent: config.AgentClaude, AccountID: "a1"}
	if err := s.store.Put(sess); err != nil {
		t.Fatal(err)
	}
	// Simulate a pre-v11 row by clearing the path the reconciler now writes.
	if _, err := s.store.ReconcileSyncProjects("s1", "", []string{"alpha"}); err != nil {
		t.Fatal(err)
	}
	if err := s.migrateInstances(); err != nil {
		t.Fatal(err)
	}
	rows, err := s.store.SyncProjects("s1")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 {
		t.Fatalf("projects = %+v", rows)
	}
	want := filepath.Join(s.workspaceDir(sess), "alpha")
	if rows[0].Path != want {
		t.Fatalf("path = %q want %q", rows[0].Path, want)
	}
}
