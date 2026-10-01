package syncclient

import (
	"encoding/json"
	"errors"
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

func manifestOf(entries ...Entry) Manifest {
	return Manifest{Revision: Revision(entries), Entries: entries}
}

func fileEntry(path, hash string) Entry {
	return Entry{Path: path, Kind: "file", Size: int64(len(hash)), Mode: 0o644, SHA256: hash}
}

// A forced policy has to behave exactly like a bootstrap: it ignores the
// baseline, so one side's whole tree overwrites the other's. That is what
// makes "sync now, server wins" delete local files the server does not have.
func TestResolvePlanForcePolicyOverwritesTheOtherSide(t *testing.T) {
	base := manifestOf(fileEntry("a.txt", "v1"))
	local := manifestOf(fileEntry("a.txt", "v2"), fileEntry("local-only.txt", "l"))
	remote := manifestOf(fileEntry("a.txt", "v3"), fileEntry("remote-only.txt", "r"))

	types := func(plan Plan) map[string]ActionType {
		out := map[string]ActionType{}
		for _, action := range plan.Actions {
			out[action.Entry.Path] = action.Type
		}
		return out
	}

	t.Run("server wins", func(t *testing.T) {
		plan, err := resolvePlan("demo", base, true, local, remote, "server", "")
		if err != nil {
			t.Fatalf("resolvePlan: %v", err)
		}
		if len(plan.Conflicts) != 0 {
			t.Fatalf("a forced policy must not stop at conflicts: %v", plan.Conflicts)
		}
		got := types(plan)
		want := map[string]ActionType{
			"a.txt":           ActionDownload,
			"remote-only.txt": ActionDownload,
			"local-only.txt":  ActionDeleteLocal,
		}
		for path, wantType := range want {
			if got[path] != wantType {
				t.Fatalf("server wins: %s = %q, want %q (all: %v)", path, got[path], wantType, got)
			}
		}
	})

	t.Run("local wins", func(t *testing.T) {
		plan, err := resolvePlan("demo", base, true, local, remote, "local", "")
		if err != nil {
			t.Fatalf("resolvePlan: %v", err)
		}
		if len(plan.Conflicts) != 0 {
			t.Fatalf("a forced policy must not stop at conflicts: %v", plan.Conflicts)
		}
		got := types(plan)
		want := map[string]ActionType{
			"a.txt":           ActionUpload,
			"local-only.txt":  ActionUpload,
			"remote-only.txt": ActionDeleteRemote,
		}
		for path, wantType := range want {
			if got[path] != wantType {
				t.Fatalf("local wins: %s = %q, want %q (all: %v)", path, got[path], wantType, got)
			}
		}
	})
}

// Without a forced policy the same inputs must still go through the three-way
// merge, which reports the double edit instead of picking a side.
func TestResolvePlanWithoutAForceStillMergesThreeWay(t *testing.T) {
	base := manifestOf(fileEntry("a.txt", "v1"))
	local := manifestOf(fileEntry("a.txt", "v2"), fileEntry("local-only.txt", "l"))
	remote := manifestOf(fileEntry("a.txt", "v3"), fileEntry("remote-only.txt", "r"))

	plan, err := resolvePlan("demo", base, true, local, remote, "", "")
	if err != nil {
		t.Fatalf("resolvePlan: %v", err)
	}
	if len(plan.Conflicts) != 1 || plan.Conflicts[0] != "a.txt" {
		t.Fatalf("conflicts = %v, want [a.txt]", plan.Conflicts)
	}
	for _, action := range plan.Actions {
		if action.Entry.Path == "a.txt" {
			t.Fatalf("a conflicting file must not be planned, got %v", action)
		}
	}
}

func TestResolvePlanBootstrapsWithTheInitialPolicy(t *testing.T) {
	local := manifestOf(fileEntry("local-only.txt", "l"))
	remote := manifestOf(fileEntry("remote-only.txt", "r"))

	plan, err := resolvePlan("demo", Manifest{}, false, local, remote, "", "server")
	if err != nil {
		t.Fatalf("resolvePlan: %v", err)
	}
	if len(plan.Conflicts) != 0 {
		t.Fatalf("conflicts = %v, want none", plan.Conflicts)
	}
	// A server bootstrap takes the server tree wholesale: remote files come
	// down, and anything that exists only locally goes away.
	got := map[string]ActionType{}
	for _, action := range plan.Actions {
		got[action.Entry.Path] = action.Type
	}
	if got["remote-only.txt"] != ActionDownload {
		t.Fatalf("remote-only.txt = %q, want download (all: %v)", got["remote-only.txt"], got)
	}
	if got["local-only.txt"] != ActionDeleteLocal {
		t.Fatalf("local-only.txt = %q, want delete_local (all: %v)", got["local-only.txt"], got)
	}
}

// An empty initial policy with no baseline cannot be resolved at all: the
// caller has to say which side wins before anything is touched.
func TestResolvePlanWithoutAPolicyAsksForOne(t *testing.T) {
	local := manifestOf(fileEntry("local-only.txt", "l"))
	remote := manifestOf(fileEntry("remote-only.txt", "r"))

	_, err := resolvePlan("demo", Manifest{}, false, local, remote, "", "")
	var conflict *InitialConflictError
	if !errors.As(err, &conflict) {
		t.Fatalf("resolvePlan = %v, want an InitialConflictError", err)
	}
}
