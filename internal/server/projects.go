package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"agentbox/internal/dockerx"
	"agentbox/internal/safefs"
	"agentbox/internal/store"
)

type projectView struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Path      string    `json:"path"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

func (s *Server) projectView(project store.SyncProject) projectView {
	return projectView{
		ID: project.ID, Name: project.Name, Path: "/workspace/" + project.Name,
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
	projects, err := s.store.ReconcileSyncProjects(sess.ID, names)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	out := make([]projectView, 0, len(projects))
	for _, project := range projects {
		out = append(out, s.projectView(project))
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleProjectCreate(w http.ResponseWriter, r *http.Request, sess store.Session) {
	var req struct {
		Name string `json:"name"`
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
	projects, err := s.store.ReconcileSyncProjects(sess.ID, names)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	for _, project := range projects {
		if project.Name == name {
			writeJSON(w, http.StatusCreated, s.projectView(project))
			return
		}
	}
	writeErr(w, http.StatusInternalServerError, "项目注册失败")
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
	writeJSON(w, http.StatusOK, s.projectView(updated))
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
