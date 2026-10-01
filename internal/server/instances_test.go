package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"agentbox/internal/config"
	"agentbox/internal/store"
)

const (
	instanceClaudeAcct = "claude-1"
	instanceCodexAcct  = "codex-1"
	instanceResProxy   = "px-res"
	instanceDCProxy    = "px-dc"
)

// newInstanceServer builds a server with one claude account, one codex
// account, a labelled residential proxy and a labelled datacenter proxy.
//
// Docker is left nil on purpose: every path exercised here must decide before
// touching the runtime.
func newInstanceServer(t *testing.T) *Server {
	t.Helper()
	dataDir := t.TempDir()
	if resolved, err := filepath.EvalSymlinks(dataDir); err == nil {
		dataDir = resolved
	}
	st, err := store.Open(filepath.Join(dataDir, "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	if err := st.CreateUser(store.User{Name: "alice", Role: store.RoleUser}); err != nil {
		t.Fatal(err)
	}
	return &Server{
		cfg: &config.Config{
			DataDir: dataDir,
			Accounts: []config.Account{
				{ID: instanceClaudeAcct, Type: config.AgentClaude, Label: "Claude 主号"},
				{ID: instanceCodexAcct, Type: config.AgentCodex, Label: "Codex 主号"},
			},
			Proxies: []config.Proxy{
				{ID: instanceResProxy, Name: "住宅", Kind: config.ProxyKindResidential,
					Scheme: config.ProxySOCKS5, Host: "10.0.0.1", Port: 1080},
				{ID: instanceDCProxy, Name: "机房", Kind: config.ProxyKindDatacenter,
					Scheme: config.ProxySOCKS5, Host: "10.0.0.2", Port: 1080},
			},
		},
		store:  st,
		logins: newLoginGuard(),
		mon:    newMonState(),
	}
}

func createInstance(t *testing.T, s *Server, body string) *httptest.ResponseRecorder {
	t.Helper()
	w := httptest.NewRecorder()
	s.handleCreateSession(w, accessRequest("alice", http.MethodPost, "/sessions", body))
	return w
}

// seedInstance writes a row directly. Creating through the handler also creates
// directories and chowns them to the container UID, which only works as root;
// these tests only need the row.
func seedInstance(t *testing.T, s *Server, sess store.Session) store.Session {
	t.Helper()
	if sess.ID == "" {
		sess.ID = store.NewID()
	}
	if sess.User == "" {
		sess.User = "alice"
	}
	if sess.Agent == "" {
		sess.Agent = config.AgentClaude
	}
	if sess.Status == "" {
		sess.Status = store.StatusStopped
	}
	if err := s.store.Put(sess); err != nil {
		t.Fatal(err)
	}
	return sess
}

// The binding rules are pure validation: they must hold whether or not the
// filesystem lets us finish the create.
func TestResolveInstanceBindings(t *testing.T) {
	for _, tc := range []struct {
		name    string
		req     createSessionRequest
		claude  string
		codex   string
		agent   string
		wantErr bool
	}{
		{name: "claude only", req: createSessionRequest{ClaudeAccountID: "claude-1"},
			claude: "claude-1", agent: config.AgentClaude},
		{name: "codex only", req: createSessionRequest{CodexAccountID: "codex-1"},
			codex: "codex-1", agent: config.AgentCodex},
		{name: "both, claude default", req: createSessionRequest{ClaudeAccountID: "claude-1", CodexAccountID: "codex-1"},
			claude: "claude-1", codex: "codex-1", agent: config.AgentClaude},
		{name: "both, codex default", req: createSessionRequest{ClaudeAccountID: "claude-1", CodexAccountID: "codex-1", DefaultAgent: "codex"},
			claude: "claude-1", codex: "codex-1", agent: config.AgentCodex},
		{name: "legacy pair", req: createSessionRequest{Agent: "claude", AccountID: "claude-1"},
			claude: "claude-1", agent: config.AgentClaude},
		{name: "no account", req: createSessionRequest{}, wantErr: true},
		{name: "type mismatch", req: createSessionRequest{ClaudeAccountID: "codex-1"}, wantErr: true},
		{name: "unknown account", req: createSessionRequest{ClaudeAccountID: "nope"}, wantErr: true},
		{name: "default tool without its account",
			req: createSessionRequest{ClaudeAccountID: "claude-1", DefaultAgent: "codex"}, wantErr: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := newInstanceServer(t)
			w := httptest.NewRecorder()
			claude, codex, agent, ok := s.resolveInstanceAccounts(w,
				accessRequest("alice", http.MethodPost, "/sessions", ""), tc.req)
			if tc.wantErr {
				if ok {
					t.Fatalf("accepted: claude=%q codex=%q agent=%q", claude, codex, agent)
				}
				return
			}
			if !ok {
				t.Fatalf("rejected: %s", w.Body.String())
			}
			if claude != tc.claude || codex != tc.codex || agent != tc.agent {
				t.Fatalf("got claude=%q codex=%q agent=%q", claude, codex, agent)
			}
		})
	}
}

