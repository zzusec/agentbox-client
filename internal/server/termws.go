package server

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/gorilla/websocket"

	"agentbox/internal/store"
)

const (
	wsWriteWait  = 10 * time.Second
	wsPongWait   = 90 * time.Second
	wsPingPeriod = 30 * time.Second
)

// closeQuota 是「额度不足」的关闭码。4000–4999 是 WebSocket 留给应用自己用的
// 私有段。用它而不是 HTTP 错误码：浏览器的 WebSocket 拿不到升级失败时的状态码
// 和响应体，只会收到一个没有原因的 1006，前端分不清是没额度还是网络抖动，于是
// 按退避策略无限重连——理由不会变，只是把服务端敲个不停。带原因的私有关闭码让
// 前端能把话原样显示出来，并且知道这次不该重连。
const closeQuota = 4003
const closeAccountAccess = 4004

// closeWithReason 送出一个带原因的关闭帧。
//
// 只用 WriteControl，不发数据帧：gorilla 的 WriteControl 可以和别的写并发，
// WriteMessage 不行，而这个函数会在读循环正往浏览器灌 PTY 字节时被巡检协程调用。
// 那行红字交给前端照着 reason 自己写进终端。
func closeWithReason(conn *websocket.Conn, code int, reason string) {
	_ = conn.WriteControl(websocket.CloseMessage,
		websocket.FormatCloseMessage(code, truncReason(reason)),
		time.Now().Add(wsWriteWait))
}

// truncReason 把关闭原因截到控制帧放得下的长度：整帧上限 125 字节，关闭码占 2 字节。
// 超了 WriteControl 直接报错，那样一句话都送不出去。按 rune 边界截——半个汉字会让
// 对端解码失败，比截短更糟。
func truncReason(s string) string {
	const max = 123
	if len(s) <= max {
		return s
	}
	b := []byte(s)
	n := max
	for n > 0 && !utf8.RuneStart(b[n]) {
		n--
	}
	return string(b[:n])
}

// termCommand builds the terminal's entry command: mirror this exec's env into
// the tmux server's global environment, then attach.
//
// The exec env reaches this process only. A tmux session that already exists
// was forked from some earlier exec, so anything started in it keeps that older
// env — a tunnel that came up after the session started stays invisible there
// (the symptom: the agent reports no $AGENTBOX_INTRANET_PROXY while the link is
// plainly connected). Pushing the values into tmux's global environment makes
// every window/pane opened from now on, including a restarted agent, see the
// current values. Panes already running keep their frozen env; that is a
// process-level fact of life, not something tmux can undo.
func termCommand(env []string) string {
	cmd := "command -v tmux >/dev/null || exec /bin/bash\n"
	// Errors are dropped on purpose: with no tmux server yet these fail, which
	// is harmless — new-session then inherits this exec's env directly. Their
	// output must not reach the PTY either way.
	if sync := tmuxEnvSync(env); sync != "" {
		cmd += "{ " + sync + "} >/dev/null 2>&1\n"
	}
	return cmd + tmuxAttach("new-session -A -D -s main")
}

// agentTermCommand opens the interactive coding agent for one workspace
// project. Each project gets a stable tmux session so several projects can run
// independently, and reconnecting attaches to the same agent process.
//
// workspace is the instance workspace directory on the host. The container
// mounts that directory at the same absolute path, so the directory the agent
// starts in is the path the user sees everywhere else — including on their own
// machine, where abox-sync mirrors the project under the same name.
//
// command is the project's launch command (see projectLaunch). It runs under
// `bash -c` rather than a bare exec so a stored command may use shell syntax —
// an env assignment, `&&`, a pipe — without the caller quoting anything; bash
// still execs a simple command in place, so the agent stays the foreground
// process of its tmux session.
func agentTermCommand(env []string, project, command, workspace string) string {
	projectPath := filepath.Join(workspace, project)
	run := "cd " + shellQuote(projectPath) + " && exec /bin/bash -c " + shellQuote(command)
	cmd := "command -v tmux >/dev/null || { " + run + "; }\n"
	if sync := tmuxEnvSync(env); sync != "" {
		cmd += "{ " + sync + "} >/dev/null 2>&1\n"
	}
	return cmd + tmuxAttach("new-session -A -D -s "+
		shellQuote(agentTmuxSession(project))+" "+shellQuote(run))
}

// tmuxNoAltScreen tells tmux not to switch the client terminal to its
// alternate screen. On the alternate screen everything tmux scrolls away is
// lost to the outer terminal, so the Mac app's scrollbar and the browser's
// scrollback had nothing to show; on the normal screen lines that scroll off
// the top land in the outer terminal's own history, where wheel, scrollbar
// and local selection all work.
const tmuxNoAltScreen = ",*:smcup@:rmcup@"

