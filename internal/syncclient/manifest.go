// Package syncclient implements the local side of agentbox project sync.
package syncclient

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

type Entry struct {
	Path       string `json:"path"`
	Kind       string `json:"kind"`
	Size       int64  `json:"size,omitempty"`
	Mode       uint32 `json:"mode,omitempty"`
	MTime      string `json:"mtime,omitempty"`
	SHA256     string `json:"sha256,omitempty"`
	LinkTarget string `json:"link_target,omitempty"`
}

type Manifest struct {
	ProjectID string  `json:"project_id"`
	Revision  string  `json:"revision"`
	Entries   []Entry `json:"entries"`
}

type ActionType string

const (
	ActionUpload       ActionType = "upload"
	ActionDeleteRemote ActionType = "delete_remote"
	ActionDownload     ActionType = "download"
	ActionDeleteLocal  ActionType = "delete_local"
)

type Action struct {
	Type  ActionType
	Entry Entry
}

type Plan struct {
	Actions   []Action
	Conflicts []string
}

var defaultExcludes = []string{
	".DS_Store",
	".git",
	".agentbox-sync",
	"node_modules",
	"__pycache__",
	".venv",
	"venv",
	"dist",
	"build",
	"target",
	"DerivedData",
	".next",
	".cache",
}

// BuildLocalManifest hashes a project without following symlinks. Git metadata
// and generated dependency directories stay out of the live sync set.
func BuildLocalManifest(root string) (Manifest, error) {
	excludes, err := loadExcludes(root)
	if err != nil {
		return Manifest{}, err
	}
	entries := []Entry{}
	err = filepath.WalkDir(root, func(name string, item fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if name == root {
			return nil
		}
		rel, err := filepath.Rel(root, name)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		if excluded(rel, item.IsDir(), excludes) {
			if item.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		info, err := item.Info()
		if err != nil {
			return err
		}
		entry := Entry{
			Path:  rel,
			Mode:  uint32(info.Mode().Perm()),
			MTime: info.ModTime().UTC().Format(time.RFC3339Nano),
		}
		switch {
		case info.Mode()&os.ModeSymlink != 0:
			target, err := os.Readlink(name)
			if err != nil {
				return err
			}
			entry.Kind = "symlink"
			entry.LinkTarget = target
		case info.IsDir():
			entry.Kind = "dir"
		case info.Mode().IsRegular():
			entry.Kind = "file"
			entry.Size = info.Size()
			file, err := os.Open(name)
			if err != nil {
				return err
			}
			hash := sha256.New()
			_, copyErr := io.Copy(hash, file)
			closeErr := file.Close()
			if copyErr != nil {
				return copyErr
			}
			if closeErr != nil {
				return closeErr
			}
			entry.SHA256 = hex.EncodeToString(hash.Sum(nil))
		default:
			return nil
		}
		entries = append(entries, entry)
		return nil
	})
	if err != nil {
		return Manifest{}, err
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Path < entries[j].Path })
	return Manifest{Revision: Revision(entries), Entries: entries}, nil
}

func FilterManifest(manifest Manifest, root string) (Manifest, error) {
	excludes, err := loadExcludes(root)
	if err != nil {
		return Manifest{}, err
	}
	entries := make([]Entry, 0, len(manifest.Entries))
	for _, entry := range manifest.Entries {
		if excluded(entry.Path, entry.Kind == "dir", excludes) {
			continue
		}
		entries = append(entries, entry)
	}
	manifest.Entries = entries
	manifest.Revision = Revision(entries)
	return manifest, nil
}

func Entries(manifest Manifest) map[string]Entry {
	out := make(map[string]Entry, len(manifest.Entries))
	for _, entry := range manifest.Entries {
		out[entry.Path] = entry
	}
	return out
}

func Revision(entries []Entry) string {
	hash := sha256.New()
	sorted := append([]Entry(nil), entries...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].Path < sorted[j].Path })
	for _, entry := range sorted {
		fmt.Fprintf(hash, "%s\x00%s\x00%d\x00%d\x00%s\x00%s\n",
			entry.Path, entry.Kind, entry.Size, entry.Mode, entry.SHA256, entry.LinkTarget)
	}
	return hex.EncodeToString(hash.Sum(nil))
}

