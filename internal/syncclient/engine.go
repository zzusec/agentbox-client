package syncclient

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
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

	// OnProgress ticks while a plan is applied, with a byte-weighted
	// percentage so one large file moves the bar smoothly instead of sitting
	// at 0% and jumping to 100%. OnTransfer fires once per finished item with
	// how long it took. Both are only called from inside SyncProject, on the
	// caller's goroutine, so the caller can rebind them per project.
	OnProgress func(Progress)
	OnTransfer func(Transfer)

	// AllowBulkDelete disables the guard that stops a merge pass from wiping
	// out most of one side. Off by default: the usual cause of a mass
	// deletion is an agent that ran `rm -rf`, not a user who meant it.
	AllowBulkDelete bool

	// lastRemote caches each project's last synced (filtered) remote
	// manifest, keyed by project ID. Together with the server's
	// If-Revision support it turns idle poll cycles into tiny 204 probes.
	mu         sync.Mutex
	lastRemote map[string]Manifest
	// localCache is the local mirror of the server's stat-signature cache:
	// hashing every local file once a second is the dominant cost of an idle
	// watcher on a big project.
	localCache map[string]localCacheEntry
}

// localCacheMaxAge forces a full re-hash now and then even when the stat
// signature is unchanged, so an edit that kept both size and mtime (some
// editors and `touch -r` do) still syncs within a minute.
const localCacheMaxAge = time.Minute

type localCacheEntry struct {
	signature string
	manifest  Manifest
	at        time.Time
}