// tmuxAttach execs tmux with args (already shell-quoted). The override is a
// server option and only reaches clients that attach after it is set, so it is
// set ahead of the attach: appended once on a running server (checked first,
// or every connection would append another copy), or as the first command of
// the same invocation when this attach is what starts the server.
func tmuxAttach(args string) string {
	return "if tmux show-options -sv terminal-overrides 2>/dev/null | grep -qF 'smcup@'; then exec tmux -u " + args + "; fi\n" +
		"exec tmux -u start-server \\; set-option -sa terminal-overrides " + shellQuote(tmuxNoAltScreen) + " \\; " + args
}

// agentTmuxSession avoids tmux's separator characters and keeps names stable
// without exposing an arbitrary project name to tmux command parsing.
func agentTmuxSession(project string) string {
	sum := sha256.Sum256([]byte(project))
	return "agent-" + hex.EncodeToString(sum[:])[:12]
}

type terminalRequest struct {
	mode    string
	project string
	// tab names one independent shell. Without it, mode=shell keeps the
	// shared "main" session the browser terminal has always attached to.
	tab string
}

// shellTabRe keeps a client-chosen tab ID to something that is safe in a
// tmux session name and needs no quoting thought anywhere it travels.
var shellTabRe = regexp.MustCompile(`^[A-Za-z0-9-]{1,40}$`)

// shellTmuxSession names the tmux session behind one shell tab. Hashing keeps
// arbitrary project names out of tmux's target syntax, and the "shell-"
// prefix keeps tabs from ever colliding with "main" or an agent session.
func shellTmuxSession(project, tab string) string {
	sum := sha256.Sum256([]byte(project + "\x00" + tab))
	return "shell-" + hex.EncodeToString(sum[:])[:12]
}

// shellTermCommand opens one shell tab: a tmux session of its own, started in
// the project directory, so several tabs can run side by side and each one
// survives a reconnect. -A -D re-attaches the same tab and displaces a stale
// client, exactly like the agent and "main" sessions.
func shellTermCommand(env []string, dir, session string) string {
	cmd := "command -v tmux >/dev/null || { cd " + shellQuote(dir) + " && exec /bin/bash -l; }\n"
	if sync := tmuxEnvSync(env); sync != "" {
		cmd += "{ " + sync + "} >/dev/null 2>&1\n"
	}
	return cmd + tmuxAttach("new-session -A -D -s "+shellQuote(session)+" -c "+shellQuote(dir))
}

func parseTerminalRequest(r *http.Request) (terminalRequest, error) {
	req := terminalRequest{
		mode:    strings.TrimSpace(r.URL.Query().Get("mode")),
		project: strings.TrimSpace(r.URL.Query().Get("project")),
		tab:     strings.TrimSpace(r.URL.Query().Get("tab")),
	}
	if req.mode == "" {
		req.mode = "shell"
	}
	switch req.mode {
	case "shell":
		if req.tab == "" {
			if req.project != "" {
				return terminalRequest{}, fmt.Errorf("项目终端需要 tab")
			}
			return req, nil
		}
		if !shellTabRe.MatchString(req.tab) {
			return terminalRequest{}, fmt.Errorf("终端标签无效")
		}
		if req.project != "" {
			project, ok := validFileName(req.project)
			if !ok {
				return terminalRequest{}, fmt.Errorf("项目名称无效")
			}
			req.project = project
		}
		return req, nil
	case "agent":
		project, ok := validFileName(req.project)
		if !ok {
			return terminalRequest{}, fmt.Errorf("项目名称无效")
		}
		req.project = project
		return req, nil
	default:
		return terminalRequest{}, fmt.Errorf("终端模式无效")
	}
}

// tmuxEnvSync renders the `tmux set-environment` calls mirroring env into the
// tmux global environment. Variables that come and go — the tunnel's, and the
// account's outbound proxy — are unset when absent rather than left alone, so a
// dropped link stops advertising a dead proxy URL to newly opened shells, and
// an unbound account stops routing through a proxy it no longer has.
func tmuxEnvSync(env []string) string {
	var b strings.Builder
	have := make(map[string]bool, len(env))
	for _, kv := range env {
		k, v, ok := strings.Cut(kv, "=")
		if !ok || !validEnvName(k) {
			continue
		}
		have[k] = true
		fmt.Fprintf(&b, "tmux set-environment -g %s %s; ", k, shellQuote(v))
	}
	for _, k := range append(append([]string{}, tunnelEnvNames...), proxyEnvNames...) {
		if !have[k] {
			fmt.Fprintf(&b, "tmux set-environment -gu %s; ", k)
		}
	}
	return b.String()
}

