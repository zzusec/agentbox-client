package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"path/filepath"
	"strings"
	"time"

	"agentbox/internal/config"
	"agentbox/internal/dockerx"
	"agentbox/internal/store"
	"agentbox/internal/workspace"
)

func (s *Server) sessionDir(sess store.Session) string {
	return workspace.SessionDir(s.cfg.DataDir, sess)
}

func (s *Server) workspaceDir(sess store.Session) string {
	return filepath.Join(s.sessionDir(sess), "workspace")
}

func (s *Server) containerWorkspace(ctx context.Context, sess store.Session) string {
	path := s.workspaceDir(sess)
	if s.dock != nil && !s.dock.RunningWithMount(ctx, sess.ContainerID, path) {
		return dockerx.WorkspaceMount
	}
	return path
}

func (s *Server) homeDir(sess store.Session) string {
	return filepath.Join(s.sessionDir(sess), "home")
}

func (s *Server) chatLogPath(sess store.Session) string {
	return filepath.Join(s.sessionDir(sess), "chat.jsonl")
}

// homeTemplateDir is the server-wide skeleton overlaid onto every session home
// on start (skills, user-scope MCP servers, rc files). Empty or absent =
// feature off; see agent.SeedHomeTemplate for the merge rules.
func (s *Server) homeTemplateDir() string {
	return filepath.Join(s.cfg.DataDir, "home-template")
}

// userTemplateDir is the same idea scoped to one user, layered on top of the
// server-wide template. It is what the 技能 tab writes to, so a user can push
// something to all of their own sessions without touching everyone else's.
func (s *Server) userTemplateDir(user string) string {
	return filepath.Join(s.cfg.DataDir, "users", user, "home-template")
}

// ensureSharedDir creates (idempotently) the per-user shared directory that is
// bind-mounted into every session container at /shared.
func (s *Server) ensureSharedDir(user string) (string, error) {
	return s.workspaces().EnsureSharedDir(user)
}

type sessionView struct {
	store.Session
	AccountLabel       string `json:"account_label"`
	ClaudeAccountLabel string `json:"claude_account_label,omitempty"`
	CodexAccountLabel  string `json:"codex_account_label,omitempty"`
	ProxyLabel         string `json:"proxy_label,omitempty"`
	// DefaultAgent mirrors Agent under the instance vocabulary so newer
	// clients do not have to know the old column name.
	DefaultAgent  string `json:"default_agent"`
	WorkspacePath string `json:"workspace_path"`
}

func (s *Server) view(sess store.Session) sessionView {
	label := func(id string) string {
		if id == "" {
			return ""
		}
		if a, ok := s.cfg.Account(id); ok {
			return a.Label
		}
		return id
	}
	legacy := label(sess.AccountID)
	proxyLabel := sess.ProxyID
	if p, ok := s.cfg.Proxy(sess.ProxyID); ok {
		proxyLabel = p.Name
	}
	if sess.ProxyID == "" {
		proxyLabel = ""
	}
	return sessionView{
		Session:            sess,
		AccountLabel:       legacy,
		ClaudeAccountLabel: label(sess.ClaudeAccountID),
		CodexAccountLabel:  label(sess.CodexAccountID),
		ProxyLabel:         proxyLabel,
		DefaultAgent:       sess.Agent,
		WorkspacePath:      s.workspaceDir(sess),
	}
}

