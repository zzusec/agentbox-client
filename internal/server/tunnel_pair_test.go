package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"agentbox/internal/store"
	"agentbox/internal/tunnel"
)

func TestPairCodeIsSingleUse(t *testing.T) {
	p := newPairStore()
	code, ok := p.issue("alice")
	if !ok {
		t.Fatal("issue failed")
	}
	if user, ok := p.redeem(code); !ok || user != "alice" {
		t.Fatalf("first redeem = %q, %v", user, ok)
	}
	if _, ok := p.redeem(code); ok {
		t.Fatal("a pairing code must not be redeemable twice")
	}
}

func TestPairCodeExpires(t *testing.T) {
	p := newPairStore()
	code, _ := p.issue("alice")
	p.mu.Lock()
	e := p.codes[code]
	e.expires = time.Now().Add(-time.Second)
	p.codes[code] = e
	p.mu.Unlock()

	if _, ok := p.redeem(code); ok {
		t.Fatal("an expired code must not redeem")
	}
}

// Clicking "generate" again should not leave the previous code live — the user
// reasonably assumes the one on screen is the only one that works.
func TestReissueInvalidatesPreviousCode(t *testing.T) {
	p := newPairStore()
	first, _ := p.issue("alice")
	second, _ := p.issue("alice")

	if _, ok := p.redeem(first); ok {
		t.Error("the superseded code should no longer redeem")
	}
	if _, ok := p.redeem(second); !ok {
		t.Error("the newest code should redeem")
	}
}

func TestReissueDoesNotDisturbOtherUsers(t *testing.T) {
	p := newPairStore()
	bobs, _ := p.issue("bob")
	p.issue("alice")
	p.issue("alice")

	if user, ok := p.redeem(bobs); !ok || user != "bob" {
		t.Fatalf("bob's code was collateral damage: %q %v", user, ok)
	}
}

func TestRedeemUnknownCode(t *testing.T) {
	p := newPairStore()
	p.issue("alice")
	if _, ok := p.redeem("not-a-real-code"); ok {
		t.Fatal("unknown code redeemed")
	}
}

func TestPairOrigin(t *testing.T) {
	cases := []struct {
		name    string
		claimed string
		req     func() *http.Request
		want    string
	}{
		{
			name:    "browser origin wins",
			claimed: "https://box.example.com",
			req:     func() *http.Request { return httptest.NewRequest("POST", "/api/tunnel/pair", nil) },
			want:    "https://box.example.com",
		},
		{
			name:    "falls back to request host",
			claimed: "",
			req: func() *http.Request {
				r := httptest.NewRequest("POST", "/api/tunnel/pair", nil)
				r.Host = "box.internal:8080"
				return r
			},
			want: "http://box.internal:8080",
		},
		{
			name:    "honours a terminating proxy's headers",
			claimed: "",
			req: func() *http.Request {
				r := httptest.NewRequest("POST", "/api/tunnel/pair", nil)
				r.Host = "127.0.0.1:8080"
				r.Header.Set("X-Forwarded-Host", "box.example.com, inner")
				r.Header.Set("X-Forwarded-Proto", "https")
				return r
			},
			want: "https://box.example.com",
		},
		{
			name:    "ignores a nonsense claim",
			claimed: "javascript:alert(1)",
			req: func() *http.Request {
				r := httptest.NewRequest("POST", "/api/tunnel/pair", nil)
				r.Host = "box.internal"
				return r
			},
			want: "http://box.internal",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := pairOrigin(tc.claimed, tc.req()); got != tc.want {
				t.Errorf("pairOrigin = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestClientPairDoesNotRequireTunnel(t *testing.T) {
	s, _ := newTestServer(t)
	s.pairs = newPairStore()
	if err := s.store.CreateUser(store.User{Name: "alice", Role: store.RoleUser}); err != nil {
		t.Fatal(err)
	}

	issue := accessRequest("alice", http.MethodPost, "/api/clients/pair", `{"origin":"https://box.example.com"}`)
	w := httptest.NewRecorder()
	s.handleClientPair(w, issue)
	if w.Code != http.StatusOK {
		t.Fatalf("issue status = %d, body = %s", w.Code, w.Body.String())
	}
	var issued struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &issued); err != nil {
		t.Fatal(err)
	}
	payload, err := tunnel.DecodePairCode(issued.Code)
	if err != nil {
		t.Fatal(err)
	}
	if payload.Server != "https://box.example.com" {
		t.Fatalf("server = %q", payload.Server)
	}

	redeem := httptest.NewRequest(http.MethodPost, "/api/clients/pair/redeem",
		strings.NewReader(`{"code":`+string(mustJSON(t, payload.Code))+`}`))
	w = httptest.NewRecorder()
	s.handleClientPairRedeem(w, redeem)
	if w.Code != http.StatusOK {
		t.Fatalf("redeem status = %d, body = %s", w.Code, w.Body.String())
	}
	var result struct {
		User  string `json:"user"`
		Token string `json:"token"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.User != "alice" || result.Token == "" {
		t.Fatalf("redeem result = %+v", result)
	}
	if user, ok := s.store.TokenUser(result.Token); !ok || user.Name != "alice" {
		t.Fatalf("issued token is not usable: %q %v", user.Name, ok)
	}
}

func mustJSON(t *testing.T, value any) []byte {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}
