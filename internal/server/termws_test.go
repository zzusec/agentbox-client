package server

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/gorilla/websocket"

	"agentbox/internal/config"
	"agentbox/internal/store"
)

func TestTmuxEnvSyncMirrorsAndUnsets(t *testing.T) {
	got := tmuxEnvSync([]string{
		"ANTHROPIC_BASE_URL=https://example.com",
		envIntranetProxy + "=socks5h://u:p@172.17.0.1:1080",
	})
	for _, want := range []string{
		"tmux set-environment -g ANTHROPIC_BASE_URL 'https://example.com'; ",
		"tmux set-environment -g " + envIntranetProxy + " 'socks5h://u:p@172.17.0.1:1080'; ",
		// Not injected this time (no port maps) -> must be cleared, not kept.
		"tmux set-environment -gu " + envIntranetMaps + "; ",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in:\n%s", want, got)
		}
	}
	if strings.Contains(got, "-gu "+envIntranetProxy) {
		t.Errorf("proxy was provided, must not be unset:\n%s", got)
	}
}

func TestTmuxEnvSyncUnsetsAllTunnelVarsWhenLinkDown(t *testing.T) {
	got := tmuxEnvSync(nil)
	for _, name := range tunnelEnvNames {
		if !strings.Contains(got, "tmux set-environment -gu "+name+"; ") {
			t.Errorf("%s not unset with no env:\n%s", name, got)
		}
	}
}

func TestTmuxEnvSyncSkipsUnsafeNames(t *testing.T) {
	got := tmuxEnvSync([]string{"BAD;NAME=x", "9LEADING=x", "=novalue", "OK_1=y"})
	for _, bad := range []string{"BAD;NAME", "9LEADING", "novalue"} {
		if strings.Contains(got, bad) {
			t.Errorf("unsafe entry %q leaked into:\n%s", bad, got)
		}
	}
	if !strings.Contains(got, "tmux set-environment -g OK_1 'y'; ") {
		t.Errorf("valid name dropped:\n%s", got)
	}
}

func TestShellQuoteNeutralizesInjection(t *testing.T) {
	got := shellQuote(`a'; rm -rf /; echo '`)
	if want := `'a'\''; rm -rf /; echo '\'''`; got != want {
		t.Errorf("shellQuote = %s, want %s", got, want)
	}
}

// dialTerm 起一个只挂 handleTermWS 的服务器并连上去。测的是拒绝路径，走不到
// docker，所以 newTestServer 里没有 dock 也不要紧。
func dialTerm(t *testing.T, s *Server, sess store.Session) *websocket.Conn {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.handleTermWS(w, r, sess)
	}))
	t.Cleanup(srv.Close)
	conn, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(srv.URL, "http"), nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return conn
}