func (s *Server) handleListSessions(w http.ResponseWriter, r *http.Request) {
	out := []sessionView{}
	for _, sess := range s.store.List(reqUser(r).Name) {
		out = append(out, s.view(sess))
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleGetSession(w http.ResponseWriter, r *http.Request, sess store.Session) {
	writeJSON(w, http.StatusOK, s.view(sess))
}

// createSessionRequest is the instance creation payload. The legacy pair
// (agent + account_id) is still accepted: older clients, the macOS app and
// abox-sync predate the instance model and must keep working.
type createSessionRequest struct {
	Name      string `json:"name"`
	Agent     string `json:"agent"`
	AccountID string `json:"account_id"`

	ClaudeAccountID string `json:"claude_account_id"`
	CodexAccountID  string `json:"codex_account_id"`
	// ProxyID is mandatory. An instance without a usable exit would leak the
	// server's own IP, so it is refused rather than defaulted.
	ProxyID string `json:"proxy_id"`
	// DefaultAgent picks which tool a new project starts with. Optional: it
	// defaults to claude when a claude account is bound, else codex.
	DefaultAgent    string  `json:"default_agent"`
	GitConnectionID *string `json:"git_connection_id"`
}

// resolveInstanceAccounts folds the legacy single-account pair into the
// per-tool columns and validates every binding.
func (s *Server) resolveInstanceAccounts(w http.ResponseWriter, r *http.Request, req createSessionRequest) (claudeID, codexID, defaultAgent string, ok bool) {
	claudeID, codexID = req.ClaudeAccountID, req.CodexAccountID
	if req.AccountID != "" {
		acct, found := s.cfg.Account(req.AccountID)
		if !found {
			writeErr(w, http.StatusBadRequest, "unknown account_id")
			return "", "", "", false
		}
		// The legacy pair only fills a column the caller left empty, so a
		// client that sends both spellings is not silently overridden.
		if acct.Type == config.AgentClaude && claudeID == "" {
			claudeID = req.AccountID
		}
		if acct.Type == config.AgentCodex && codexID == "" {
			codexID = req.AccountID
		}
	}
	if claudeID == "" && codexID == "" {
		writeErr(w, http.StatusBadRequest, "实例至少需要绑定一个账号")
		return "", "", "", false
	}
	for _, b := range []struct {
		tool string
		id   string
	}{{config.AgentClaude, claudeID}, {config.AgentCodex, codexID}} {
		if b.id == "" {
			continue
		}
		acct, found := s.cfg.Account(b.id)
		if !found {
			writeErr(w, http.StatusBadRequest, "unknown account_id "+b.id)
			return "", "", "", false
		}
		if acct.Type != b.tool {
			writeErr(w, http.StatusBadRequest, "account type does not match agent type")
			return "", "", "", false
		}
		if !acct.CanUse(reqUser(r).Name, reqUser(r).Role == store.RoleAdmin) {
			writeErr(w, http.StatusForbidden, errAccountAccess.Error())
			return "", "", "", false
		}
	}
	defaultAgent = req.DefaultAgent
	if defaultAgent == "" {
		defaultAgent = req.Agent
	}
	if defaultAgent == "" {
		if claudeID != "" {
			defaultAgent = config.AgentClaude
		} else {
			defaultAgent = config.AgentCodex
		}
	}
	if defaultAgent != config.AgentClaude && defaultAgent != config.AgentCodex {
		writeErr(w, http.StatusBadRequest, "default_agent must be claude or codex")
		return "", "", "", false
	}
	// The default tool has to be one the instance can actually run, otherwise
	// its first project would start with no credentials.
	if defaultAgent == config.AgentClaude && claudeID == "" {
		writeErr(w, http.StatusBadRequest, "默认开发工具为 claude，但实例未绑定 Claude 账号")
		return "", "", "", false
	}
	if defaultAgent == config.AgentCodex && codexID == "" {
		writeErr(w, http.StatusBadRequest, "默认开发工具为 codex，但实例未绑定 Codex 账号")
		return "", "", "", false
	}
	return claudeID, codexID, defaultAgent, true
}

// resolveInstanceProxy validates the optional exit proxy for an instance. An
// empty id means direct egress unless the operator made proxies mandatory.
func (s *Server) resolveInstanceProxy(w http.ResponseWriter, proxyID string) (string, bool) {
	if proxyID == "" {
		if s.cfg.RequireInstanceProxy() {
			writeErr(w, http.StatusBadRequest, "请为实例选择出口住宅代理")
			return "", false
		}
		return "", true
	}
	p, found := s.cfg.Proxy(proxyID)
	if !found {
		writeErr(w, http.StatusBadRequest, "unknown proxy_id")
		return "", false
	}
	if p.Disabled {
		writeErr(w, http.StatusBadRequest, "该代理已停用")
		return "", false
	}
	// New instances must state that the exit is residential. An unlabelled
	// proxy is a pool that predates the field; it stays valid for instances
	// that already used it, but a fresh binding has to be explicit.
	if p.Kind != config.ProxyKindResidential {
		writeErr(w, http.StatusBadRequest, "该代理未标注为住宅代理，不能用于新实例")
		return "", false
	}
	return proxyID, true
}

func (s *Server) handleCreateSession(w http.ResponseWriter, r *http.Request) {
	var req createSessionRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if req.Name == "" || len(req.Name) > 64 {
		writeErr(w, http.StatusBadRequest, "name is required (max 64 chars)")
		return
	}
	claudeID, codexID, defaultAgent, ok := s.resolveInstanceAccounts(w, r, req)
	if !ok {
		return
	}
	instanceBindMu.Lock()
	defer instanceBindMu.Unlock()
	if !s.requireAccountsFree(w, r, "", claudeID, codexID) {
		return
	}
	proxyID, ok := s.resolveInstanceProxy(w, req.ProxyID)
	if !ok {
		return
	}

	gitConnection := ""
	if req.GitConnectionID != nil {
		gitConnection = *req.GitConnectionID
	} else {
		var err error
		gitConnection, err = s.store.GitDefault(reqUser(r).Name, "")
		if err != nil {
			writeGitStoreErr(w, err)
			return
		}
	}
	if gitConnection != "" {
		c, err := s.store.GitConnectionFor(reqUser(r).Name, gitConnection)
		if err != nil {
			writeGitStoreErr(w, err)
			return
		}
		if !c.Enabled {
			writeErr(w, 409, "默认 Git 连接已停用，请选择其他连接或不绑定")
			return
		}
	}
	// AccountID mirrors the default tool's account. It is what pre-instance
	// clients read, and what an emergency rollback would fall back to, so it
	// must never point at a tool the instance cannot run.
	legacyAccount := claudeID
	if defaultAgent == config.AgentCodex {
		legacyAccount = codexID
	}
	sess := store.Session{
		ID:                 store.NewID(),
		User:               reqUser(r).Name,
		Name:               req.Name,
		Agent:              defaultAgent,
		AccountID:          legacyAccount,
		ClaudeAccountID:    claudeID,
		CodexAccountID:     codexID,
		ProxyID:            proxyID,
		DefaultModel:       s.cfg.GetDefaultModel(defaultAgent),
		DefaultModelClaude: s.cfg.GetDefaultModel(config.AgentClaude),
		DefaultModelCodex:  s.cfg.GetDefaultModel(config.AgentCodex),
		Status:             store.StatusStopped,
		CreatedAt:          time.Now(),
	}
	if err := s.workspaces().CreateWithGitConnection(sess, gitConnection); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, s.view(sess))
}

// startSession is the idempotent bring-up used by the REST endpoint and by
// the chat/terminal channels (which auto-start stopped sessions).
func (s *Server) startSession(ctx context.Context, sess store.Session) (store.Session, error) {
	return s.workspaces().Start(ctx, sess.ID)
}

var (
	errSessionGone = workspace.ErrSessionGone
	errAccountGone = jsonError("account referenced by session is gone from config")
)

type jsonError string

func (e jsonError) Error() string { return string(e) }

func (s *Server) handleStartSession(w http.ResponseWriter, r *http.Request, sess store.Session) {
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	updated, err := s.startSession(ctx, sess)
	if err != nil {
		status := http.StatusInternalServerError
		if errors.Is(err, workspace.ErrCapacity) {
			status = http.StatusTooManyRequests
		}
		if err == errAccountAccess {
			status = http.StatusForbidden
		}
		if errors.Is(err, errInstanceProxy) {
			status = http.StatusConflict
		}
		writeErr(w, status, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, s.view(updated))
}

// handleRenameSession is the instance update endpoint. Name is the common case
// (the id, directories and container name are all derived from the id, so a
// rename touches nothing else), but the same PATCH also re-binds accounts, the
// exit proxy and the default tool.
//
// Every field is a pointer so an omitted one keeps its stored value; the web
// client patches one thing at a time. Account bindings are only re-validated
// when the request actually touches them, so a plain rename of a row that has
// not been through the v11 backfill cannot be rejected for "no account".
func (s *Server) handleRenameSession(w http.ResponseWriter, r *http.Request, sess store.Session) {
	err := s.workspaces().WithSession(r.Context(), sess.ID, func(current store.Session) error {
		s.patchInstance(w, r, current)
		return nil
	})
	if err != nil {
		writeErr(w, http.StatusConflict, err.Error())
	}
}

func (s *Server) patchInstance(w http.ResponseWriter, r *http.Request, sess store.Session) {
	var req struct {
		Name            *string `json:"name"`
		ClaudeAccountID *string `json:"claude_account_id"`
		CodexAccountID  *string `json:"codex_account_id"`
		ProxyID         *string `json:"proxy_id"`
		DefaultAgent    *string `json:"default_agent"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10)).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "请求体格式错误")
		return
	}
	if req.Name != nil {
		name := strings.TrimSpace(*req.Name)
		if name == "" || len([]rune(name)) > 64 {
			writeErr(w, http.StatusBadRequest, "实例名称需为 1-64 个字符")
			return
		}
	}
	changesBinding := req.ClaudeAccountID != nil && *req.ClaudeAccountID != sess.AccountForTool(config.AgentClaude) ||
		req.CodexAccountID != nil && *req.CodexAccountID != sess.AccountForTool(config.AgentCodex) ||
		req.ProxyID != nil && *req.ProxyID != sess.ProxyID ||
		req.DefaultAgent != nil && *req.DefaultAgent != sess.Agent
	if changesBinding && sess.ContainerID != "" {
		if s.dock == nil {
			writeErr(w, http.StatusConflict, "无法确认容器已停止，暂不允许修改实例绑定")
			return
		}
		running, err := s.dock.Running(r.Context(), sess.ContainerID)
		if err != nil || running {
			writeErr(w, http.StatusConflict, "请先停止实例，再修改账号、代理或默认工具；现有容器不会被重建")
			return
		}
	}
	// Resolve the prospective bindings before writing anything, so a rejected
	// patch leaves the row untouched rather than half-applied.
	claudeID, codexID := sess.AccountForTool(config.AgentClaude), sess.AccountForTool(config.AgentCodex)
	if req.ClaudeAccountID != nil {
		claudeID = strings.TrimSpace(*req.ClaudeAccountID)
	}
	if req.CodexAccountID != nil {
		codexID = strings.TrimSpace(*req.CodexAccountID)
	}
	defaultAgent := sess.Agent
	touchesTool := req.ClaudeAccountID != nil || req.CodexAccountID != nil || req.DefaultAgent != nil
	if touchesTool {
		requestedDefault := sess.Agent
		if req.DefaultAgent != nil {
			requestedDefault = *req.DefaultAgent
		}
		_, _, resolved, ok := s.resolveInstanceAccounts(w, r, createSessionRequest{
			Agent:           sess.Agent,
			ClaudeAccountID: claudeID,
			CodexAccountID:  codexID,
			DefaultAgent:    requestedDefault,
		})
		if !ok {
			return
		}
		defaultAgent = resolved
		// Only a newly attached account is checked: an instance that already
		// shares one from before the rule can still change its proxy or name.
		var added []string
		if claudeID != sess.AccountForTool(config.AgentClaude) {
			added = append(added, claudeID)
		}
		if codexID != sess.AccountForTool(config.AgentCodex) {
			added = append(added, codexID)
		}
		instanceBindMu.Lock()
		defer instanceBindMu.Unlock()
		if !s.requireAccountsFree(w, r, sess.ID, added...) {
			return
		}
	}
	if req.DefaultAgent != nil {
		v := strings.TrimSpace(*req.DefaultAgent)
		if v != config.AgentClaude && v != config.AgentCodex {
			writeErr(w, http.StatusBadRequest, "default_agent must be claude or codex")
			return
		}
		if v == config.AgentClaude && claudeID == "" {
			writeErr(w, http.StatusBadRequest, "默认开发工具为 claude，但实例未绑定 Claude 账号")
			return
		}
		if v == config.AgentCodex && codexID == "" {
			writeErr(w, http.StatusBadRequest, "默认开发工具为 codex，但实例未绑定 Codex 账号")
			return
		}
		defaultAgent = v
	}
	if touchesTool {
		projects, err := s.store.SyncProjects(sess.ID)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		for _, project := range projects {
			if project.Agent == config.AgentClaude && claudeID == "" || project.Agent == config.AgentCodex && codexID == "" {
				writeErr(w, http.StatusConflict, "仍有项目使用该账号的开发工具，请先调整项目设置")
				return
			}
		}
	}
	proxyID := sess.ProxyID
	if req.ProxyID != nil {
		v := strings.TrimSpace(*req.ProxyID)
		if v == "" && s.cfg.RequireInstanceProxy() {
			writeErr(w, http.StatusBadRequest, "实例必须绑定出口代理")
			return
		}
		// Re-binding an existing instance may keep a proxy it already had,
		// including an unlabelled one from before the kind field existed. Any
		// other proxy has to pass the new-instance rules.
		if v != sess.ProxyID {
			if _, ok := s.resolveInstanceProxy(w, v); !ok {
				return
			}
		}
		proxyID = v
	}
	legacyAccount := claudeID
	if defaultAgent == config.AgentCodex {
		legacyAccount = codexID
	}
	updated, err := s.store.Update(sess.ID, func(x *store.Session) {
		if req.Name != nil {
			x.Name = strings.TrimSpace(*req.Name)
		}
		// Bindings are only rewritten when the request asked for it. A bare
		// rename of a row that has not been through the backfill must not blank
		// its legacy account column.
		if touchesTool {
			x.ClaudeAccountID = claudeID
			x.CodexAccountID = codexID
			x.Agent = defaultAgent
			x.AccountID = legacyAccount
		}
		x.ProxyID = proxyID
		if x.DefaultModelClaude == "" {
			x.DefaultModelClaude = s.cfg.GetDefaultModel(config.AgentClaude)
		}
		if x.DefaultModelCodex == "" {
			x.DefaultModelCodex = s.cfg.GetDefaultModel(config.AgentCodex)
		}
	})
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, s.view(updated))
}

func (s *Server) handleStopSession(w http.ResponseWriter, r *http.Request, sess store.Session) {
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	updated, err := s.workspaces().Stop(ctx, sess.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, s.view(updated))
}
func (s *Server) handleDeleteSession(w http.ResponseWriter, r *http.Request, sess store.Session) {
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	if err := s.workspaces().Delete(ctx, sess.ID, r.URL.Query().Get("purge") == "1"); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"deleted": true})
}
