package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"agentbox/internal/config"
	"agentbox/internal/store"
)

// One account, one instance: a second instance may not take an account that
// another instance already holds, whoever owns it.
func TestCreateInstanceRejectsAccountBoundElsewhere(t *testing.T) {
	s := newInstanceServer(t)
	if err := s.store.CreateUser(store.User{Name: "bob", Role: store.RoleUser}); err != nil {
		t.Fatal(err)
	}
	seedInstance(t, s, store.Session{
		Name: "alice-box", ClaudeAccountID: instanceClaudeAcct, AccountID: instanceClaudeAcct,
		ProxyID: instanceResProxy,
	})
	before := len(s.store.All())

	w := createInstance(t, s, `{"name":"second","claude_account_id":"claude-1","proxy_id":"px-res"}`)
	if w.Code != http.StatusConflict || !strings.Contains(w.Body.String(), "alice-box") {
		t.Fatalf("owner: status=%d body=%s", w.Code, w.Body.String())
	}

	// Another user is told the account is taken, not whose instance has it.
	rec := httptest.NewRecorder()
	s.handleCreateSession(rec, accessRequest("bob", http.MethodPost, "/sessions",
		`{"name":"bobs","claude_account_id":"claude-1","proxy_id":"px-res"}`))
	if rec.Code != http.StatusConflict || strings.Contains(rec.Body.String(), "alice-box") ||
		!strings.Contains(rec.Body.String(), "另一个实例") {
		t.Fatalf("other user: status=%d body=%s", rec.Code, rec.Body.String())
	}
	if got := len(s.store.All()); got != before {
		t.Fatalf("a rejected create left %d instances, want %d", got, before)
	}
}

func TestPatchInstanceRejectsAccountBoundElsewhere(t *testing.T) {
	s := newInstanceServer(t)
	seedInstance(t, s, store.Session{
		Name: "holder", CodexAccountID: instanceCodexAcct, AccountID: instanceCodexAcct,
		Agent: config.AgentCodex, ProxyID: instanceResProxy,
	})
	sess := seedInstance(t, s, store.Session{
		Name: "taker", ClaudeAccountID: instanceClaudeAcct, AccountID: instanceClaudeAcct,
		ProxyID: instanceResProxy,
	})
	patch := func(target store.Session, body string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		s.handleRenameSession(rec, accessRequest("alice", http.MethodPatch, "/instances/"+target.ID, body), target)
		return rec
	}
	if got := patch(sess, `{"codex_account_id":"codex-1"}`); got.Code != http.StatusConflict ||
		!strings.Contains(got.Body.String(), "holder") {
		t.Fatalf("rebind to a held account: %d %s", got.Code, got.Body.String())
	}
	after, _ := s.store.Get(sess.ID)
	if after.CodexAccountID != "" {
		t.Fatalf("rejected rebind changed the row: %+v", after)
	}

	// Two instances that already shared an account before the rule can still
	// be renamed; only a newly attached account is checked.
	shared := seedInstance(t, s, store.Session{
		Name: "legacy-share", ClaudeAccountID: instanceClaudeAcct, AccountID: instanceClaudeAcct,
		ProxyID: instanceResProxy,
	})
	if got := patch(shared, `{"name":"renamed"}`); got.Code != http.StatusOK {
		t.Fatalf("rename of a legacy share: %d %s", got.Code, got.Body.String())
	}
	if got := patch(shared, `{"claude_account_id":"claude-1","default_agent":"claude"}`); got.Code != http.StatusOK {
		t.Fatalf("re-sending the same account: %d %s", got.Code, got.Body.String())
	}
}

func TestAccountListReportsBinding(t *testing.T) {
	s := newInstanceServer(t)
	if err := s.store.CreateUser(store.User{Name: "bob", Role: store.RoleUser}); err != nil {
		t.Fatal(err)
	}
	held := seedInstance(t, s, store.Session{
		Name: "alice-box", ClaudeAccountID: instanceClaudeAcct, AccountID: instanceClaudeAcct,
		ProxyID: instanceResProxy,
	})
	list := func(user string) map[string]acctView {
		t.Helper()
		rec := httptest.NewRecorder()
		s.handleAccounts(rec, accessRequest(user, http.MethodGet, "/accounts", ""))
		var views []acctView
		if err := json.Unmarshal(rec.Body.Bytes(), &views); err != nil {
			t.Fatal(err)
		}
		out := map[string]acctView{}
		for _, v := range views {
			out[v.ID] = v
		}
		return out
	}
	alice := list("alice")
	if v := alice[instanceClaudeAcct]; !v.Bound || v.BoundInstance != "alice-box" || v.BoundSessionID != held.ID {
		t.Fatalf("owner view = %+v", v)
	}
	if v := alice[instanceCodexAcct]; v.Bound {
		t.Fatalf("free account reported bound: %+v", v)
	}
	bob := list("bob")
	if v := bob[instanceClaudeAcct]; !v.Bound || v.BoundInstance != "" || v.BoundSessionID != "" {
		t.Fatalf("other user view leaks the holder: %+v", v)
	}
	if v := list("root")[instanceClaudeAcct]; v.BoundInstance != "alice-box" {
		t.Fatalf("admin view = %+v", v)
	}
}
