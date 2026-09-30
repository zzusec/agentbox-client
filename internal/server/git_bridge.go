package server

import (
	"context"
	"net"
	"net/http"
	"strings"
	"sync"
)

const gitBridgePathPrefix = "/.agentbox-git/"

// gitBridgeGrant is one operation-scoped Git handler multiplexed through the
// account-proxy bridge listener. The listener port is already reachable from
// workspace containers, while fresh high ports may be blocked by host firewall
// rules.
type gitBridgeGrant struct {
	handler http.Handler
	ctx     context.Context
	cancel  context.CancelFunc

	gate   sync.Mutex
	closed bool
	wg     sync.WaitGroup
}

func (g *gitBridgeGrant) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	g.gate.Lock()
	if g.closed {
		g.gate.Unlock()
		http.NotFound(w, r)
		return
	}
	g.wg.Add(1)
	g.gate.Unlock()
	defer g.wg.Done()
	g.handler.ServeHTTP(w, r.WithContext(g.ctx))
}

func (g *gitBridgeGrant) Close() {
	g.gate.Lock()
	if !g.closed {
		g.closed = true
		g.cancel()
	}
	g.gate.Unlock()
	g.wg.Wait()
}

func (s *Server) registerGitBridge(ctx context.Context, ticket string, handler http.Handler) (*gitBridgeGrant, bool) {
	if ticket == "" || handler == nil {
		return nil, false
	}
	grantCtx, cancel := context.WithCancel(ctx)
	g := &gitBridgeGrant{handler: handler, ctx: grantCtx, cancel: cancel}
	s.gitBridgeMu.Lock()
	defer s.gitBridgeMu.Unlock()
	if s.gitBridgeGrants == nil {
		s.gitBridgeGrants = map[string]*gitBridgeGrant{}
	}
	if _, exists := s.gitBridgeGrants[ticket]; exists {
		cancel()
		return nil, false
	}
	s.gitBridgeGrants[ticket] = g
	return g, true
}

func (s *Server) unregisterGitBridge(ticket string, grant *gitBridgeGrant) {
	s.gitBridgeMu.Lock()
	if s.gitBridgeGrants[ticket] == grant {
		delete(s.gitBridgeGrants, ticket)
	}
	s.gitBridgeMu.Unlock()
}

func (s *Server) gitBridgeGrant(ticket string) *gitBridgeGrant {
	s.gitBridgeMu.Lock()
	defer s.gitBridgeMu.Unlock()
	return s.gitBridgeGrants[ticket]
}

func (s *Server) gitBridgeEndpoint() (string, bool) {
	s.bridgeMu.Lock()
	defer s.bridgeMu.Unlock()
	if s.bridgeLn == nil || !s.bridgeUp.Load() {
		return "", false
	}
	host := s.cfg.GetProxyBridge().Host
	_, port, err := net.SplitHostPort(s.bridgeLn.Addr().String())
	if host == "" || err != nil {
		return "", false
	}
	return net.JoinHostPort(host, port), true
}

// serveGitBridge consumes only its reserved path. Proxy requests continue
// through the existing authenticated proxy path unchanged.
func (s *Server) serveGitBridge(w http.ResponseWriter, r *http.Request) bool {
	if !strings.HasPrefix(r.URL.Path, gitBridgePathPrefix) {
		return false
	}
	rest := strings.TrimPrefix(r.URL.Path, gitBridgePathPrefix)
	ticket, suffix, ok := strings.Cut(rest, "/")
	if !ok || ticket == "" || suffix == "" {
		http.NotFound(w, r)
		return true
	}
	grant := s.gitBridgeGrant(ticket)
	if grant == nil {
		http.NotFound(w, r)
		return true
	}
	clone := r.Clone(r.Context())
	u := *r.URL
	u.Path = "/" + ticket + "/" + suffix
	u.RawPath = ""
	clone.URL = &u
	grant.ServeHTTP(w, clone)
	return true
}
