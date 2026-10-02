package server

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"agentbox/internal/config"
	"agentbox/internal/dockerx"
	"agentbox/internal/safefs"
	"agentbox/internal/store"
)

type projectView struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// Agent is the tool this project is developed with. Empty means "inherit
	// the instance default".
	Agent string `json:"agent"`
	Path  string `json:"path"`
	// Command is what the project terminal runs, with the default already
	// filled in; Custom says whether it was set explicitly, and
	// DefaultCommand is what an empty command falls back to for this agent.
	Command        string    `json:"command"`
	DefaultCommand string    `json:"default_command"`
	Custom         bool      `json:"custom_command"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
}

func (s *Server) projectView(sess store.Session, project store.SyncProject) projectView {
	path := project.Path
	if path == "" {
		// Pre-v11 row (or a row whose instance directory moved): derive it so
		// the client always sees an absolute, container-valid path.
		path = filepath.Join(s.workspaceDir(sess), project.Name)
	}
	tool, command := projectLaunch(sess, project)
	return projectView{
		ID: project.ID, Name: project.Name, Agent: project.Agent, Path: path,
		Command: command, DefaultCommand: defaultLaunchCommand(tool),
		Custom:    strings.TrimSpace(project.Command) != "",
		CreatedAt: project.CreatedAt, UpdatedAt: project.UpdatedAt,
	}
}

// Default launch commands. A project terminal is meant to run unattended
// next to a synced local checkout, so the agents start without per-action
// approval prompts; the container (non-root, no-new-privileges, fixed mounts)
// is the boundary. A project stores its own command to opt out.
const (
	defaultClaudeCommand = "claude --dangerously-skip-permissions"
	defaultCodexCommand  = "codex --yolo"
	maxLaunchCommand     = 1024
)

func defaultLaunchCommand(tool string) string {
	if tool == config.AgentCodex {
		return defaultCodexCommand
	}
	return defaultClaudeCommand
}

// projectLaunch resolves which tool a project terminal runs and the command
// that starts it: the project's own agent and command when set, otherwise the
// instance default tool with that tool's default command. A directory made
// inside the container has no row yet and simply gets the defaults.
func projectLaunch(sess store.Session, project store.SyncProject) (tool, command string) {
	tool = project.Agent
	if tool == "" {
		tool = sess.Agent
	}
	if tool != config.AgentCodex {
		tool = config.AgentClaude
	}
	command = strings.TrimSpace(project.Command)
	if command == "" {
		command = defaultLaunchCommand(tool)
	}
	return tool, command
}

// validLaunchCommand checks a launch command before it is stored.
//
// The command runs under bash in the instance container as the agent user,
// which anyone who can open this project's terminal can already do by typing.
// What the check protects is the generated tmux script: a newline or other
// control character would end the quoted argument and run text outside it.
func validLaunchCommand(command string) (string, error) {
	command = strings.TrimSpace(command)
	if len(command) > maxLaunchCommand {
		return "", fmt.Errorf("启动命令不能超过 %d 字节", maxLaunchCommand)
	}
	if !utf8.ValidString(command) {
		return "", errors.New("启动命令不是有效的 UTF-8")
	}
	for _, r := range command {
		if unicode.IsControl(r) {
			return "", errors.New("启动命令不能包含换行或控制字符")
		}
	}
	return command, nil
}

// normalizeLaunchCommand stores the agent's own default as empty, so
// "custom" means something and an untouched project follows future defaults.
func normalizeLaunchCommand(sess store.Session, agent, command string) string {
	tool, _ := projectLaunch(sess, store.SyncProject{Agent: agent})
	if command == defaultLaunchCommand(tool) {
		return ""
	}
	return command
}

func (s *Server) handleProjectList(w http.ResponseWriter, r *http.Request, sess store.Session) {
	root, err := s.openDataDir(s.workspaceDir(sess))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer root.Close()
	names, err := projectDirectoryNames(root)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	projects, err := s.store.ReconcileSyncProjects(sess.ID, s.workspaceDir(sess), names)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	out := make([]projectView, 0, len(projects))
	for _, project := range projects {
		out = append(out, s.projectView(sess, project))
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleProjectCreate(w http.ResponseWriter, r *http.Request, sess store.Session) {
	var req struct {
		Name string `json:"name"`
		// Agent pins the tool for this project. Omitted or empty means
		// "whatever the instance defaults to".
		Agent string `json:"agent"`
		// Command overrides the launch command. Omitted, empty or equal to
		// the agent's default means "use the default".
		Command string `json:"command"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10)).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "请求体格式错误")
		return
	}
	name, ok := validFileName(req.Name)
	if !ok || strings.HasPrefix(name, ".") {
		writeErr(w, http.StatusBadRequest, "项目名称无效")
		return
	}
	agent, err := validProjectAgent(sess, req.Agent)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	// Checked before the directory exists, so a bad command cannot leave an
	// unconfigured project behind.
	command, err := validLaunchCommand(req.Command)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	command = normalizeLaunchCommand(sess, agent, command)
	root, err := s.openDataDir(s.workspaceDir(sess))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer root.Close()
	if err := root.Mkdir(name, 0o755); err != nil {
		status := http.StatusInternalServerError
		if os.IsExist(err) {
			status = http.StatusConflict
		}
		writeErr(w, status, err.Error())
		return
	}
	_ = root.Chown(name, dockerx.AgentUID, dockerx.AgentGID)
	names, err := projectDirectoryNames(root)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	projects, err := s.store.ReconcileSyncProjects(sess.ID, s.workspaceDir(sess), names)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	for _, project := range projects {
		if project.Name == name {
			if agent != "" {
				if project, err = s.store.SetSyncProjectAgent(project.ID, agent); err != nil {
					writeErr(w, http.StatusInternalServerError, err.Error())
					return
				}
			}
			if command != "" {
				if project, err = s.store.SetSyncProjectCommand(project.ID, command); err != nil {
					writeErr(w, http.StatusInternalServerError, err.Error())
					return
				}
			}
			writeJSON(w, http.StatusCreated, s.projectView(sess, project))
			return
		}
	}
	writeErr(w, http.StatusInternalServerError, "项目注册失败")
}

