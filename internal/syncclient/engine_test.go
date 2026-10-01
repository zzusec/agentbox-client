package syncclient

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestCheckProjectDir(t *testing.T) {
	root := t.TempDir()
	stateRoot := filepath.Join(root, "agentbox")

	cases := []struct {
		name    string
		dir     string
		wantErr bool
	}{
		{"classic project under the sync root", filepath.Join(stateRoot, "demo"), false},
		{"unrelated absolute directory", filepath.Join(root, "elsewhere", "demo"), false},
		{"empty", "", true},
		{"relative", "demo", true},
		{"filesystem root", string(filepath.Separator), true},
		{"ancestor of the sync root", root, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := CheckProjectDir(tc.dir, stateRoot)
			if tc.wantErr && err == nil {
				t.Fatalf("CheckProjectDir(%q) = nil, want an error", tc.dir)
			}
			if !tc.wantErr && err != nil {
				t.Fatalf("CheckProjectDir(%q) = %v, want nil", tc.dir, err)
			}
		})
	}
}

func TestSaveBaseRecordsTheDirectoryItDescribes(t *testing.T) {
	stateRoot := t.TempDir()
	project := Project{ID: "p1", Name: "demo"}
	dir := classicProjectDir(stateRoot, project)
	manifest := Manifest{Revision: "rev-1", Entries: []Entry{{Path: "a.txt", Kind: "file"}}}

	if err := saveBase(stateRoot, project.ID, dir, manifest); err != nil {
		t.Fatalf("saveBase: %v", err)
	}
	raw, err := os.ReadFile(basePath(stateRoot, project.ID))
	if err != nil {
		t.Fatalf("read base: %v", err)
	}
	var probe map[string]json.RawMessage
	if err := json.Unmarshal(raw, &probe); err != nil {
		t.Fatalf("base is not JSON: %v", err)
	}
	if _, ok := probe["local_dir"]; !ok {
		t.Fatalf("base record must carry local_dir, got %s", raw)
	}
	if _, ok := probe["manifest"]; !ok {
		t.Fatalf("base record must wrap the manifest, got %s", raw)
	}
}

func TestLoadBaseDropsTheBaselineWhenTheProjectMoves(t *testing.T) {
	stateRoot := t.TempDir()
	project := Project{ID: "p1", Name: "demo"}
	classic := classicProjectDir(stateRoot, project)
	moved := filepath.Join(t.TempDir(), "demo")
	manifest := Manifest{Revision: "rev-1", Entries: []Entry{{Path: "a.txt", Kind: "file"}}}

	if err := saveBase(stateRoot, project.ID, classic, manifest); err != nil {
		t.Fatalf("saveBase: %v", err)
	}

	// Still at the recorded directory: the baseline applies.
	if _, ok, err := loadBase(stateRoot, project.ID, classic, classic); err != nil || !ok {
		t.Fatalf("loadBase at the recorded directory = ok %v, err %v; want a baseline", ok, err)
	}
	// Moved: the baseline lists files under the old path, so reusing it would
	// read as "everything was deleted locally" and wipe the server copy.
	if _, ok, err := loadBase(stateRoot, project.ID, moved, classic); err != nil || ok {
		t.Fatalf("loadBase after a move = ok %v, err %v; want no baseline", ok, err)
	}
}

func TestLoadBaseTrustsLegacyFilesOnlyAtTheClassicPath(t *testing.T) {
	stateRoot := t.TempDir()
	project := Project{ID: "p1", Name: "demo"}
	classic := classicProjectDir(stateRoot, project)
	moved := filepath.Join(t.TempDir(), "demo")

	// The format written before per-project directories existed: a bare
	// Manifest with no recorded directory.
	raw, err := json.Marshal(Manifest{
		Revision: "rev-1",
		Entries:  []Entry{{Path: "a.txt", Kind: "file"}},
	})
	if err != nil {
		t.Fatalf("marshal legacy base: %v", err)
	}
	if err := os.MkdirAll(stateDir(stateRoot), 0o700); err != nil {
		t.Fatalf("mkdir state dir: %v", err)
	}
	if err := os.WriteFile(basePath(stateRoot, project.ID), raw, 0o600); err != nil {
		t.Fatalf("write legacy base: %v", err)
	}

	if _, ok, err := loadBase(stateRoot, project.ID, classic, classic); err != nil || !ok {
		t.Fatalf("legacy base at the classic path = ok %v, err %v; want a baseline", ok, err)
	}
	if _, ok, err := loadBase(stateRoot, project.ID, moved, classic); err != nil || ok {
		t.Fatalf("legacy base after a move = ok %v, err %v; want no baseline", ok, err)
	}
}

func TestLoadBaseIgnoresAMissingFile(t *testing.T) {
	stateRoot := t.TempDir()
	project := Project{ID: "p1", Name: "demo"}
	classic := classicProjectDir(stateRoot, project)
	if _, ok, err := loadBase(stateRoot, project.ID, classic, classic); err != nil || ok {
		t.Fatalf("loadBase with no file = ok %v, err %v; want no baseline", ok, err)
	}
}