// A new instance must state that its exit is residential. An unlabelled proxy
// is a pool that predates the field: it stays usable for instances that
// already had it, but a fresh binding has to be explicit.
func TestResolveInstanceProxyRequiresResidential(t *testing.T) {
	s := newInstanceServer(t)
	for _, tc := range []struct {
		name    string
		id      string
		wantErr bool
	}{
		{name: "residential", id: instanceResProxy},
		{name: "datacenter", id: instanceDCProxy, wantErr: true},
		{name: "missing", id: "", wantErr: true},
		{name: "unknown", id: "nope", wantErr: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			w := httptest.NewRecorder()
			got, ok := s.resolveInstanceProxy(w, tc.id)
			if tc.wantErr {
				if ok {
					t.Fatalf("accepted %q", got)
				}
				return
			}
			if !ok || got != tc.id {
				t.Fatalf("got %q ok=%v: %s", got, ok, w.Body.String())
			}
		})
	}
}

func TestCreateInstanceRejectsBeforeCreatingAnything(t *testing.T) {
	for _, tc := range []struct {
		name string
		body string
	}{
		{"no account", `{"name":"a","proxy_id":"px-res"}`},
		{"no proxy", `{"name":"a","claude_account_id":"claude-1"}`},
		{"datacenter proxy", `{"name":"a","claude_account_id":"claude-1","proxy_id":"px-dc"}`},
		{"unknown proxy", `{"name":"a","claude_account_id":"claude-1","proxy_id":"nope"}`},
		{"account type mismatch", `{"name":"a","claude_account_id":"codex-1","proxy_id":"px-res"}`},
		{"default tool without its account", `{"name":"a","claude_account_id":"claude-1","proxy_id":"px-res","default_agent":"codex"}`},
		{"empty name", `{"name":"","claude_account_id":"claude-1","proxy_id":"px-res"}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := newInstanceServer(t)
			w := createInstance(t, s, tc.body)
			if w.Code != http.StatusBadRequest {
				t.Fatalf("status = %d body=%s", w.Code, w.Body.String())
			}
			if n := len(s.store.All()); n != 0 {
				t.Fatalf("rejected request created %d instances", n)
			}
		})
	}
}

// Legacy callers (the macOS app, abox-sync, saved scripts) still send the
// pre-instance pair. It must reach the same validation, including the now
// mandatory proxy.
func TestCreateInstanceValidatesLegacyPair(t *testing.T) {
	s := newInstanceServer(t)
	w := createInstance(t, s, `{"name":"legacy","agent":"claude","account_id":"claude-1"}`)
	if w.Code != http.StatusBadRequest || !strings.Contains(w.Body.String(), "代理") {
		t.Fatalf("legacy create without proxy: %d %s", w.Code, w.Body.String())
	}
}

// The accepted shapes go through directory creation and a chown to the
// container UID, which only succeeds as root — the same constraint the
// existing workspace tests document.
func TestCreateInstanceAcceptsEitherOrBothAccounts(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("requires chown to container UID; exercised in Linux container suite")
	}
	for _, tc := range []struct {
		name         string
		body         string
		claude       string
		codex        string
		defaultAgent string
	}{
		{"claude only", `{"name":"a","claude_account_id":"claude-1","proxy_id":"px-res"}`, "claude-1", "", config.AgentClaude},
		{"codex only", `{"name":"b","codex_account_id":"codex-1","proxy_id":"px-res"}`, "", "codex-1", config.AgentCodex},
		{"both, codex default",
			`{"name":"c","claude_account_id":"claude-1","codex_account_id":"codex-1","proxy_id":"px-res","default_agent":"codex"}`,
			"claude-1", "codex-1", config.AgentCodex},
		{"legacy pair", `{"name":"d","agent":"claude","account_id":"claude-1","proxy_id":"px-res"}`,
			"claude-1", "", config.AgentClaude},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := newInstanceServer(t)
			w := createInstance(t, s, tc.body)
			if w.Code != http.StatusCreated {
				t.Fatalf("status = %d body=%s", w.Code, w.Body.String())
			}
			var got sessionView
			if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
				t.Fatal(err)
			}
			if got.ClaudeAccountID != tc.claude || got.CodexAccountID != tc.codex {
				t.Fatalf("bindings = claude:%q codex:%q", got.ClaudeAccountID, got.CodexAccountID)
			}
			if got.Agent != tc.defaultAgent || got.DefaultAgent != tc.defaultAgent {
				t.Fatalf("default agent = %q / %q, want %q", got.Agent, got.DefaultAgent, tc.defaultAgent)
			}
			// The legacy column has to point at a tool the instance can run:
			// pre-instance clients and usage attribution still read it.
			wantLegacy := tc.claude
			if tc.defaultAgent == config.AgentCodex {
				wantLegacy = tc.codex
			}
			if got.AccountID != wantLegacy {
				t.Fatalf("legacy account_id = %q, want %q", got.AccountID, wantLegacy)
			}
			if got.WorkspacePath == "" {
				t.Fatal("workspace_path is empty")
			}
		})
	}
}

func TestPatchInstanceRebindsAccountsAndProxy(t *testing.T) {
	s := newInstanceServer(t)
	sess := seedInstance(t, s, store.Session{
		ClaudeAccountID: instanceClaudeAcct, AccountID: instanceClaudeAcct,
		ProxyID: instanceResProxy, Agent: config.AgentClaude,
	})

	patch := func(body string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		s.handleRenameSession(rec, accessRequest("alice", http.MethodPatch, "/instances/"+sess.ID, body), sess)
		return rec
	}

	// A plain rename must not blank the bindings.
	if got := patch(`{"name":"renamed"}`); got.Code != http.StatusOK {
		t.Fatalf("rename: %d %s", got.Code, got.Body.String())
	}
	after, _ := s.store.Get(sess.ID)
	if after.Name != "renamed" || after.ClaudeAccountID != instanceClaudeAcct || after.ProxyID != instanceResProxy {
		t.Fatalf("rename disturbed bindings: %+v", after)
	}

	// Adding the codex account and switching the default tool.
	if got := patch(`{"codex_account_id":"codex-1","default_agent":"codex"}`); got.Code != http.StatusOK {
		t.Fatalf("rebind: %d %s", got.Code, got.Body.String())
	}
	after, _ = s.store.Get(sess.ID)
	if after.CodexAccountID != instanceCodexAcct || after.Agent != config.AgentCodex || after.AccountID != instanceCodexAcct {
		t.Fatalf("rebind = %+v", after)
	}

	// Unbinding the account the default tool needs is refused...
	if got := patch(`{"codex_account_id":"","default_agent":"codex"}`); got.Code != http.StatusBadRequest {
		t.Fatalf("expected rejection, got %d %s", got.Code, got.Body.String())
	}
	// ...and so is switching to a datacenter proxy.
	if got := patch(`{"proxy_id":"px-dc"}`); got.Code != http.StatusBadRequest {
		t.Fatalf("expected rejection, got %d %s", got.Code, got.Body.String())
	}
	// The instance keeps what it had after the rejected patches.
	after, _ = s.store.Get(sess.ID)
	if after.CodexAccountID != instanceCodexAcct || after.ProxyID != instanceResProxy {
		t.Fatalf("rejected patch changed the row: %+v", after)
	}
}

// An instance that has not been through the v11 backfill still only carries the
// legacy column. Renaming it must not wipe that column.
func TestPatchInstanceKeepsLegacyBinding(t *testing.T) {
	s := newInstanceServer(t)
	sess := seedInstance(t, s, store.Session{
		AccountID: instanceClaudeAcct, Agent: config.AgentClaude, ProxyID: instanceResProxy,
	})
	rec := httptest.NewRecorder()
	s.handleRenameSession(rec, accessRequest("alice", http.MethodPatch, "/instances/"+sess.ID, `{"name":"kept"}`), sess)
	if rec.Code != http.StatusOK {
		t.Fatalf("rename: %d %s", rec.Code, rec.Body.String())
	}
	after, _ := s.store.Get(sess.ID)
	if after.AccountID != instanceClaudeAcct {
		t.Fatalf("legacy account_id = %q, want %q", after.AccountID, instanceClaudeAcct)
	}
}

// A project cannot be pinned to a tool the instance has no account for: the
// terminal would start with no credentials.
func TestProjectAgentMustMatchBoundAccount(t *testing.T) {
	s := newInstanceServer(t)
	sess := seedInstance(t, s, store.Session{
		ClaudeAccountID: instanceClaudeAcct, AccountID: instanceClaudeAcct,
		ProxyID: instanceResProxy, Agent: config.AgentClaude,
	})
	if err := os.MkdirAll(s.workspaceDir(sess), 0o755); err != nil {
		t.Fatal(err)
	}

	rec := httptest.NewRecorder()
	s.handleProjectCreate(rec, accessRequest("alice", http.MethodPost, "/instances/"+sess.ID+"/projects", `{"name":"alpha","agent":"codex"}`), sess)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("codex project on a claude-only instance: %d %s", rec.Code, rec.Body.String())
	}

	rec = httptest.NewRecorder()
	s.handleProjectCreate(rec, accessRequest("alice", http.MethodPost, "/instances/"+sess.ID+"/projects", `{"name":"alpha","agent":"claude"}`), sess)
	if rec.Code != http.StatusCreated || !strings.Contains(rec.Body.String(), `"agent":"claude"`) {
		t.Fatalf("claude project: %d %s", rec.Code, rec.Body.String())
	}
	// The path is the absolute host path, which is also the container path.
	var project projectView
	if err := json.Unmarshal(rec.Body.Bytes(), &project); err != nil {
		t.Fatal(err)
	}
	if project.Path != filepath.Join(s.workspaceDir(sess), "alpha") {
		t.Fatalf("path = %q", project.Path)
	}
}

// The per-user stats endpoint must only ever report the caller's instances.
func TestInstanceStatsListIsScopedToTheCaller(t *testing.T) {
	s := newInstanceServer(t)
	seedInstance(t, s, store.Session{ID: "s-alice", Name: "alice-box"})
	seedInstance(t, s, store.Session{ID: "s-bob", User: "bob", Name: "bob-box"})

	w := httptest.NewRecorder()
	s.handleInstanceStatsList(w, accessRequest("alice", http.MethodGet, "/instances/stats", ""))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d body=%s", w.Code, w.Body.String())
	}
	var view instanceStatsView
	if err := json.Unmarshal(w.Body.Bytes(), &view); err != nil {
		t.Fatal(err)
	}
	if len(view.Items) != 1 || view.Items[0].SessionID != "s-alice" {
		t.Fatalf("items = %+v", view.Items)
	}
	if view.WindowMS != 0 {
		t.Fatalf("first frame window_ms = %d, want 0", view.WindowMS)
	}
	// No proxy bound: the row has to say so rather than looking healthy.
	if view.Items[0].ProxyBound {
		t.Fatal("instance without a proxy reported as bound")
	}
}

// The alias routes have to resolve to the same handlers as /api/sessions.
// A duplicate or conflicting pattern would panic when the mux is built.
func TestInstanceRoutesAliasSessions(t *testing.T) {
	s := newInstanceServer(t)
	if err := s.store.CreateToken("alice-token", "alice"); err != nil {
		t.Fatal(err)
	}
	h := s.Handler()
	for _, path := range []string{"/api/instances", "/api/sessions"} {
		r := httptest.NewRequest(http.MethodGet, path, nil)
		r.Header.Set("Authorization", "Bearer alice-token")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != http.StatusOK {
			t.Fatalf("%s: %d %s", path, w.Code, w.Body.String())
		}
	}
}