// BuildPlan compares local and remote manifests against the last common base.
// It never resolves a file changed on both sides; conflicts pause the project.
func BuildPlan(base, local, remote map[string]Entry) Plan {
	paths := map[string]bool{}
	for name := range base {
		paths[name] = true
	}
	for name := range local {
		paths[name] = true
	}
	for name := range remote {
		paths[name] = true
	}
	ordered := make([]string, 0, len(paths))
	for name := range paths {
		ordered = append(ordered, name)
	}
	sort.Strings(ordered)

	plan := Plan{}
	for _, name := range ordered {
		baseEntry, inBase := base[name]
		localEntry, inLocal := local[name]
		remoteEntry, inRemote := remote[name]
		localChanged := entryChanged(localEntry, inLocal, baseEntry, inBase)
		remoteChanged := entryChanged(remoteEntry, inRemote, baseEntry, inBase)
		switch {
		case localChanged && remoteChanged:
			if equalEntry(localEntry, inLocal, remoteEntry, inRemote) {
				continue
			}
			plan.Conflicts = append(plan.Conflicts, name)
		case localChanged:
			if !inLocal {
				plan.Actions = append(plan.Actions, Action{Type: ActionDeleteRemote, Entry: baseEntry})
			} else {
				plan.Actions = append(plan.Actions, Action{Type: ActionUpload, Entry: localEntry})
			}
		case remoteChanged:
			if !inRemote {
				plan.Actions = append(plan.Actions, Action{Type: ActionDeleteLocal, Entry: baseEntry})
			} else {
				plan.Actions = append(plan.Actions, Action{Type: ActionDownload, Entry: remoteEntry})
			}
		}
	}
	plan.Actions = orderedActions(plan.Actions)
	return plan
}

func orderedActions(actions []Action) []Action {
	sort.SliceStable(actions, func(i, j int) bool {
		left, right := actions[i], actions[j]
		if left.Type != right.Type {
			return actionOrder(left.Type) < actionOrder(right.Type)
		}
		leftDepth := strings.Count(left.Entry.Path, "/")
		rightDepth := strings.Count(right.Entry.Path, "/")
		if left.Type == ActionDeleteRemote || left.Type == ActionDeleteLocal {
			return leftDepth > rightDepth
		}
		if (left.Entry.Kind == "dir") != (right.Entry.Kind == "dir") {
			return left.Entry.Kind == "dir"
		}
		return left.Entry.Path < right.Entry.Path
	})
	return actions
}

func actionOrder(kind ActionType) int {
	switch kind {
	case ActionDeleteRemote:
		return 0
	case ActionDeleteLocal:
		return 1
	case ActionUpload:
		return 2
	case ActionDownload:
		return 3
	default:
		return 4
	}
}

func entryChanged(entry Entry, present bool, base Entry, inBase bool) bool {
	return !equalEntry(entry, present, base, inBase)
}

func equalEntry(left Entry, leftOK bool, right Entry, rightOK bool) bool {
	if leftOK != rightOK {
		return false
	}
	if !leftOK {
		return true
	}
	return left.Kind == right.Kind &&
		left.Size == right.Size &&
		left.Mode == right.Mode &&
		left.SHA256 == right.SHA256 &&
		left.LinkTarget == right.LinkTarget
}

func loadExcludes(root string) ([]string, error) {
	out := append([]string(nil), defaultExcludes...)
	raw, err := os.ReadFile(filepath.Join(root, ".agentboxignore"))
	if err != nil {
		if os.IsNotExist(err) {
			return out, nil
		}
		return nil, err
	}
	for _, line := range strings.Split(string(raw), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		out = append(out, strings.TrimPrefix(filepath.ToSlash(line), "/"))
	}
	return out, nil
}

func excluded(rel string, isDir bool, patterns []string) bool {
	rel = strings.TrimPrefix(path.Clean(filepath.ToSlash(rel)), "./")
	parts := strings.Split(rel, "/")
	for _, pattern := range patterns {
		pattern = strings.TrimPrefix(path.Clean(pattern), "./")
		if pattern == "" || pattern == "." {
			continue
		}
		if matched, _ := path.Match(pattern, rel); matched {
			return true
		}
		for _, part := range parts {
			if matched, _ := path.Match(pattern, part); matched {
				return true
			}
		}
		if strings.HasSuffix(pattern, "/") &&
			strings.HasPrefix(rel, strings.TrimSuffix(pattern, "/")+"/") {
			return true
		}
	}
	return false
}
