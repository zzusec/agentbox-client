package credentials

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"agentbox/internal/config"
	"agentbox/internal/store"
)

func TestSecondaryCodexCredentialSync(t *testing.T) {
	account := config.Account{ID: "codex-secondary", Type: config.AgentCodex, CredentialsDir: t.TempDir()}
	service, data := testService(t, "", account)
	session := store.Session{ID: "dual", User: "alice", Agent: config.AgentClaude, AccountID: "claude-primary", CodexAccountID: account.ID}
	service.sessions = testSessions{session}
	pool := filepath.Join(account.CredentialsDir, "auth.json")
	home := filepath.Join(data, "users", "alice", "sessions", session.ID, "home", ".codex", "auth.json")
	put(t, pool, `{"OPENAI_API_KEY":"fresh-synthetic-key"}`)
	put(t, home, `{"OPENAI_API_KEY":"old-synthetic-key"}`)
	stamp := time.Now().Add(-5 * time.Second)
	if err := os.Chtimes(home, stamp, stamp); err != nil {
		t.Fatal(err)
	}
	if err := service.Sync(t.Context(), account, session); err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(home)
	if err != nil || !strings.Contains(string(content), "fresh-synthetic-key") {
		t.Fatalf("secondary credentials not synchronized: %s, %v", content, err)
	}
}

func TestSecondaryClaudeCredentialBroadcastRespectsAccess(t *testing.T) {
	account := config.Account{
		ID: "claude-secondary", Type: config.AgentClaude, CredentialsDir: t.TempDir(),
		Access: &config.AccountAccess{Mode: "users", Users: []string{"alice"}},
	}
	service, data := testService(t, "", account)
	service.sessions = testSessions{
		{ID: "dual", User: "alice", Agent: config.AgentCodex, AccountID: "codex-primary", ClaudeAccountID: account.ID},
		{ID: "revoked", User: "bob", Agent: config.AgentCodex, AccountID: "codex-primary", ClaudeAccountID: account.ID},
	}
	put(t, filepath.Join(account.CredentialsDir, ".credentials.json"), `{"claudeAiOauth":{"accessToken":"fresh-synthetic-access"}}`)
	allowed := homeFile(data, "alice", "dual")
	revoked := homeFile(data, "bob", "revoked")
	put(t, allowed, expiredJSON())
	put(t, revoked, expiredJSON())
	service.broadcast(account)
	content, err := os.ReadFile(allowed)
	if err != nil || !strings.Contains(string(content), "fresh-synthetic-access") {
		t.Fatalf("secondary Claude not updated: %s, %v", content, err)
	}
	content, err = os.ReadFile(revoked)
	if err != nil || strings.Contains(string(content), "fresh-synthetic-access") {
		t.Fatalf("revoked user received credentials: %s, %v", content, err)
	}
}
