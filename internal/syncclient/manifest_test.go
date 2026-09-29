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