// validProjectAgent checks a requested project tool against the accounts the
// instance actually has. A project cannot be pinned to a tool whose account the
// instance does not carry: the terminal would start with no credentials.
func validProjectAgent(sess store.Session, agent string) (string, error) {
	if agent == "" {
		return "", nil
	}
	if agent != config.AgentClaude && agent != config.AgentCodex {
		return "", errors.New("开发工具只能是 claude 或 codex")
	}
	if !sess.HasTool(agent) {
		name := "Codex"
		if agent == config.AgentClaude {
			name = "Claude"
		}
		return "", fmt.Errorf("该实例未绑定 %s 账号，不能把项目指定为 %s", name, agent)
	}
	return agent, nil
}

func (s *Server) handleProjectRename(w http.ResponseWriter, r *http.Request, sess store.Session) {
	projectID := r.PathValue("project")
	project, ok := s.store.SyncProject(projectID)
	if !ok || project.SessionID != sess.ID {
		writeErr(w, http.StatusNotFound, "项目不存在")
		return
	}
	var req struct {
		// Name renames the project. It may be omitted (or repeat the current
		// name) when the request only changes the agent or command.
		Name string `json:"name"`
		// Agent is optional; when absent the project keeps its current tool.
		Agent *string `json:"agent"`
		// Command is optional; empty restores the agent's default.
		Command *string `json:"command"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10)).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "请求体格式错误")
		return
	}
	name := project.Name
	if strings.TrimSpace(req.Name) != "" || (req.Agent == nil && req.Command == nil) {
		var ok bool
		name, ok = validFileName(req.Name)
		if !ok || strings.HasPrefix(name, ".") {
			writeErr(w, http.StatusBadRequest, "项目名称无效")
			return
		}
	}
	agent := project.Agent
	if req.Agent != nil {
		chosen, err := validProjectAgent(sess, *req.Agent)
		if err != nil {
			writeErr(w, http.StatusBadRequest, err.Error())
			return
		}
		agent = chosen
	}
	command := project.Command
	if req.Command != nil {
		chosen, err := validLaunchCommand(*req.Command)
		if err != nil {
			writeErr(w, http.StatusBadRequest, err.Error())
			return
		}
		command = chosen
	}
	command = normalizeLaunchCommand(sess, agent, command)

	updated := project
	if name != project.Name {
		root, err := s.openDataDir(s.workspaceDir(sess))
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		err = root.RenameTo(project.Name, root, name, false)
		root.Close()
		if err != nil {
			status := http.StatusInternalServerError
			if os.IsExist(err) {
				status = http.StatusConflict
			}
			writeErr(w, status, err.Error())
			return
		}
		if updated, err = s.store.RenameSyncProject(project.ID, name); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	var err error
	if agent != updated.Agent {
		if updated, err = s.store.SetSyncProjectAgent(updated.ID, agent); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	if command != updated.Command {
		if updated, err = s.store.SetSyncProjectCommand(updated.ID, command); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	writeJSON(w, http.StatusOK, s.projectView(sess, updated))
}

func (s *Server) handleProjectDelete(w http.ResponseWriter, r *http.Request, sess store.Session) {
	projectID := r.PathValue("project")
	project, ok := s.store.SyncProject(projectID)
	if !ok || project.SessionID != sess.ID {
		writeErr(w, http.StatusNotFound, "项目不存在")
		return
	}
	source, err := s.openDataDir(s.workspaceDir(sess))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer source.Close()
	trashParent := filepath.Join(s.cfg.DataDir, "users", sess.User, "sync-trash")
	trashBase, err := safefs.Open(trashParent)
	if os.IsNotExist(err) {
		if mkerr := os.MkdirAll(trashParent, 0o700); mkerr != nil {
			writeErr(w, http.StatusInternalServerError, mkerr.Error())
			return
		}
		trashBase, err = safefs.Open(trashParent)
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer trashBase.Close()
	sessionTrash := filepath.Join(sess.ID)
	if err := trashBase.MkdirAll(sessionTrash, 0o700); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	trash, err := trashBase.Sub(sessionTrash)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer trash.Close()
	trashName := fmt.Sprintf("%s-%d", project.Name, time.Now().UnixNano())
	if err := source.RenameTo(project.Name, trash, trashName, false); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if err := s.store.DeleteSyncProject(project.ID); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"trash_id": filepath.ToSlash(filepath.Join(sessionTrash, trashName))})
}

func projectDirectoryNames(root *safefs.Root) ([]string, error) {
	entries, err := root.ReadDir(".")
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() || strings.HasPrefix(entry.Name(), ".") {
			continue
		}
		if _, err := root.Sub(entry.Name()); err != nil {
			continue
		}
		names = append(names, entry.Name())
	}
	sort.Strings(names)
	return names, nil
}
