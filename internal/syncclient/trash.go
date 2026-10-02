package syncclient

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// TrashDirName holds locally removed copies under the sync state directory.
// It sits inside .agentbox-sync, which the manifest walker already excludes,
// so rescued files never sync themselves back to the server.
const TrashDirName = "trash"

// bulkDeleteMin is the smallest deletion batch the guard will ever stop. Below
// it the ratio test is skipped: a two-file project loses "half its files" every
// time someone deletes one, and tripping on that would make sync unusable.
const bulkDeleteMin = 5

// BulkDeleteError stops a pass that would wipe out most of one side. The
// usual cause is an agent running `rm -rf` in the container (or a local folder
// that got moved while sync was off): the plan is technically correct, and
// applying it destroys the other copy too.
type BulkDeleteError struct {
	Project string
	Side    string // "local" or "remote" — the side the deletions land on
	Deletes int
	Total   int
}

func (e *BulkDeleteError) Error() string {
	side := "本地"
	if e.Side == "remote" {
		side = "服务器"
	}
	return fmt.Sprintf(
		"项目 %s 这一轮要删掉%s %d/%d 项，疑似误删，已暂停同步；确认无误后用 allow_bulk_delete 放行",
		e.Project, side, e.Deletes, e.Total,
	)
}

// guardBulkDelete refuses a plan whose deletions look like an accident rather
// than an edit. Checked per direction, because the two sides fail differently:
// an agent wiping /workspace shows up as delete_local, a local folder that
// vanished shows up as delete_remote.
func guardBulkDelete(project string, plan Plan, localCount, remoteCount int) error {
	var local, remote int
	for _, action := range plan.Actions {
		switch action.Type {
		case ActionDeleteLocal:
			local++
		case ActionDeleteRemote:
			remote++
		}
	}
	if local >= bulkDeleteMin && local*2 >= localCount {
		return &BulkDeleteError{Project: project, Side: "local", Deletes: local, Total: localCount}
	}
	if remote >= bulkDeleteMin && remote*2 >= remoteCount {
		return &BulkDeleteError{Project: project, Side: "remote", Deletes: remote, Total: remoteCount}
	}
	return nil
}

// trashRoot is where one sync pass parks everything it removes locally. The
// timestamp groups a pass together so an accidental wipe can be restored with
// a single move back.
func trashRoot(localRoot, projectName string, stamp time.Time) string {
	return filepath.Join(
		stateDir(localRoot),
		TrashDirName,
		sanitizeTrashName(projectName),
		stamp.UTC().Format("20060102T150405Z"),
	)
}

// sanitizeTrashName keeps a project name from escaping the trash directory.
// Names come from the server's project list, which is itself derived from
// directory names, but the trash path is built with plain filepath.Join.
func sanitizeTrashName(name string) string {
	clean := strings.Map(func(r rune) rune {
		switch r {
		case '/', '\\', ':', 0:
			return '-'
		}
		return r
	}, name)
	clean = strings.TrimSpace(clean)
	if clean == "" || clean == "." || clean == ".." {
		return "project"
	}
	return clean
}

// moveToTrash relocates target under dest instead of deleting it.
//
// Deletions are applied deepest-first, so by the time a directory is removed
// its children are already sitting at the matching place in the trash; the
// plain rename then fails with EEXIST/ENOTEMPTY and the merge path below takes
// over. A missing target is not an error: the file may already be gone.
func moveToTrash(target, dest string) error {
	info, err := os.Lstat(target)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o700); err != nil {
		return err
	}
	if _, err := os.Lstat(dest); errors.Is(err, os.ErrNotExist) {
		if err := os.Rename(target, dest); err == nil {
			return nil
		}
	}
	if info.IsDir() {
		if err := os.MkdirAll(dest, 0o700); err != nil {
			return err
		}
		entries, err := os.ReadDir(target)
		if err != nil {
			return err
		}
		for _, entry := range entries {
			if err := moveToTrash(
				filepath.Join(target, entry.Name()),
				filepath.Join(dest, entry.Name()),
			); err != nil {
				return err
			}
		}
		return os.Remove(target)
	}
	return os.Rename(target, uniqueTrashPath(dest))
}

// uniqueTrashPath avoids clobbering an earlier rescue of the same path within
// one pass; the trash is worthless if a second delete overwrites the first.
func uniqueTrashPath(dest string) string {
	for i := 1; i < 1000; i++ {
		candidate := fmt.Sprintf("%s.%d", dest, i)
		if _, err := os.Lstat(candidate); errors.Is(err, os.ErrNotExist) {
			return candidate
		}
	}
	return dest + "." + fmt.Sprint(time.Now().UnixNano())
}
