package syncclient

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

type Engine struct {
	Client     *Client
	DeviceID   string
	DeviceName string

	// lastRemote caches each project's last synced (filtered) remote
	// manifest, keyed by project ID. Together with the server's
	// If-Revision support it turns idle poll cycles into tiny 204 probes.
	mu         sync.Mutex
	lastRemote map[string]Manifest
}

func (e *Engine) cachedRemote(projectID string) Manifest {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.lastRemote[projectID]
}

func (e *Engine) rememberRemote(projectID string, manifest Manifest) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.lastRemote == nil {
		e.lastRemote = map[string]Manifest{}
	}
	e.lastRemote[projectID] = manifest
}

type SyncResult struct {
	Project   string
	Actions   int
	Conflicts []string
}

type InitialConflictError struct {
	Project     string
	LocalCount  int
	RemoteCount int
}

func (e *InitialConflictError) Error() string {
	return fmt.Sprintf("项目 %s 没有同步基线：本地 %d 项，服务器 %d 项；请先指定 initial_policy",
		e.Project, e.LocalCount, e.RemoteCount)
}

type ConflictError struct {
	Project string
	Paths   []string
}

func (e *ConflictError) Error() string {
	return fmt.Sprintf("项目 %s 有 %d 个冲突，已暂停同步：%s",
		e.Project, len(e.Paths), strings.Join(e.Paths, ", "))
}

func (e *Engine) SyncProject(
	ctx context.Context,
	project Project,
	localRoot string,
	initialPolicy string,
) (SyncResult, error) {
	if e.Client == nil {
		return SyncResult{}, errors.New("sync client is nil")
	}
	if e.DeviceID == "" {
		return SyncResult{}, errors.New("device_id is required")
	}
	localProject := filepath.Join(localRoot, project.Name)
	if err := ensureSafeProjectPath(localRoot, localProject); err != nil {
		return SyncResult{}, err
	}
	base, hasBase, err := loadBase(localRoot, project.ID, localProject)
	if err != nil {
		return SyncResult{}, err
	}

	lastRemote := e.cachedRemote(project.ID)
	ifRevision := lastRemote.ServerRevision
	if ifRevision == "" && hasBase {
		ifRevision = base.ServerRevision
	}
	remote, notModified, err := e.Client.Manifest(ctx, project.ID, ifRevision)
	if err != nil {
		return SyncResult{}, err
	}
	if notModified {
		remote = lastRemote
		if remote.Revision == "" {
			remote = base
		}
	} else {
		rawRevision := remote.Revision
		remote, err = FilterManifest(remote, localProject)
		if err != nil {
			return SyncResult{}, err
		}
		remote.ServerRevision = rawRevision
	}
	local, err := localManifest(localProject)
	if err != nil {
		return SyncResult{}, err
	}

	var plan Plan
	if !hasBase {
		plan, err = bootstrapPlan(project.Name, initialPolicy, local, remote)
	} else {
		plan = BuildPlan(Entries(base), Entries(local), Entries(remote))
	}
	if err != nil {
		return SyncResult{}, err
	}
	if len(plan.Conflicts) != 0 {
		return SyncResult{Project: project.Name, Conflicts: plan.Conflicts},
			&ConflictError{Project: project.Name, Paths: plan.Conflicts}
	}
	if len(plan.Actions) == 0 {
		if err := saveBase(localRoot, project.ID, remote); err != nil {
			return SyncResult{}, err
		}
		e.rememberRemote(project.ID, remote)
		return SyncResult{Project: project.Name}, nil
	}

	lease, err := e.Client.AcquireLease(ctx, project.ID, e.DeviceID, e.DeviceName, 5*time.Minute)
	if err != nil {
		return SyncResult{}, err
	}
	defer func() {
		_ = e.Client.ReleaseLease(context.Background(), project.ID, lease.LeaseID)
	}()

	// Re-read under the lease. Server-side Claude can still write during the
	// transfer, but this closes the gap between the first manifest and lock.
	remote, notModified, err = e.Client.Manifest(ctx, project.ID, "")
	if err != nil {
		return SyncResult{}, err
	}
	if notModified {
		return SyncResult{}, errors.New("租约下的清单意外返回无变化")
	}
	leaseRawRevision := remote.Revision
	remote, err = FilterManifest(remote, localProject)
	if err != nil {
		return SyncResult{}, err
	}
	remote.ServerRevision = leaseRawRevision
	if !hasBase {
		plan, err = bootstrapPlan(project.Name, initialPolicy, local, remote)
	} else {
		plan = BuildPlan(Entries(base), Entries(local), Entries(remote))
	}
	if err != nil {
		return SyncResult{}, err
	}
	if len(plan.Conflicts) != 0 {
		return SyncResult{Project: project.Name, Conflicts: plan.Conflicts},
			&ConflictError{Project: project.Name, Paths: plan.Conflicts}
	}
	if len(plan.Actions) == 0 {
		if err := saveBase(localRoot, project.ID, remote); err != nil {
			return SyncResult{}, err
		}
		e.rememberRemote(project.ID, remote)
		return SyncResult{Project: project.Name}, nil
	}
	if err := e.applyPlan(ctx, project.ID, lease, localProject, plan); err != nil {
		return SyncResult{}, err
	}

	finalLocal, err := localManifest(localProject)
	if err != nil {
		return SyncResult{}, err
	}
	finalRemote, notModified, err := e.Client.Manifest(ctx, project.ID, "")
	if err != nil {
		return SyncResult{}, err
	}
	if notModified {
		return SyncResult{}, errors.New("同步完成后服务器清单意外返回无变化")
	}
	finalRawRevision := finalRemote.Revision
	finalRemote, err = FilterManifest(finalRemote, localProject)
	if err != nil {
		return SyncResult{}, err
	}
	finalRemote.ServerRevision = finalRawRevision
	verify := BuildPlan(Entries(finalLocal), Entries(finalLocal), Entries(finalRemote))
	if len(verify.Conflicts) != 0 || len(verify.Actions) != 0 {
		return SyncResult{}, errors.New("同步完成后本地和服务器仍不一致")
	}
	if err := saveBase(localRoot, project.ID, finalRemote); err != nil {
		return SyncResult{}, err
	}
	e.rememberRemote(project.ID, finalRemote)
	return SyncResult{Project: project.Name, Actions: len(plan.Actions)}, nil
}