// localManifest returns the project's local manifest, reusing the previous
// hash pass while the tree's stat signature is unchanged.
func (e *Engine) localManifest(dir string) (Manifest, error) {
	signature, err := QuickLocalRevision(dir)
	if err != nil {
		return Manifest{}, err
	}
	e.mu.Lock()
	cached, ok := e.localCache[dir]
	e.mu.Unlock()
	if ok && signature != "" && cached.signature == signature &&
		time.Since(cached.at) < localCacheMaxAge {
		return cached.manifest, nil
	}
	manifest, err := localManifest(dir)
	if err != nil {
		return Manifest{}, err
	}
	e.mu.Lock()
	if e.localCache == nil {
		e.localCache = map[string]localCacheEntry{}
	}
	e.localCache[dir] = localCacheEntry{signature: signature, manifest: manifest, at: time.Now()}
	e.mu.Unlock()
	return manifest, nil
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
	// Planned is the human-readable plan, filled in only for a dry run.
	Planned []string

	Uploaded      int
	Downloaded    int
	DeletedLocal  int
	DeletedRemote int
	Bytes         int64
	// InSync reports that the pass ended with both sides verified identical:
	// either nothing differed, or the post-transfer manifests matched.
	InSync bool
	// TrashDir is where this pass parked locally deleted files, if any.
	TrashDir string
	Duration time.Duration
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

// ProjectTarget is one project's resolved sync target: where its local
// directory lives and which side wins if it has to build a fresh baseline.
type ProjectTarget struct {
	Project Project
	// LocalDir is the absolute local directory mapped to this project.
	// Callers keeping the classic layout pass filepath.Join(localRoot, name).
	LocalDir string
	// StateRoot holds the .agentbox-sync baseline directory. It stays the
	// workspace local root no matter where the project itself lives, so
	// moving one project does not orphan every other project's baseline.
	StateRoot string
	// InitialPolicy decides which side wins when the project has no usable
	// baseline and both sides have content: "local" or "server". Empty means
	// "ask the caller" and surfaces as an InitialConflictError.
	InitialPolicy string
	// ForcePolicy, when set, reconciles the project as if it were bootstrapping
	// and lets that side overwrite the other. It is how an explicit "sync now,
	// server (or local) wins" is expressed: the baseline is ignored for this
	// pass and replaced by whatever the forced policy produces.
	ForcePolicy string
	// DryRun stops after planning. It reports what a pass would do without
	// taking a lease, touching a file or moving the baseline, which is the
	// only way to answer "why does this file keep coming back?" on a live
	// machine.
	DryRun bool
}

func (e *Engine) SyncProject(ctx context.Context, target ProjectTarget) (SyncResult, error) {
	started := time.Now()
	result, err := e.syncProject(ctx, target)
	result.Duration = time.Since(started)
	if result.Project == "" {
		result.Project = target.Project.Name
	}
	return result, err
}

func (e *Engine) syncProject(ctx context.Context, target ProjectTarget) (SyncResult, error) {
	project := target.Project
	if e.Client == nil {
		return SyncResult{}, errors.New("sync client is nil")
	}
	if e.DeviceID == "" {
		return SyncResult{}, errors.New("device_id is required")
	}
	localProject := target.LocalDir
	if err := CheckProjectDir(localProject, target.StateRoot); err != nil {
		return SyncResult{}, err
	}
	base, hasBase, err := loadBase(
		target.StateRoot, project.ID, localProject, classicProjectDir(target.StateRoot, project),
	)
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
	local, err := e.localManifest(localProject)
	if err != nil {
		return SyncResult{}, err
	}

	var plan Plan
	plan, err = resolvePlan(
		project.Name, base, hasBase, local, remote, target.ForcePolicy, target.InitialPolicy,
	)
	if err != nil {
		return SyncResult{}, err
	}
	if target.DryRun {
		return SyncResult{
			Project:   project.Name,
			Actions:   len(plan.Actions),
			Conflicts: plan.Conflicts,
			Planned:   describePlan(plan),
		}, nil
	}
	if len(plan.Conflicts) != 0 {
		return SyncResult{Project: project.Name, Conflicts: plan.Conflicts},
			&ConflictError{Project: project.Name, Paths: plan.Conflicts}
	}
	if len(plan.Actions) == 0 {
		if err := saveBase(target.StateRoot, project.ID, localProject, remote); err != nil {
			return SyncResult{}, err
		}
		e.rememberRemote(project.ID, remote)
		return SyncResult{Project: project.Name, InSync: true}, nil
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
	plan, err = resolvePlan(
		project.Name, base, hasBase, local, remote, target.ForcePolicy, target.InitialPolicy,
	)
	if err != nil {
		return SyncResult{}, err
	}
	if len(plan.Conflicts) != 0 {
		return SyncResult{Project: project.Name, Conflicts: plan.Conflicts},
			&ConflictError{Project: project.Name, Paths: plan.Conflicts}
	}
	if len(plan.Actions) == 0 {
		if err := saveBase(target.StateRoot, project.ID, localProject, remote); err != nil {
			return SyncResult{}, err
		}
		e.rememberRemote(project.ID, remote)
		return SyncResult{Project: project.Name, InSync: true}, nil
	}
	// Only a three-way merge is guarded. A forced pass and a bootstrap are
	// the user's explicit answer to "which side wins?", not an accident.
	if target.ForcePolicy == "" && hasBase && !e.AllowBulkDelete {
		if err := guardBulkDelete(
			project.Name, plan, len(local.Entries), len(remote.Entries),
		); err != nil {
			return SyncResult{Project: project.Name}, err
		}
	}
	result, err := e.applyPlan(ctx, project, target.StateRoot, lease, localProject, plan)
	result.Project = project.Name
	result.Actions = len(plan.Actions)
	if err != nil {
		return result, err
	}

	finalLocal, err := e.localManifest(localProject)
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
		return result, errors.New("同步完成后本地和服务器仍不一致")
	}
	if err := saveBase(target.StateRoot, project.ID, localProject, finalRemote); err != nil {
		return result, err
	}
	e.rememberRemote(project.ID, finalRemote)
	result.InSync = true
	return result, nil
}

// describePlan renders a plan for a dry run: what would be deleted, uploaded
// or downloaded, and what stopped because both sides changed.
func describePlan(plan Plan) []string {
	out := make([]string, 0, len(plan.Actions)+len(plan.Conflicts))
	for _, path := range plan.Conflicts {
		out = append(out, "conflict      "+path)
	}
	for _, action := range plan.Actions {
		out = append(out, fmt.Sprintf("%-13s %s", action.Type, action.Entry.Path))
	}
	return out
}

// resolvePlan picks how one pass reconciles a project. A forced policy wins
// over everything: it resolves the project as if it were bootstrapping, which
// is exactly what "sync now, this side wins" means and is why it can delete
// files the user still has. Otherwise a project with no usable baseline
// bootstraps under its initial policy, and everything else merges three-way.
func resolvePlan(
	name string,
	base Manifest,
	hasBase bool,
	local, remote Manifest,
	forcePolicy, initialPolicy string,
) (Plan, error) {
	switch {
	case forcePolicy != "":
		return bootstrapPlan(name, forcePolicy, local, remote)
	case !hasBase:
		return bootstrapPlan(name, initialPolicy, local, remote)
	default:
		return BuildPlan(Entries(base), Entries(local), Entries(remote)), nil
	}
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
	project Project,
	stateRoot string,
	lease Lease,
	localProject string,
	plan Plan,
) (SyncResult, error) {
	var result SyncResult
	progress := newReporter(e.OnProgress, project.Name, plan)
	trashDir := trashRoot(stateRoot, project.Name, time.Now())

	for index, action := range plan.Actions {
		target, err := safeProjectPath(localProject, action.Entry.Path)
		if err != nil {
			return result, err
		}
		phase := phaseFor(action.Type)
		progress.begin(index+1, phase, action.Entry.Path)
		started := time.Now()
		var moved int64

		switch action.Type {
		case ActionUpload:
			moved, err = e.upload(ctx, project.ID, lease, action.Entry, target, progress)
			result.Uploaded++
		case ActionDeleteRemote:
			err = e.Client.DeleteFile(ctx, project.ID, lease.LeaseID, lease.DeviceID, action.Entry.Path)
			result.DeletedRemote++
		case ActionDownload:
			moved, err = e.download(ctx, project.ID, action.Entry, target, progress)
			result.Downloaded++
		case ActionDeleteLocal:
			// Never os.RemoveAll: the server copy may have been deleted by an
			// agent in the container, and this is the user's only other copy.
			// The trash sits under .agentbox-sync, which the manifest walker
			// excludes, so rescued files never sync themselves back.
			err = moveToTrash(target, filepath.Join(trashDir, filepath.FromSlash(action.Entry.Path)))
			result.DeletedLocal++
			result.TrashDir = trashDir
		default:
			err = fmt.Errorf("unknown sync action %q", action.Type)
		}
		if err != nil {
			return result, err
		}
		result.Bytes += moved
		if e.OnTransfer != nil {
			e.OnTransfer(Transfer{
				Project:    project.Name,
				Phase:      phase,
				Path:       action.Entry.Path,
				Bytes:      moved,
				DurationMS: time.Since(started).Milliseconds(),
			})
		}
	}
	progress.finish()
	return result, nil
}

func (e *Engine) upload(
	ctx context.Context,
	projectID string,
	lease Lease,
	entry Entry,
	target string,
	progress *reporter,
) (int64, error) {
	switch entry.Kind {
	case "dir":
		return 0, e.Client.PutFile(ctx, projectID, lease.LeaseID, lease.DeviceID, entry, nil)
	case "file":
		file, err := os.Open(target)
		if err != nil {
			return 0, err
		}
		var sent int64
		body := &countingReader{inner: file, count: func(n int64) {
			sent += n
			progress.advance(n)
		}}
		err = e.Client.PutFile(ctx, projectID, lease.LeaseID, lease.DeviceID, entry, body)
		closeErr := file.Close()
		if err != nil {
			return sent, err
		}
		return sent, closeErr
	default:
		return 0, fmt.Errorf("live sync does not support %s: %s", entry.Kind, entry.Path)
	}
}

func (e *Engine) download(
	ctx context.Context,
	projectID string,
	entry Entry,
	target string,
	progress *reporter,
) (int64, error) {
	switch entry.Kind {
	case "dir":
		return 0, os.MkdirAll(target, os.FileMode(entry.Mode))
	case "file":
		body, err := e.Client.OpenFile(ctx, projectID, entry.Path)
		if err != nil {
			return 0, err
		}
		var got int64
		counted := &countingReader{inner: body, count: func(n int64) {
			got += n
			progress.advance(n)
		}}
		err = writeVerifiedFile(target, entry.SHA256, counted, os.FileMode(entry.Mode), entry.MTime)
		closeErr := body.Close()
		var mismatch *DownloadMismatchError
		if errors.As(err, &mismatch) {
			mismatch.Path = entry.Path
		}
		if err != nil {
			return got, err
		}
		return got, closeErr
	default:
		return 0, fmt.Errorf("live sync does not support %s: %s", entry.Kind, entry.Path)
	}
}

func phaseFor(kind ActionType) string {
	switch kind {
	case ActionUpload:
		return PhaseUpload
	case ActionDownload:
		return PhaseDownload
	case ActionDeleteLocal:
		return PhaseDeleteLocal
	case ActionDeleteRemote:
		return PhaseDeleteRemote
	default:
		return string(kind)
	}
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

// classicProjectDir is where a project lives when it has no explicit local
// directory. It is still needed after per-project directories exist, because
// a baseline written before that feature describes exactly this path.
func classicProjectDir(stateRoot string, project Project) string {
	return filepath.Join(stateRoot, project.Name)
}

// CheckProjectDir rejects project directories that would sync something far
// wider than the user meant. StateRoot is refused as an ancestor because the
// baseline directory and every other project live under it, so pointing a
// project at a parent of StateRoot would upload the whole workspace into one
// project. Callers validate with it up front so a bad override fails loudly
// instead of silently syncing the wrong tree.
func CheckProjectDir(dir, stateRoot string) error {
	if dir == "" {
		return errors.New("project directory is required")
	}
	if !filepath.IsAbs(dir) {
		return fmt.Errorf("project directory must be absolute: %s", dir)
	}
	clean := filepath.Clean(dir)
	if clean == string(filepath.Separator) {
		return fmt.Errorf("refusing to sync the filesystem root: %s", dir)
	}
	if stateRoot != "" {
		if rel, err := filepath.Rel(clean, filepath.Clean(stateRoot)); err == nil && filepath.IsLocal(rel) {
			return fmt.Errorf("project directory %s contains the sync root %s", dir, stateRoot)
		}
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

// DownloadMismatchError means the bytes that arrived are not the bytes the
// manifest promised. The usual culprit is a proxy rewriting the response —
// Cloudflare's analytics auto-injection appends a <script> to anything served
// as text/html — and accepting it would make the local copy differ from the
// server, after which a merge pass pushes the tampered file back up.
type DownloadMismatchError struct {
	Path string
	Want string
	Got  string
}

func (e *DownloadMismatchError) Error() string {
	return fmt.Sprintf("下载的 %s 与服务器清单的校验和不一致（可能被中间代理改写），已拒绝写入", e.Path)
}

func writeLocalFile(target string, body io.Reader, mode os.FileMode, modified string) error {
	return writeVerifiedFile(target, "", body, mode, modified)
}

// writeVerifiedFile writes body to target atomically. With a non-empty
// wantSHA256 the content is hashed on the way to disk and the rename only
// happens when it matches, so a tampered download never replaces a good file.
func writeVerifiedFile(target, wantSHA256 string, body io.Reader, mode os.FileMode, modified string) error {
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(target), ".agentbox-download-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	hash := sha256.New()
	if _, err := io.Copy(io.MultiWriter(tmp, hash), body); err != nil {
		tmp.Close()
		return err
	}
	if got := hex.EncodeToString(hash.Sum(nil)); wantSHA256 != "" && got != wantSHA256 {
		tmp.Close()
		rel := filepath.Base(target)
		return &DownloadMismatchError{Path: rel, Want: wantSHA256, Got: got}
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

func stateDir(stateRoot string) string {
	return filepath.Join(stateRoot, ".agentbox-sync")
}

func basePath(stateRoot, projectID string) string {
	return filepath.Join(stateDir(stateRoot), projectID+".json")
}

// baseRecord is what actually lands in <StateRoot>/.agentbox-sync/<id>.json.
// Recording the directory it describes is what makes a moved project safe:
// the old baseline lists files under the previous path, so reusing it would
// read as "every file was deleted locally" and wipe the server copy.
type baseRecord struct {
	LocalDir string   `json:"local_dir"`
	Manifest Manifest `json:"manifest"`
}

// loadBase returns the baseline for a project, or hasBase=false when the
// baseline describes a different directory than the one being synced now.
// Files written before baseRecord existed hold a bare Manifest and can only
// be trusted while the project still sits at the classic localRoot/name path.
func loadBase(stateRoot, projectID, localDir, classicDir string) (Manifest, bool, error) {
	raw, err := os.ReadFile(basePath(stateRoot, projectID))
	if os.IsNotExist(err) {
		return Manifest{}, false, nil
	}
	if err != nil {
		return Manifest{}, false, err
	}
	var probe map[string]json.RawMessage
	if err := json.Unmarshal(raw, &probe); err != nil {
		return Manifest{}, false, fmt.Errorf("parse sync base: %w", err)
	}
	if _, ok := probe["manifest"]; ok {
		var record baseRecord
		if err := json.Unmarshal(raw, &record); err != nil {
			return Manifest{}, false, fmt.Errorf("parse sync base: %w", err)
		}
		if record.LocalDir != localDir {
			return Manifest{}, false, nil
		}
		filtered, err := FilterManifest(record.Manifest, localDir)
		if err != nil {
			return Manifest{}, false, err
		}
		return filtered, true, nil
	}
	var legacy Manifest
	if err := json.Unmarshal(raw, &legacy); err != nil {
		return Manifest{}, false, fmt.Errorf("parse sync base: %w", err)
	}
	if localDir != classicDir {
		return Manifest{}, false, nil
	}
	filtered, err := FilterManifest(legacy, localDir)
	if err != nil {
		return Manifest{}, false, err
	}
	return filtered, true, nil
}

func saveBase(stateRoot, projectID, localDir string, manifest Manifest) error {
	dir := stateDir(stateRoot)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	target := basePath(stateRoot, projectID)
	raw, err := json.MarshalIndent(baseRecord{LocalDir: localDir, Manifest: manifest}, "", "  ")
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
