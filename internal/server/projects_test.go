package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestProjectLifecycleRegistryAndTrash(t *testing.T) {
	s, sess := newTestServer(t)

	create := httptest.NewRecorder()
	s.handleProjectCreate(
		create,
		accessRequest(sess.User, http.MethodPost, "/projects", `{"name":"alpha"}`),
		sess,
	)
	if create.Code != http.StatusCreated {
		t.Fatalf("create status = %d body=%s", create.Code, create.Body.String())
	}
	var project projectView
	if err := json.Unmarshal(create.Body.Bytes(), &project); err != nil {
		t.Fatal(err)
	}
	// The project path is the absolute host path, which is also the path
	// inside the container — that identity is the whole point of v11.
	wantPath := filepath.Join(s.workspaceDir(sess), "alpha")
	if project.ID == "" || project.Path != wantPath {
		t.Fatalf("project = %+v want path %q", project, wantPath)
	}

	list := httptest.NewRecorder()
	s.handleProjectList(list, accessRequest(sess.User, http.MethodGet, "/projects", ""), sess)
	if list.Code != http.StatusOK {
		t.Fatalf("list status = %d body=%s", list.Code, list.Body.String())
	}
	var projects []projectView
	if err := json.Unmarshal(list.Body.Bytes(), &projects); err != nil {
		t.Fatal(err)
	}
	if len(projects) != 1 || projects[0].ID != project.ID {
		t.Fatalf("listed projects = %+v", projects)
	}

	renameReq := accessRequest(sess.User, http.MethodPatch, "/projects/"+project.ID, `{"name":"renamed"}`)
	renameReq.SetPathValue("project", project.ID)
	rename := httptest.NewRecorder()
	s.handleProjectRename(rename, renameReq, sess)
	if rename.Code != http.StatusOK {
		t.Fatalf("rename status = %d body=%s", rename.Code, rename.Body.String())
	}
	if _, err := os.Stat(filepath.Join(s.workspaceDir(sess), "renamed")); err != nil {
		t.Fatalf("renamed directory missing: %v", err)
	}

	deleteReq := accessRequest(sess.User, http.MethodDelete, "/projects/"+project.ID, "")
	deleteReq.SetPathValue("project", project.ID)
	deleted := httptest.NewRecorder()
	s.handleProjectDelete(deleted, deleteReq, sess)
	if deleted.Code != http.StatusOK {
		t.Fatalf("delete status = %d body=%s", deleted.Code, deleted.Body.String())
	}
	if _, err := os.Stat(filepath.Join(s.workspaceDir(sess), "renamed")); !os.IsNotExist(err) {
		t.Fatalf("project still in workspace: %v", err)
	}
	entries, err := os.ReadDir(filepath.Join(s.cfg.DataDir, "users", sess.User, "sync-trash", sess.ID))
	if err != nil || len(entries) != 1 {
		t.Fatalf("trash entries=%v err=%v", entries, err)
	}
}
