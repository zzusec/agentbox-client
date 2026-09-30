package server

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"agentbox/internal/config"
	"agentbox/internal/store"
)

func TestGitTransportUsesProxyBridgePort(t *testing.T) {
	s, sess := newTestServer(t)
	upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, pass, ok := r.BasicAuth()
		if !ok || user != "fixture" || pass != "synthetic-secret" {
			t.Errorf("upstream auth = %q/%q", user, pass)
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "application/x-git-upload-pack-advertisement")
		_, _ = io.WriteString(w, "001e# service=git-upload-pack\n0000")
	}))
	defer upstream.Close()

	s.cfg.AuthToken = "a-long-enough-token"
	s.cfg.ProxyBridge = config.ProxyBridgeConfig{Bind: "127.0.0.1:0", Host: "127.0.0.1"}
	s.cfg.Proxies = []config.Proxy{{ID: "px1", Scheme: config.ProxySOCKS5, Host: "127.0.0.1", Port: 1}}
	startBridge(t, s)

	s.gitHTTPClient = func(context.Context, store.GitConnection) (*http.Client, func(), error) {
		return upstream.Client(), func() {}, nil
	}
	c := createGitConnection(t, s, sess.User, upstream.URL, true)
	transport, closeTransport, err := s.gitTransport(t.Context(), c, upstream.URL+"/repo.git", false, "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	defer closeTransport()

	u, err := url.Parse(transport)
	if err != nil {
		t.Fatal(err)
	}
	if u.Scheme != "http" || u.Host != s.bridgeLn.Addr().String() || !strings.HasPrefix(u.Path, gitBridgePathPrefix) {
		t.Fatalf("transport = %q, want shared bridge endpoint", transport)
	}
	ticket := strings.TrimPrefix(u.Path, gitBridgePathPrefix)
	if s.gitBridgeGrant(ticket) == nil {
		t.Fatal("Git grant is not registered on the shared bridge")
	}

	resp, err := http.Get(transport + "/info/refs?service=git-upload-pack")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("bridge response = %d %s", resp.StatusCode, body)
	}

	closeTransport()
	if s.gitBridgeGrant(ticket) != nil {
		t.Fatal("Git grant remained registered after transport close")
	}
}

func TestGitBridgeUnknownTicketDoesNotFallThroughToProxyAuth(t *testing.T) {
	upstream := startUpstreamSOCKS(t, "user", "pass")
	s := bridgeTestServer(t, upstream, "user", "pass")
	startBridge(t, s)

	req := httptest.NewRequest(http.MethodGet, gitBridgePathPrefix+"missing/info/refs", nil)
	w := httptest.NewRecorder()
	s.serveProxyBridge(w, req)
	if w.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", w.Code)
	}
	if got := w.Header().Get("Proxy-Authenticate"); got != "" {
		t.Fatalf("unknown Git ticket fell through to proxy auth: %q", got)
	}
}
