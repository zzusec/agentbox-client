// abox-sync keeps a local project root mapped to one agentbox workspace.
package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"agentbox/internal/syncclient"
)

// projectSetting overrides the workspace defaults for one project. The Mac
// client writes these keyed by project ID, which survives a rename.
type projectSetting struct {
	LocalDir      string `json:"local_dir,omitempty"`
	InitialPolicy string `json:"initial_policy,omitempty"`
}

type config struct {
	Server          string                    `json:"server"`
	Token           string                    `json:"token"`
	SessionID       string                    `json:"session_id"`
	LocalRoot       string                    `json:"local_root"`
	DeviceID        string                    `json:"device_id"`
	DeviceName      string                    `json:"device_name"`
	InitialPolicy   string                    `json:"initial_policy"`
	Projects        []string                  `json:"projects"`
	ProjectSettings map[string]projectSetting `json:"project_settings,omitempty"`
	IntervalSeconds int                       `json:"interval_seconds"`
	// AllowBulkDelete lets a merge pass apply deletions that would empty most
	// of one side. Leave it off: see syncclient.BulkDeleteError.
	AllowBulkDelete bool `json:"allow_bulk_delete,omitempty"`
}

func main() {
	log.SetFlags(log.LstdFlags)
	configPath := flag.String("config", defaultConfigPath(), "JSON configuration path")
	watch := flag.Bool("watch", false, "keep polling and syncing until interrupted")
	projectFlag := flag.String("project", "", "sync only this project name")
	initialPolicy := flag.String("initial-policy", "", "initial side when both copies exist: local or server")
	forcePolicy := flag.String("force-policy", "", "one pass that lets this side overwrite the other: local or server")
	dryRun := flag.Bool("dry-run", false, "print what a pass would do, without touching anything")
	events := flag.Bool("events", false, "write progress, transfer and status events as JSON lines on stdout")
	flag.Parse()

	// A forced policy is a deliberate, destructive one-shot. Refuse to combine
	// it with -watch, which would re-overwrite on every tick.
	if *forcePolicy != "" && *watch {
		fatal(errors.New("-force-policy is a one-shot; it cannot be combined with -watch"))
	}
	if *dryRun && *watch {
		fatal(errors.New("-dry-run is a one-shot; it cannot be combined with -watch"))
	}

	cfg, err := loadConfig(*configPath)
	if err != nil {
		fatal(err)
	}
	if cfg.Token == "" {
		cfg.Token = os.Getenv("AGENTBOX_TOKEN")
	}
	if *projectFlag != "" {
		cfg.Projects = []string{*projectFlag}
	}
	if *initialPolicy != "" {
		cfg.InitialPolicy = *initialPolicy
	}
	if *forcePolicy != "" && *forcePolicy != "local" && *forcePolicy != "server" {
		fatal(errors.New("force-policy must be local or server"))
	}
	if cfg.DeviceID == "" {
		cfg.DeviceID, err = randomID()
		if err != nil {
			fatal(err)
		}
	}
	if cfg.DeviceName == "" {
		cfg.DeviceName, _ = os.Hostname()
	}
	if cfg.IntervalSeconds <= 0 {
		cfg.IntervalSeconds = 5
	}
	if err := cfg.validate(); err != nil {
		fatal(err)
	}
	if err := saveConfig(*configPath, cfg); err != nil {
		fatal(err)
	}

	client, err := syncclient.NewClient(cfg.Server, cfg.Token)
	if err != nil {
		fatal(err)
	}
	engine := &syncclient.Engine{
		Client:          client,
		DeviceID:        cfg.DeviceID,
		DeviceName:      cfg.DeviceName,
		AllowBulkDelete: cfg.AllowBulkDelete,
	}
	report := newReporter(*events)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if !*watch {
		if err := syncOnce(ctx, client, engine, report, cfg, *forcePolicy, *dryRun); err != nil {
			fatal(err)
		}
		return
	}
	ticker := time.NewTicker(time.Duration(cfg.IntervalSeconds) * time.Second)
	defer ticker.Stop()
	for {
		if err := syncOnce(ctx, client, engine, report, cfg, "", false); err != nil {
			log.Print(err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func syncOnce(
	ctx context.Context,
	client *syncclient.Client,
	engine *syncclient.Engine,
	report *reporter,
	cfg config,
	forcePolicy string,
	dryRun bool,
) error {
	projects, err := client.Projects(ctx, cfg.SessionID)
	if err != nil {
		return err
	}
	selected := map[string]bool{}
	if len(cfg.Projects) == 0 {
		for _, project := range projects {
			selected[project.Name] = true
		}
	} else {
		for _, name := range cfg.Projects {
			selected[name] = true
		}
	}
	var firstErr error
	for _, project := range projects {
		if !selected[project.Name] {
			continue
		}
		target := syncclient.ProjectTarget{
			Project:       project,
			LocalDir:      projectLocalDir(cfg, project),
			StateRoot:     cfg.LocalRoot,
			InitialPolicy: projectInitialPolicy(cfg, project),
			ForcePolicy:   forcePolicy,
			DryRun:        dryRun,
		}
		engine.OnProgress = report.progress
		engine.OnTransfer = report.transfer
		result, err := engine.SyncProject(ctx, target)
		engine.OnProgress, engine.OnTransfer = nil, nil
		if !dryRun {
			report.status(project, result, err)
		}
		if err != nil {
			var conflicts *syncclient.ConflictError
			if errors.As(err, &conflicts) {
				log.Printf("%s: %s", project.Name, strings.Join(conflicts.Paths, ", "))
				continue
			}
			// Keep going: one paused project (a guarded mass deletion, a
			// tampered download) must not stop every other project syncing.
			log.Printf("%s: %v", project.Name, err)
			if firstErr == nil {
				firstErr = fmt.Errorf("%s: %w", project.Name, err)
			}
			continue
		}
		if dryRun {
			if len(result.Planned) == 0 && len(result.Conflicts) == 0 {
				log.Printf("%s: in sync, nothing to do", project.Name)
			}
			for _, line := range result.Planned {
				log.Printf("%s: %s", project.Name, line)
			}
		} else if result.Actions != 0 {
			log.Printf("%s: 同步完成，应用了 %d 个变更，用时 %s", project.Name, result.Actions,
				result.Duration.Round(time.Millisecond))
			if result.TrashDir != "" {
				log.Printf("%s: %d 个本地文件已移入回收站 %s", project.Name, result.DeletedLocal, result.TrashDir)
			}
		} else if forcePolicy != "" {
			// A one-shot "sync now" always owes the user a verdict; the
			// watcher stays quiet on idle passes so the log is not a wall.
			log.Printf("%s: 已是最新，无需同步", project.Name)
		}
	}
	return firstErr
}

// projectLocalDir resolves where a project syncs to. Without an override the
// classic layout applies: the project name as a directory under local_root.
func projectLocalDir(cfg config, project syncclient.Project) string {
	if setting, ok := cfg.ProjectSettings[project.ID]; ok && setting.LocalDir != "" {
		return expandPath(setting.LocalDir)
	}
	return filepath.Join(cfg.LocalRoot, project.Name)
}

func projectInitialPolicy(cfg config, project syncclient.Project) string {
	if setting, ok := cfg.ProjectSettings[project.ID]; ok && setting.InitialPolicy != "" {
		return setting.InitialPolicy
	}
	return cfg.InitialPolicy
}

func (c config) validate() error {
	switch {
	case c.Server == "":
		return errors.New("server is required")
	case c.Token == "":
		return errors.New("token is required")
	case c.SessionID == "":
		return errors.New("session_id is required")
	case c.LocalRoot == "":
		return errors.New("local_root is required")
	case c.InitialPolicy != "" && c.InitialPolicy != "local" && c.InitialPolicy != "server":
		return errors.New("initial_policy must be local or server")
	}
	info, err := os.Stat(expandPath(c.LocalRoot))
	if err != nil || !info.IsDir() {
		return fmt.Errorf("local_root is not a directory: %s", c.LocalRoot)
	}
	for id, setting := range c.ProjectSettings {
		if setting.InitialPolicy != "" && setting.InitialPolicy != "local" && setting.InitialPolicy != "server" {
			return fmt.Errorf("project %s: initial_policy must be local or server", id)
		}
		if setting.LocalDir == "" {
			continue
		}
		if err := syncclient.CheckProjectDir(expandPath(setting.LocalDir), c.LocalRoot); err != nil {
			return fmt.Errorf("project %s: %w", id, err)
		}
	}
	return nil
}

func loadConfig(path string) (config, error) {
	raw, err := os.ReadFile(expandPath(path))
	if err != nil {
		return config{}, err
	}
	var cfg config
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return config{}, err
	}
	cfg.Server = strings.TrimRight(strings.TrimSpace(cfg.Server), "/")
	cfg.LocalRoot = expandPath(cfg.LocalRoot)
	return cfg, nil
}

func saveConfig(path string, cfg config) error {
	path = expandPath(path)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(raw, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func defaultConfigPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return "abox-sync.json"
	}
	return filepath.Join(home, ".agentbox-sync.json")
}

func expandPath(value string) string {
	if value == "~" || strings.HasPrefix(value, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, strings.TrimPrefix(value, "~/"))
		}
	}
	return value
}

func randomID() (string, error) {
	raw := make([]byte, 18)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(raw), nil
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "abox-sync:", err)
	os.Exit(1)
}
