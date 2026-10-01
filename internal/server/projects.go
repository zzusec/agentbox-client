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
	Agent     string    `json:"agent"`
	Path      string    `json:"path"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

func (s *Server) projectView(sess store.Session, project store.SyncProject) projectView {
	path := project.Path
	if path == "" {
		// Pre-v11 row (or a row whose instance directory moved): derive it so
		// the client always sees an absolute, container-valid path.
		path = filepath.Join(s.workspaceDir(sess), project.Name)
	}
	return projectView{
		ID: project.ID, Name: project.Name, Agent: project.Agent, Path: path,
		CreatedAt: project.CreatedAt, UpdatedAt: project.UpdatedAt,
	}
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
		Name string `json:"name"`
		// Agent is optional; when absent the project keeps its current tool.
		Agent *string `json:"agent"`
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
	agent := ""
	if req.Agent != nil {
		chosen, err := validProjectAgent(sess, *req.Agent)
		if err != nil {
			writeErr(w, http.StatusBadRequest, err.Error())
			return
		}
		agent = chosen
	}
	root, err := s.openDataDir(s.workspaceDir(sess))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer root.Close()
	if err := root.RenameTo(project.Name, root, name, false); err != nil {
		status := http.StatusInternalServerError
		if os.IsExist(err) {
			status = http.StatusConflict
		}
		writeErr(w, status, err.Error())
		return
	}
	updated, err := s.store.RenameSyncProject(project.ID, name)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if req.Agent != nil {
		if updated, err = s.store.SetSyncProjectAgent(updated.ID, agent); err != nil {
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
