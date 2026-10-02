package syncclient

import (
	"os"
	"path/filepath"
	"testing"
)

func TestBuildPlanSeparatesUploadDownloadAndConflict(t *testing.T) {
	base := map[string]Entry{
		"same.txt":  {Path: "same.txt", Kind: "file", Mode: 0o644, SHA256: "same"},
		"local.txt": {Path: "local.txt", Kind: "file", Mode: 0o644, SHA256: "old"},
		"remote.md": {Path: "remote.md", Kind: "file", Mode: 0o644, SHA256: "old"},
		"bad.txt":   {Path: "bad.txt", Kind: "file", Mode: 0o644, SHA256: "old"},
	}
	local := map[string]Entry{
		"same.txt":  base["same.txt"],
		"local.txt": {Path: "local.txt", Kind: "file", Mode: 0o644, SHA256: "local"},
		"remote.md": base["remote.md"],
		"bad.txt":   {Path: "bad.txt", Kind: "file", Mode: 0o644, SHA256: "local"},
	}
	remote := map[string]Entry{
		"same.txt":  base["same.txt"],
		"local.txt": base["local.txt"],
		"remote.md": {Path: "remote.md", Kind: "file", Mode: 0o644, SHA256: "remote"},
		"bad.txt":   {Path: "bad.txt", Kind: "file", Mode: 0o644, SHA256: "remote"},
	}
	plan := BuildPlan(base, local, remote)
	if len(plan.Conflicts) != 1 || plan.Conflicts[0] != "bad.txt" {
		t.Fatalf("conflicts = %v", plan.Conflicts)
	}
	var sawUpload, sawDownload bool
	for _, action := range plan.Actions {
		if action.Entry.Path == "local.txt" && action.Type == ActionUpload {
			sawUpload = true
		}
		if action.Entry.Path == "remote.md" && action.Type == ActionDownload {
			sawDownload = true
		}
	}
	if !sawUpload || !sawDownload {
		t.Fatalf("actions = %+v", plan.Actions)
	}
}

func TestBuildLocalManifestExcludesGitAndHashesFiles(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".git", "config"), []byte("ignored"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "hello.txt"), []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	manifest, err := BuildLocalManifest(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(manifest.Entries) != 1 || manifest.Entries[0].Path != "hello.txt" {
		t.Fatalf("entries = %+v", manifest.Entries)
	}
	if manifest.Entries[0].SHA256 != "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" {
		t.Fatalf("sha = %s", manifest.Entries[0].SHA256)
	}
}

// TestEqualEntryIgnoresDirectoryMode pins the comparison that made a project
// re-upload its whole directory tree on every pass: the server creates
// directories under a umask (the unit sets 0077), so a directory sent as 0755
// came back as 0700 and never matched. Nothing can be transferred to fix that,
// so the mode of a directory is not part of the comparison.
func TestEqualEntryIgnoresDirectoryMode(t *testing.T) {
	local := Entry{Path: "src", Kind: "dir", Mode: 0o755}
	remote := Entry{Path: "src", Kind: "dir", Mode: 0o700}
	if !equalEntry(local, true, remote, true) {
		t.Fatal("a directory whose mode the server changed must still count as equal")
	}
	// Files keep comparing by mode: that one does round-trip.
	localFile := Entry{Path: "run.sh", Kind: "file", Mode: 0o755, SHA256: "abc"}
	remoteFile := Entry{Path: "run.sh", Kind: "file", Mode: 0o644, SHA256: "abc"}
	if equalEntry(localFile, true, remoteFile, true) {
		t.Fatal("a file's mode must still be compared")
	}
	// And a directory that differs in kind is still a difference.
	if equalEntry(local, true, Entry{Path: "src", Kind: "file", Mode: 0o755}, true) {
		t.Fatal("kind must still be compared")
	}
}