// 额度用尽的用户不该被放进终端：终端里的 agent 不计量，放进去等于绕过额度。
func TestHandleTermWSBlocksExhaustedQuota(t *testing.T) {
	s, sess := newTestServer(t)
	if _, err := s.store.Grant(sess.User, 1000, "grant:seed", "", "boxadmin"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.store.Grant(sess.User, -1000, "spend:all", "", ""); err != nil {
		t.Fatal(err)
	}

	conn := dialTerm(t, s, sess)
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	_, _, err := conn.ReadMessage()
	ce, ok := err.(*websocket.CloseError)
	if !ok {
		t.Fatalf("err = %v, want a close frame", err)
	}
	// 关闭码必须落在应用私有段：前端据此停止自动重连，1006 会让它一直退避重试。
	if ce.Code != closeQuota {
		t.Errorf("close code = %d, want %d", ce.Code, closeQuota)
	}
	if !strings.Contains(ce.Text, "额度已用完") {
		t.Errorf("close reason = %q, 应该把原因告诉用户", ce.Text)
	}
}

// 没有额度行 = 不限额，老部署升级上来不能被这道检查关在门外。
func TestHandleTermWSAllowsUnmeteredUser(t *testing.T) {
	s, sess := newTestServer(t)
	if why := s.quotaBlock(sess.User); why != "" {
		t.Fatalf("没开额度的用户被拦了：%s", why)
	}
}

// 只计不拦的用户余额见底也照样能进终端，跟对话页一个口径。
func TestHandleTermWSAllowsTrackOnlyUser(t *testing.T) {
	s, sess := newTestServer(t)
	if _, err := s.store.Grant(sess.User, -1000, "spend:all", "", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := s.store.SetQuotaEnforced(sess.User, false); err != nil {
		t.Fatal(err)
	}
	if why := s.quotaBlock(sess.User); why != "" {
		t.Fatalf("只计不拦的用户被拦了：%s", why)
	}
}

// 关闭原因超长会让 WriteControl 直接报错，一句话都送不出去；截断必须落在 rune 边界。
func TestTruncReasonFitsControlFrame(t *testing.T) {
	long := strings.Repeat("额", 200) // 600 字节
	got := truncReason(long)
	if len(got) > 123 {
		t.Errorf("len = %d, 控制帧塞不下（上限 123）", len(got))
	}
	if !utf8.ValidString(got) {
		t.Errorf("截在了半个汉字上：%q", got)
	}
	if short := "额度已用完"; truncReason(short) != short {
		t.Errorf("放得下的原因不该被动：%q", truncReason(short))
	}
}

func TestTermCommandKeepsFallbackAndAttach(t *testing.T) {
	cmd := termCommand([]string{envIntranetProxy + "=socks5h://x"})
	if !strings.HasPrefix(cmd, "command -v tmux >/dev/null || exec /bin/bash\n") {
		t.Errorf("pre-tmux image fallback lost:\n%s", cmd)
	}
	if !strings.HasSuffix(cmd, "exec tmux -u new-session -A -D -s main") {
		t.Errorf("attach must be the last thing exec'd:\n%s", cmd)
	}
	// The sync block must not be able to write to the PTY or abort the attach.
	if !strings.Contains(cmd, "} >/dev/null 2>&1\n") {
		t.Errorf("sync output not silenced:\n%s", cmd)
	}
}

func TestParseTerminalRequest(t *testing.T) {
	tests := []struct {
		name    string
		target  string
		mode    string
		project string
		ok      bool
	}{
		{name: "default shell", target: "/term", mode: "shell", ok: true},
		{name: "agent project", target: "/term?mode=agent&project=alpha", mode: "agent", project: "alpha", ok: true},
		{name: "agent requires project", target: "/term?mode=agent", ok: false},
		{name: "reject separators", target: "/term?mode=agent&project=a%2Fb", ok: false},
		{name: "reject unknown mode", target: "/term?mode=other", ok: false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodGet, tt.target, nil)
			got, err := parseTerminalRequest(r)
			if tt.ok != (err == nil) {
				t.Fatalf("ok = %v, err = %v", tt.ok, err)
			}
			if tt.ok && (got.mode != tt.mode || got.project != tt.project) {
				t.Fatalf("request = %+v, want mode=%q project=%q", got, tt.mode, tt.project)
			}
		})
	}
}

func TestAgentTermCommandUsesProjectSession(t *testing.T) {
	const workspace = "/srv/agentbox/data/users/alice/sessions/s1/workspace"
	cmd := agentTermCommand([]string{envIntranetProxy + "=socks5h://x"}, "alpha", config.AgentClaude, workspace)
	for _, want := range []string{
		workspace + "/alpha",
		"exec claude",
		"new-session -A -D -s " + shellQuote(agentTmuxSession("alpha")),
		"set-environment -g " + envIntranetProxy + " 'socks5h://x'; ",
	} {
		if !strings.Contains(cmd, want) {
			t.Errorf("missing %q in:\n%s", want, cmd)
		}
	}
	if agentTmuxSession("alpha") == agentTmuxSession("beta") {
		t.Fatal("different projects must not share a tmux session")
	}
}
