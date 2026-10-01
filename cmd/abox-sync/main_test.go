package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"agentbox/internal/syncclient"
)

func testConfig(t *testing.T) config {
	t.Helper()
	root := t.TempDir()
	return config{
		Server:    "https://example.invalid",
		Token:     "token",
		SessionID: "session-1",
		LocalRoot: root,
	}
}

func TestProjectLocalDirFallsBackToTheClassicLayout(t *testing.T) {
	cfg := testConfig(t)
	project := syncclient.Project{ID: "p1", Name: "demo"}

	want := filepath.Join(cfg.LocalRoot, "demo")
	if got := projectLocalDir(cfg, project); got != want {
		t.Fatalf("projectLocalDir with no override = %q, want %q", got, want)
	}
}

func TestProjectLocalDirPrefersTheOverride(t *testing.T) {
	cfg := testConfig(t)
	project := syncclient.Project{ID: "p1", Name: "demo"}
	elsewhere := filepath.Join(t.TempDir(), "work", "demo")
	cfg.ProjectSettings = map[string]projectSetting{
		"p1": {LocalDir: elsewhere},
	}

	if got := projectLocalDir(cfg, project); got != elsewhere {
		t.Fatalf("projectLocalDir = %q, want %q", got, elsewhere)
	}
	// An override keyed by another project must not leak across.
	other := syncclient.Project{ID: "p2", Name: "other"}
	if got, want := projectLocalDir(cfg, other), filepath.Join(cfg.LocalRoot, "other"); got != want {
		t.Fatalf("projectLocalDir for an unconfigured project = %q, want %q", got, want)
	}
}

func TestProjectInitialPolicyFallsBackAndOverrides(t *testing.T) {
	cfg := testConfig(t)
	cfg.InitialPolicy = "server"
	project := syncclient.Project{ID: "p1", Name: "demo"}

	if got := projectInitialPolicy(cfg, project); got != "server" {
		t.Fatalf("projectInitialPolicy with no override = %q, want server", got)
	}
	cfg.ProjectSettings = map[string]projectSetting{"p1": {InitialPolicy: "local"}}
	if got := projectInitialPolicy(cfg, project); got != "local" {
		t.Fatalf("projectInitialPolicy = %q, want local", got)
	}
	// A setting that only carries a directory must not clear the default.
	cfg.ProjectSettings = map[string]projectSetting{"p1": {LocalDir: t.TempDir()}}
	if got := projectInitialPolicy(cfg, project); got != "server" {
		t.Fatalf("projectInitialPolicy with a directory-only setting = %q, want server", got)
	}
}

func TestValidateAcceptsAWellFormedOverride(t *testing.T) {
	cfg := testConfig(t)
	cfg.ProjectSettings = map[string]projectSetting{
		"p1": {LocalDir: filepath.Join(t.TempDir(), "demo"), InitialPolicy: "local"},
	}
	if err := cfg.validate(); err != nil {
		t.Fatalf("validate = %v, want nil", err)
	}
}

func TestValidateRejectsBadProjectSettings(t *testing.T) {
	cases := []struct {
		name    string
		setting projectSetting
		want    string
	}{
		{
			name:    "unknown policy",
			setting: projectSetting{InitialPolicy: "newest"},
			want:    "initial_policy must be local or server",
		},
		{
			name:    "relative directory",
			setting: projectSetting{LocalDir: "demo"},
			want:    "must be absolute",
		},
		{
			name:    "filesystem root",
			setting: projectSetting{LocalDir: string(filepath.Separator)},
			want:    "filesystem root",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg := testConfig(t)
			cfg.ProjectSettings = map[string]projectSetting{"p1": tc.setting}
			err := cfg.validate()
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("validate = %v, want an error containing %q", err, tc.want)
			}
		})
	}
}

func TestValidateRejectsAProjectThatContainsTheSyncRoot(t *testing.T) {
	cfg := testConfig(t)
	// local_root lives under the home-style parent we are about to sync, so
	// every other project would be uploaded into this one.
	parent := filepath.Dir(cfg.LocalRoot)
	cfg.ProjectSettings = map[string]projectSetting{"p1": {LocalDir: parent}}
	err := cfg.validate()
	if err == nil || !strings.Contains(err.Error(), "contains the sync root") {
		t.Fatalf("validate = %v, want an error about containing the sync root", err)
	}
}

func TestLoadConfigExpandsProjectSettingsOnUse(t *testing.T) {
	cfg := testConfig(t)
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skipf("no home directory: %v", err)
	}
	cfg.ProjectSettings = map[string]projectSetting{"p1": {LocalDir: "~/agentbox-demo"}}
	got := projectLocalDir(cfg, syncclient.Project{ID: "p1", Name: "demo"})
	if want := filepath.Join(home, "agentbox-demo"); got != want {
		t.Fatalf("projectLocalDir with a tilde = %q, want %q", got, want)
	}
}