func bootstrapPlan(name, policy string, local, remote Manifest) (Plan, error) {
	localEntries, remoteEntries := Entries(local), Entries(remote)
	if manifestsEqual(localEntries, remoteEntries) {
		return Plan{}, nil
	}
	if len(localEntries) == 0 {
		policy = "server"
	} else if len(remoteEntries) == 0 {
		policy = "local"
	}
	if policy != "local" && policy != "server" {
		return Plan{}, &InitialConflictError{
			Project: name, LocalCount: len(localEntries), RemoteCount: len(remoteEntries),
		}
	}
	all := map[string]bool{}
	for name := range localEntries {
		all[name] = true
	}
	for name := range remoteEntries {
		all[name] = true
	}
	paths := make([]string, 0, len(all))
	for name := range all {
		paths = append(paths, name)
	}
	sort.Strings(paths)
	plan := Plan{}
	for _, name := range paths {
		localEntry, inLocal := localEntries[name]
		remoteEntry, inRemote := remoteEntries[name]
		if policy == "local" {
			switch {
			case !inLocal:
				plan.Actions = append(plan.Actions, Action{Type: ActionDeleteRemote, Entry: remoteEntry})
			case !inRemote || !equalEntry(localEntry, true, remoteEntry, true):
				plan.Actions = append(plan.Actions, Action{Type: ActionUpload, Entry: localEntry})
			}
		} else {
			switch {
			case !inRemote:
				plan.Actions = append(plan.Actions, Action{Type: ActionDeleteLocal, Entry: localEntry})
			case !inLocal || !equalEntry(localEntry, true, remoteEntry, true):
				plan.Actions = append(plan.Actions, Action{Type: ActionDownload, Entry: remoteEntry})
			}
		}
	}
	plan.Actions = orderedActions(plan.Actions)
	return plan, nil
}

func manifestsEqual(left, right map[string]Entry) bool {
	if len(left) != len(right) {
		return false
	}
	for name, entry := range left {
		if !equalEntry(entry, true, right[name], right[name].Path != "") {
			return false
		}
	}
	return true
}