// validEnvName keeps anything that would not survive interpolation out of the
// generated script; account env is admin-edited config, not assumed well-formed.
func validEnvName(s string) bool {
	if s == "" {
		return false
	}
	for i, r := range s {
		switch {
		case r == '_', r >= 'A' && r <= 'Z', r >= 'a' && r <= 'z':
		case i > 0 && r >= '0' && r <= '9':
		default:
			return false
		}
	}
	return true
}

// shellQuote single-quotes s for the bash -c script (embedded quotes are broken
// out and escaped), so a value can never end the quoting and inject commands.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// handleTermWS bridges a browser xterm.js to a TTY exec inside the session
// container. Protocol: binary frames are raw terminal bytes in both
// directions; text frames are JSON control messages ({"type":"resize",...}).
//
// 余额见底的用户进不来。终端里的 claude/codex 是容器内进程，输出直接进 PTY，
// 服务端看不到用量事件，既记不了账也扣不了钱——不挡的话，对话页扣光额度后切到
// 终端手敲一遍就绕过去了。挡的位置在 startSession 之前：没额度的用户连容器都
// 不该被拉起来。
//
// 这一层只挡输入。tmux 里已经跑着的程序断开连接也不会停（detach 不杀进程），
// 真要按量算准还得从中转站侧计量，见 AGENTS.md 的已知缺口。
func (s *Server) handleTermWS(w http.ResponseWriter, r *http.Request, sess store.Session) {
	termReq, err := parseTerminalRequest(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if termReq.project != "" {
		root, err := s.openDataDir(s.workspaceDir(sess))
		if err != nil {
			writeErr(w, http.StatusBadRequest, "工作空间不可用")
			return
		}
		project, err := root.Sub(termReq.project)
		root.Close()
		if err != nil {
			writeErr(w, http.StatusBadRequest, "项目不存在或不是普通目录")
			return
		}
		project.Close()
	}

	if why := s.quotaBlock(sess.User); why != "" {
		// 先升级再关：理由要送到浏览器手里，升级前返回 HTTP 错误它看不见。
		if conn, err := s.upgrader.Upgrade(w, r, nil); err == nil {
			closeWithReason(conn, closeQuota, why)
			conn.Close()
		}
		return
	}

	if _, err := s.sessionAccount(sess); err != nil {
		if conn, upgradeErr := s.upgrader.Upgrade(w, r, nil); upgradeErr == nil {
			closeWithReason(conn, closeAccountAccess, err.Error())
			conn.Close()
		}
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	sess, err = s.startSession(ctx, sess)
	cancel()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "start session: "+err.Error())
		return
	}

	// Attach to a persistent tmux session instead of spawning a bare bash:
	// docker exec detach does NOT kill the process, so a bare shell (and any
	// claude/codex inside) would linger unreachable after a reconnect. With
	// tmux, reconnects land back in the same session, programs survive.
	//   -A  attach if the session exists, create otherwise
	//   -D  detach other clients (last connection wins; a displaced client's
	//       exec exits cleanly, and the frontend treats clean closes as final
	//       rather than auto-reconnecting, so two tabs don't fight)
	// Containers built from pre-tmux images fall back to a plain bash.
	tool := sess.Agent
	launch := ""
	if termReq.mode == "agent" {
		project, projectErr := s.projectByName(sess, termReq.project)
		if projectErr != nil {
			writeErr(w, http.StatusBadRequest, "项目不存在")
			return
		}
		if project.Agent != "" {
			tool = project.Agent
		}
		_, launch = projectLaunch(sess, project)
	}
	env, err := s.execEnvFor(sess, tool, termReq.project)
	if err != nil {
		if conn, upgradeErr := s.upgrader.Upgrade(w, r, nil); upgradeErr == nil {
			closeWithReason(conn, closeAccountAccess, err.Error())
			conn.Close()
		}
		return
	}
	command := termCommand(env)
	workDir := s.containerWorkspace(r.Context(), sess)
	switch {
	case termReq.mode == "agent":
		command = agentTermCommand(env, termReq.project, launch, workDir)
	case termReq.tab != "":
		dir := workDir
		if termReq.project != "" {
			dir = filepath.Join(workDir, termReq.project)
		}
		command = shellTermCommand(env, dir, shellTmuxSession(termReq.project, termReq.tab))
	}
	pty, err := s.dock.ExecPTY(r.Context(), sess.ContainerID, []string{"/bin/bash", "-c", command}, env, workDir)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "exec: "+err.Error())
		return
	}

	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		pty.Close()
		return
	}
	defer conn.Close()
	defer pty.Close()
	release, ok := s.track(func() { _ = conn.Close(); pty.Close() })
	if !ok {
		return
	}
	defer release()

	// An attached terminal runs a live PTY exec inside the container; hold it
	// so the idle reaper can't stop the container out from under the shell.
	s.workspaces().Activity().Hold(sess.ID)
	defer s.workspaces().Activity().Release(sess.ID)

	conn.SetReadDeadline(time.Now().Add(wsPongWait))
	conn.SetPongHandler(func(string) error {
		conn.SetReadDeadline(time.Now().Add(wsPongWait))
		return nil
	})

	done := make(chan struct{})
	pingDone := make(chan struct{})
	defer func() { _ = conn.Close(); pty.Close(); <-done; <-pingDone }()

	// container -> browser
	go func() {
		defer close(done)
		buf := make([]byte, 32<<10)
		for {
			n, err := pty.Reader.Read(buf)
			if n > 0 {
				conn.SetWriteDeadline(time.Now().Add(wsWriteWait))
				if werr := conn.WriteMessage(websocket.BinaryMessage, buf[:n]); werr != nil {
					return
				}
			}
			if err != nil {
				conn.SetWriteDeadline(time.Now().Add(wsWriteWait))
				_ = conn.WriteControl(websocket.CloseMessage,
					websocket.FormatCloseMessage(websocket.CloseNormalClosure, "process exited"),
					time.Now().Add(wsWriteWait))
				return
			}
		}
	}()

	// keepalive pings，顺带巡一遍额度
	go func() {
		defer close(pingDone)
		t := time.NewTicker(wsPingPeriod)
		defer t.Stop()
		for {
			select {
			case <-done:
				return
			case <-t.C:
				if _, err := s.sessionAccount(sess); err != nil {
					closeWithReason(conn, closeAccountAccess, err.Error())
					conn.Close()
					return
				}
				// 余额是在别处（对话页）被扣穿的，挂着的终端不会自己发现。不巡的话
				// 把终端标签页一直开着就绕过了入口检查——那正是这次要堵的洞。代价是
				// 最多晚一个 ping 周期，以及可能打断用户正在敲的东西；人都欠费了，
				// 断开也断不掉 tmux 里跑着的程序，这个取舍认了。
				if why := s.quotaBlock(sess.User); why != "" {
					closeWithReason(conn, closeQuota, why)
					conn.Close() // 读循环随之报错退出，PTY 由它的 defer 收掉
					return
				}
				_ = conn.WriteControl(websocket.PingMessage, nil, time.Now().Add(wsWriteWait))
			}
		}
	}()

	// browser -> container
	for {
		mt, data, err := conn.ReadMessage()
		if err != nil {
			return
		}
		if _, err := s.sessionAccount(sess); err != nil {
			closeWithReason(conn, closeAccountAccess, err.Error())
			return
		}
		switch mt {
		case websocket.BinaryMessage:
			if _, err := pty.Conn.Write(data); err != nil {
				return
			}
		case websocket.TextMessage:
			var ctl struct {
				Type string `json:"type"`
				Cols uint   `json:"cols"`
				Rows uint   `json:"rows"`
			}
			if err := json.Unmarshal(data, &ctl); err == nil && ctl.Type == "resize" && ctl.Cols > 0 && ctl.Rows > 0 {
				if err := s.dock.ResizePTY(r.Context(), pty.ExecID, ctl.Cols, ctl.Rows); err != nil {
					log.Printf("resize %s: %v", sess.ID, err)
				}
			}
		}
	}
}

// handleShellClose ends one shell tab when the client closes it. Without this
// every closed tab would leave its tmux session — and whatever it was running
// — alive in the container forever, since a dropped connection only detaches.
// Best effort: a stopped container or an already-gone session is success.
func (s *Server) handleShellClose(w http.ResponseWriter, r *http.Request, sess store.Session) {
	tab := strings.TrimSpace(r.PathValue("tab"))
	if !shellTabRe.MatchString(tab) {
		writeErr(w, http.StatusBadRequest, "终端标签无效")
		return
	}
	project := strings.TrimSpace(r.URL.Query().Get("project"))
	if project != "" {
		name, ok := validFileName(project)
		if !ok {
			writeErr(w, http.StatusBadRequest, "项目名称无效")
			return
		}
		project = name
	}
	if s.dock != nil && sess.ContainerID != "" {
		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
		_, _ = s.dock.ExecCapture(ctx, sess.ContainerID,
			[]string{"tmux", "kill-session", "-t", "=" + shellTmuxSession(project, tab)}, nil, "")
		cancel()
	}
	w.WriteHeader(http.StatusNoContent)
}
