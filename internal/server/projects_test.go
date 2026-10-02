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

func TestProjectLaunchCommand(t *testing.T) {
	s, sess := newTestServer(t)
	sess.Agent = "claude"
	sess.ClaudeAccountID = "claude-1"
	sess.CodexAccountID = "codex-1"

	create := func(body string) (int, projectView) {
		t.Helper()
		rec := httptest.NewRecorder()
		s.handleProjectCreate(rec, accessRequest(sess.User, http.MethodPost, "/projects", body), sess)
		var view projectView
		_ = json.Unmarshal(rec.Body.Bytes(), &view)
		return rec.Code, view
	}
	update := func(id, body string) (int, projectView) {
		t.Helper()
		req := accessRequest(sess.User, http.MethodPatch, "/projects/"+id, body)
		req.SetPathValue("project", id)
		rec := httptest.NewRecorder()
		s.handleProjectRename(rec, req, sess)
		var view projectView
		_ = json.Unmarshal(rec.Body.Bytes(), &view)
		return rec.Code, view
	}

	code, plain := create(`{"name":"plain"}`)
	if code != http.StatusCreated || plain.Command != "claude --dangerously-skip-permissions" || plain.Custom {
		t.Fatalf("plain = %d %+v", code, plain)
	}
	code, codex := create(`{"name":"codexy","agent":"codex"}`)
	if code != http.StatusCreated || codex.Command != "codex --yolo" || codex.DefaultCommand != "codex --yolo" || codex.Custom {
		t.Fatalf("codex = %d %+v", code, codex)
	}
	// Sending the default verbatim is stored as "follow the default".
	code, explicit := create(`{"name":"explicit","agent":"codex","command":"codex --yolo"}`)
	if code != http.StatusCreated || explicit.Custom {
		t.Fatalf("explicit = %d %+v", code, explicit)
	}
	if row, _ := s.store.SyncProject(explicit.ID); row.Command != "" {
		t.Fatalf("default stored verbatim: %+v", row)
	}

	// Command-only update: no name needed, nothing renamed.
	code, custom := update(codex.ID, `{"command":"codex --model gpt-5.5 --yolo"}`)
	if code != http.StatusOK || !custom.Custom || custom.Command != "codex --model gpt-5.5 --yolo" || custom.Name != "codexy" {
		t.Fatalf("custom = %d %+v", code, custom)
	}
	// Switching agent keeps a custom command; clearing it restores the
	// new agent's default.
	code, switched := update(codex.ID, `{"agent":"claude","command":""}`)
	if code != http.StatusOK || switched.Custom || switched.Command != "claude --dangerously-skip-permissions" {
		t.Fatalf("switched = %d %+v", code, switched)
	}
	// Rename alone still works and keeps the launch settings.
	code, renamed := update(custom.ID, `{"name":"codexy2"}`)
	if code != http.StatusOK || renamed.Name != "codexy2" || renamed.Agent != "claude" {
		t.Fatalf("renamed = %d %+v", code, renamed)
	}

	for _, body := range []string{
		`{"name":"bad1","command":"claude\nrm -rf ~"}`,
		`{"name":"bad2","command":"claude\u001b[2J"}`,
	} {
		if code, _ := create(body); code != http.StatusBadRequest {
			t.Fatalf("create %s = %d, want 400", body, code)
		}
	}
	if _, err := os.Stat(filepath.Join(s.workspaceDir(sess), "bad1")); !os.IsNotExist(err) {
		t.Fatalf("rejected project left a directory: %v", err)
	}
	if code, _ := update(plain.ID, `{}`); code != http.StatusBadRequest {
		t.Fatalf("empty patch = %d, want 400", code)
	}
}