func (e *Engine) applyPlan(
	ctx context.Context,
	projectID string,
	lease Lease,
	localProject string,
	plan Plan,
) error {
	for _, action := range plan.Actions {
		target, err := safeProjectPath(localProject, action.Entry.Path)
		if err != nil {
			return err
		}
		switch action.Type {
		case ActionUpload:
			switch action.Entry.Kind {
			case "dir":
				if err := e.Client.PutFile(
					ctx, projectID, lease.LeaseID, lease.DeviceID, action.Entry, nil,
				); err != nil {
					return err
				}
			case "file":
				file, err := os.Open(target)
				if err != nil {
					return err
				}
				err = e.Client.PutFile(
					ctx, projectID, lease.LeaseID, lease.DeviceID, action.Entry, file,
				)
				closeErr := file.Close()
				if err != nil {
					return err
				}
				if closeErr != nil {
					return closeErr
				}
			default:
				return fmt.Errorf("live sync does not support %s: %s", action.Entry.Kind, action.Entry.Path)
			}
		case ActionDeleteRemote:
			if err := e.Client.DeleteFile(
				ctx, projectID, lease.LeaseID, lease.DeviceID, action.Entry.Path,
			); err != nil {
				return err
			}
		case ActionDownload:
			switch action.Entry.Kind {
			case "dir":
				if err := os.MkdirAll(target, os.FileMode(action.Entry.Mode)); err != nil {
					return err
				}
			case "file":
				body, err := e.Client.OpenFile(ctx, projectID, action.Entry.Path)
				if err != nil {
					return err
				}
				err = writeLocalFile(target, body, os.FileMode(action.Entry.Mode), action.Entry.MTime)
				closeErr := body.Close()
				if err != nil {
					return err
				}
				if closeErr != nil {
					return closeErr
				}
			default:
				return fmt.Errorf("live sync does not support %s: %s", action.Entry.Kind, action.Entry.Path)
			}
		case ActionDeleteLocal:
			if err := os.RemoveAll(target); err != nil {
				return err
			}
		default:
			return fmt.Errorf("unknown sync action %q", action.Type)
		}
	}
	return nil
}

func localManifest(root string) (Manifest, error) {
	info, err := os.Stat(root)
	if os.IsNotExist(err) {
		return Manifest{Revision: Revision(nil)}, nil
	}
	if err != nil {
		return Manifest{}, err
	}
	if !info.IsDir() {
		return Manifest{}, fmt.Errorf("%s is not a directory", root)
	}
	return BuildLocalManifest(root)
}

func ensureSafeProjectPath(root, target string) error {
	rel, err := filepath.Rel(root, target)
	if err != nil || !filepath.IsLocal(rel) {
		return fmt.Errorf("invalid project path")
	}
	return nil
}

func safeProjectPath(root, rel string) (string, error) {
	rel = filepath.Clean(filepath.FromSlash(rel))
	if rel == "." || !filepath.IsLocal(rel) {
		return "", fmt.Errorf("invalid sync path %q", rel)
	}
	target := filepath.Join(root, rel)
	if err := ensureSafeProjectPath(root, target); err != nil {
		return "", err
	}
	return target, nil
}

func writeLocalFile(target string, body io.Reader, mode os.FileMode, modified string) error {
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(target), ".agentbox-download-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := io.Copy(tmp, body); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(mode.Perm()); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpName, target); err != nil {
		return err
	}
	if modified != "" {
		if when, err := time.Parse(time.RFC3339Nano, modified); err == nil {
			_ = os.Chtimes(target, when, when)
		}
	}
	return nil
}

func stateDir(localRoot string) string {
	return filepath.Join(localRoot, ".agentbox-sync")
}

func basePath(localRoot, projectID string) string {
	return filepath.Join(stateDir(localRoot), projectID+".json")
}

func loadBase(localRoot, projectID, localProject string) (Manifest, bool, error) {
	raw, err := os.ReadFile(basePath(localRoot, projectID))
	if os.IsNotExist(err) {
		return Manifest{}, false, nil
	}
	if err != nil {
		return Manifest{}, false, err
	}
	var manifest Manifest
	if err := json.Unmarshal(raw, &manifest); err != nil {
		return Manifest{}, false, fmt.Errorf("parse sync base: %w", err)
	}
	filtered, err := FilterManifest(manifest, localProject)
	if err != nil {
		return Manifest{}, false, err
	}
	return filtered, true, nil
}

func saveBase(localRoot, projectID string, manifest Manifest) error {
	dir := stateDir(localRoot)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	target := basePath(localRoot, projectID)
	raw, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".base-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if _, err := tmp.Write(append(raw, '\n')); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(name, target)
}
