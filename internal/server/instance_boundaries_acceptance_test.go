package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"agentbox/internal/config"
	"agentbox/internal/store"
)

func TestBoundInstanceRejectsMissingBridgeHost(t *testing.T) {
	server := newProxyServer("px1", testProxies)
	server.cfg.ProxyBridge.Host = ""
	server.cfg.ProxyBridge.Bind = ":1081"
	if env, err := server.proxyEnvList(store.Session{ID: "s1", ProxyID: "px1"}); err == nil || len(env) != 0 {
		t.Fatalf("bound instance may bypass its proxy: env=%v, error=%v", env, err)
	}
}

func TestInstanceProxyOptionsNeverExposeConnectionDetails(t *testing.T) {
	server := newInstanceServer(t)
	server.cfg.Proxies = append(server.cfg.Proxies, config.Proxy{
		ID: "private-exit", Name: "Home exit", Kind: config.ProxyKindResidential,
		Host: "secret-host.invalid", Port: 1234, Username: "secret-user", Password: "secret-password",
	})
	recorder := httptest.NewRecorder()
	server.handleInstanceProxyOptions(recorder, accessRequest("alice", http.MethodGet, "/api/instances/proxies", ""))
	var options []map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &options); err != nil {
		t.Fatal(err)
	}
	if len(options) != 2 {
		t.Fatalf("unexpected options: %s", recorder.Body.String())
	}
	for _, option := range options {
		if len(option) != 3 || option["kind"] != config.ProxyKindResidential {
			t.Fatalf("private fields or invalid exit: %v", option)
		}
	}
	if strings.Contains(recorder.Body.String(), "secret-") {
		t.Fatal("proxy secret metadata leaked")
	}
}

func TestBoundInstanceEnvCannotOverrideProxy(t *testing.T) {
	server := newInstanceServer(t)
	server.cfg.ProxyBridge = config.ProxyBridgeConfig{Host: "172.17.0.1", Bind: "172.17.0.1:1081"}
	server.cfg.Accounts[0].Env = map[string]string{"HTTP_PROXY": "http://wrong-exit.invalid", "NO_PROXY": "*"}
	session := seedInstance(t, server, store.Session{
		ClaudeAccountID: instanceClaudeAcct, AccountID: instanceClaudeAcct, ProxyID: instanceResProxy,
	})
	env, err := server.execEnv(session)
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for _, entry := range env {
		key, value, _ := strings.Cut(entry, "=")
		if seen[key] || strings.Contains(value, "wrong-exit") || key == "NO_PROXY" && value == "*" {
			t.Fatalf("proxy override remains: %v", env)
		}
		seen[key] = true
	}
}

func TestInstancePatchPreservesLegacyContainerOnBindingChange(t *testing.T) {
	server := newInstanceServer(t)
	session := seedInstance(t, server, store.Session{
		ClaudeAccountID: instanceClaudeAcct, AccountID: instanceClaudeAcct,
		ProxyID: instanceResProxy, ContainerID: "legacy", Status: store.StatusRunning,
	})
	recorder := httptest.NewRecorder()
	server.handleRenameSession(recorder, accessRequest("alice", http.MethodPatch, "/", `{"codex_account_id":"codex-1"}`), session)
	if recorder.Code != http.StatusConflict {
		t.Fatalf("unsafe binding change accepted: %d %s", recorder.Code, recorder.Body.String())
	}
	stored, _ := server.store.Get(session.ID)
	if stored.ContainerID != "legacy" || stored.CodexAccountID != "" {
		t.Fatalf("existing instance was changed: %+v", stored)
	}
}

func TestDualAccountDefaultCodexKeepsClaudeMCP(t *testing.T) {
	server := newInstanceServer(t)
	session := seedInstance(t, server, store.Session{
		ClaudeAccountID: instanceClaudeAcct, CodexAccountID: instanceCodexAcct,
		AccountID: instanceCodexAcct, Agent: config.AgentCodex, ProxyID: instanceResProxy,
		DefaultModel: "synthetic-codex-model",
	})
	recorder := httptest.NewRecorder()
	server.handleMCPSession(recorder, accessRequest("alice", http.MethodGet, "/", ""), session)
	if recorder.Code != http.StatusOK {
		t.Fatalf("bound Claude MCP rejected: %d %s", recorder.Code, recorder.Body.String())
	}
	if session.ModelFor(config.AgentClaude) != "" {
		t.Fatal("Codex legacy model was inherited by Claude")
	}
}

func TestDiskUsageDoesNotFollowSymlinks(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "inside"), []byte("abc"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(outside, "outside"), []byte("secret"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "escape")); err != nil {
		t.Fatal(err)
	}
	if size, complete := dirSize(root); !complete || size != 3 {
		t.Fatalf("unexpected disk footprint: %d, %v", size, complete)
	}
	if _, complete := dirSize(filepath.Join(root, "escape")); complete {
		t.Fatal("symlink root was accepted")
	}
}

func TestDiskUsageInvalidSampleCannotBeFresh(t *testing.T) {
	cache := newDiskUsageCache()
	cache.entries["bad"] = diskEntry{at: time.Now(), checked: time.Now(), valid: false}
	if _, fresh := cache.peek("bad"); fresh {
		t.Fatal("unknown sample reported as fresh zero")
	}
	for count := 0; count < diskUsageConcurrency; count++ {
		cache.sem <- struct{}{}
	}
	cache.warm([]string{"new-instance"})
	if _, exists := cache.entries["new-instance"]; exists {
		t.Fatal("saturated scanner queued an unbounded waiting goroutine")
	}
}
