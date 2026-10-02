package server

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"agentbox/internal/dockerx"
	"agentbox/internal/safefs"
	"agentbox/internal/store"
)

const (
	syncLeaseTTL       = 60 * time.Second
	syncMaxFileBytes   = 2 << 30
	syncMaxManifestN   = 100000
	syncLeaseHeader    = "X-Agentbox-Lease"
	syncDeviceHeader   = "X-Agentbox-Device"
	syncFileModeHeader = "X-Agentbox-File-Mode"
	syncKindHeader     = "X-Agentbox-Kind"
)

type syncManifestEntry struct {
	Path       string `json:"path"`
	Kind       string `json:"kind"`
	Size       int64  `json:"size,omitempty"`
	Mode       uint32 `json:"mode,omitempty"`
	MTime      string `json:"mtime,omitempty"`
	SHA256     string `json:"sha256,omitempty"`
	LinkTarget string `json:"link_target,omitempty"`
}

type syncManifest struct {
	ProjectID string              `json:"project_id"`
	Revision  string              `json:"revision"`
	Entries   []syncManifestEntry `json:"entries"`
}

func (s *Server) handleSyncManifest(w http.ResponseWriter, r *http.Request) {
	project, _, ok := s.syncProjectRequest(w, r)
	if !ok {
		return
	}
	root, err := s.openSyncProject(project)
	if err != nil {
		writeErr(w, http.StatusNotFound, "项目目录不存在")
		return
	}
	defer root.Close()

	// The manifest build hashes every file, which is too expensive to run at
	// one-second poll rates. The tree's stat signature (path/size/mtime/mode/
	// link target) is cheap to compute; while it stays unchanged the cached
	// manifest — hashes included — remains valid. The cache backstop re-hashes
	// at least once a minute so pathological same-mtime edits self-heal.
	sig, err := s.statSyncSignature(root)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	ifRevision := r.Header.Get("X-Agentbox-If-Revision")
	if cached, ok := s.syncManifests.get(project.ID, sig, time.Now()); ok {
		if ifRevision != "" && cached.Revision == ifRevision {
			w.Header().Set("X-Agentbox-Revision", cached.Revision)
			w.WriteHeader(http.StatusNoContent)
			return
		}
		writeJSON(w, http.StatusOK, cached)
		return
	}
	manifest, err := buildSyncManifest(project.ID, root)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.syncManifests.put(project.ID, sig, manifest, time.Now())
	if ifRevision != "" && manifest.Revision == ifRevision {
		w.Header().Set("X-Agentbox-Revision", manifest.Revision)
		w.WriteHeader(http.StatusNoContent)
		return
	}
	writeJSON(w, http.StatusOK, manifest)
}

type syncManifestCacheEntry struct {
	statSig  string
	manifest syncManifest
	builtAt  time.Time
}

type syncManifestCache struct {
	mu      sync.Mutex
	entries map[string]syncManifestCacheEntry
}

func (c *syncManifestCache) get(projectID, statSig string, now time.Time) (syncManifest, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	entry, ok := c.entries[projectID]
	if !ok || entry.statSig != statSig || now.Sub(entry.builtAt) > time.Minute {
		return syncManifest{}, false
	}
	return entry.manifest, true
}

func (c *syncManifestCache) put(projectID, statSig string, manifest syncManifest, now time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.entries == nil {
		c.entries = map[string]syncManifestCacheEntry{}
	}
	c.entries[projectID] = syncManifestCacheEntry{statSig: statSig, manifest: manifest, builtAt: now}
}

// statSyncSignature hashes the tree's metadata without reading file contents.
func (s *Server) statSyncSignature(root *safefs.Root) (string, error) {
	hash := sha256.New()
	err := fs.WalkDir(root.FS(), ".", func(name string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if name == "." {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		kind := "file"
		link := ""
		switch {
		case info.Mode()&os.ModeSymlink != 0:
			kind = "symlink"
			target, err := root.Readlink(name)
			if err != nil {
				return err
			}
			link = target
		case info.IsDir():
			kind = "dir"
		}
		fmt.Fprintf(hash, "%s\x00%s\x00%d\x00%d\x00%s\x00%s\n",
			filepath.ToSlash(name), kind, info.Size(), uint32(info.Mode().Perm()),
			info.ModTime().UTC().Format(time.RFC3339Nano), link)
		return nil
	})
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func (s *Server) handleSyncLease(w http.ResponseWriter, r *http.Request) {
	project, _, ok := s.syncProjectRequest(w, r)
	if !ok {
		return
	}
	if r.Method == http.MethodDelete {
		leaseID := strings.TrimSpace(r.Header.Get(syncLeaseHeader))
		if leaseID == "" {
			writeErr(w, http.StatusBadRequest, "缺少租约")
			return
		}
		if err := s.store.ReleaseSyncLease(project.ID, leaseID); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]bool{"released": true})
		return
	}

	var req struct {
		DeviceID   string `json:"device_id"`
		DeviceName string `json:"device_name"`
		TTLSeconds int    `json:"ttl_seconds"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10)).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "请求体格式错误")
		return
	}
	req.DeviceID = strings.TrimSpace(req.DeviceID)
	req.DeviceName = strings.TrimSpace(req.DeviceName)
	if req.DeviceID == "" || len(req.DeviceID) > 128 || len(req.DeviceName) > 128 {
		writeErr(w, http.StatusBadRequest, "设备信息无效")
		return
	}
	if req.TTLSeconds == 0 {
		req.TTLSeconds = int(syncLeaseTTL.Seconds())
	}
	if req.TTLSeconds < 30 || req.TTLSeconds > 300 {
		writeErr(w, http.StatusBadRequest, "租约时长需在 30 到 300 秒之间")
		return
	}
	lease, acquired, err := s.store.AcquireSyncLease(
		project.ID,
		req.DeviceID,
		req.DeviceName,
		time.Duration(req.TTLSeconds)*time.Second,
		time.Now(),
	)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !acquired {
		writeJSON(w, http.StatusConflict, map[string]any{
			"error": "项目正在由其他设备同步",
			"lease": lease,
		})
		return
	}
	writeJSON(w, http.StatusOK, lease)
}

func (s *Server) handleSyncFile(w http.ResponseWriter, r *http.Request) {
	project, _, ok := s.syncProjectRequest(w, r)
	if !ok {
		return
	}
	root, err := s.openSyncProject(project)
	if err != nil {
		writeErr(w, http.StatusNotFound, "项目目录不存在")
		return
	}
	defer root.Close()
	rel := cleanSyncPath(r.URL.Query().Get("path"))
	if rel == "" {
		writeErr(w, http.StatusBadRequest, "文件路径无效")
		return
	}
	switch r.Method {
	case http.MethodGet:
		s.serveSyncFile(w, r, root, rel)
	case http.MethodPut:
		if !s.requireSyncLease(w, r, project.ID) {
			return
		}
		s.putSyncFile(w, r, root, rel)
	case http.MethodDelete:
		if !s.requireSyncLease(w, r, project.ID) {
			return
		}
		s.deleteSyncFile(w, root, rel)
	default:
		writeErr(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

func (s *Server) syncProjectRequest(
	w http.ResponseWriter,
	r *http.Request,
) (store.SyncProject, store.Session, bool) {
	project, ok := s.store.SyncProject(r.PathValue("project"))
	if !ok {
		writeErr(w, http.StatusNotFound, "项目不存在")
		return store.SyncProject{}, store.Session{}, false
	}
	sess, ok := s.store.Get(project.SessionID)
	if !ok || sess.User != reqUser(r).Name {
		writeErr(w, http.StatusNotFound, "项目不存在")
		return store.SyncProject{}, store.Session{}, false
	}
	return project, sess, true
}

func (s *Server) openSyncProject(project store.SyncProject) (*safefs.Root, error) {
	sess, ok := s.store.Get(project.SessionID)
	if !ok {
		return nil, os.ErrNotExist
	}
	workspace, err := s.openDataDir(s.workspaceDir(sess))
	if err != nil {
		return nil, err
	}
	defer workspace.Close()
	return workspace.Sub(project.Name)
}

func buildSyncManifest(projectID string, root *safefs.Root) (syncManifest, error) {
	entries := []syncManifestEntry{}
	err := fs.WalkDir(root.FS(), ".", func(name string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if name == "." {
			return nil
		}
		if len(entries) >= syncMaxManifestN {
			return fmt.Errorf("项目文件数超过 %d", syncMaxManifestN)
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		item := syncManifestEntry{
			Path:  filepath.ToSlash(name),
			Mode:  uint32(info.Mode().Perm()),
			MTime: info.ModTime().UTC().Format(time.RFC3339Nano),
		}
		switch {
		case info.Mode()&os.ModeSymlink != 0:
			target, err := root.Readlink(name)
			if err != nil {
				return err
			}
			item.Kind = "symlink"
			item.LinkTarget = target
		case info.IsDir():
			item.Kind = "dir"
		case info.Mode().IsRegular():
			item.Kind = "file"
			item.Size = info.Size()
			file, err := root.OpenFile(name)
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
			item.SHA256 = hex.EncodeToString(hash.Sum(nil))
		default:
			return nil
		}
		entries = append(entries, item)
		return nil
	})
	if err != nil {
		return syncManifest{}, err
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Path < entries[j].Path })
	revisionHash := sha256.New()
	for _, entry := range entries {
		fmt.Fprintf(revisionHash, "%s\x00%s\x00%d\x00%d\x00%s\x00%s\x00%s\n",
			entry.Path, entry.Kind, entry.Size, entry.Mode, entry.MTime, entry.SHA256, entry.LinkTarget)
	}
	return syncManifest{
		ProjectID: projectID,
		Revision:  hex.EncodeToString(revisionHash.Sum(nil)),
		Entries:   entries,
	}, nil
}

func (s *Server) requireSyncLease(w http.ResponseWriter, r *http.Request, projectID string) bool {
	leaseID := strings.TrimSpace(r.Header.Get(syncLeaseHeader))
	if leaseID == "" {
		writeErr(w, http.StatusLocked, "缺少同步租约")
		return false
	}
	lease, ok := s.store.ValidateSyncLease(projectID, leaseID, time.Now())
	if !ok {
		writeErr(w, http.StatusLocked, "同步租约已过期或已被其他设备接管")
		return false
	}
	deviceID := strings.TrimSpace(r.Header.Get(syncDeviceHeader))
	if deviceID == "" || deviceID != lease.DeviceID {
		writeErr(w, http.StatusLocked, "同步租约不属于当前设备")
		return false
	}
	return true
}

func (s *Server) serveSyncFile(w http.ResponseWriter, r *http.Request, root *safefs.Root, rel string) {
	file, err := root.OpenFile(rel)
	if err != nil {
		writeErr(w, http.StatusNotFound, "文件不存在或不是普通文件")
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	// Always opaque bytes, never the file's own type. A CDN in front of the
	// server rewrites what it believes is a page — Cloudflare's analytics
	// auto-injection appends a <script> to every text/html response — and a
	// sync client that receives the rewritten file sees a local copy that no
	// longer matches the server, which a later merge pass then pushes back up.
	// no-transform asks every intermediary to leave the bytes alone as well.
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Cache-Control", "private, no-store, no-transform")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	http.ServeContent(w, r, filepath.Base(rel), info.ModTime(), file)
}

func (s *Server) putSyncFile(w http.ResponseWriter, r *http.Request, root *safefs.Root, rel string) {
	parent := path.Dir(rel)
	if parent != "." {
		if err := root.MkdirAll(parent, 0o755); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	mode := os.FileMode(0o644)
	if raw := strings.TrimSpace(r.Header.Get(syncFileModeHeader)); raw != "" {
		value, err := strconv.ParseUint(raw, 8, 32)
		if err != nil || value > 0o777 {
			writeErr(w, http.StatusBadRequest, "文件权限无效")
			return
		}
		mode = os.FileMode(value)
	}
	if strings.TrimSpace(r.Header.Get(syncKindHeader)) == "dir" {
		if err := root.MkdirAll(rel, mode); err != nil {
			writeErr(w, http.StatusBadRequest, err.Error())
			return
		}
		// MkdirAll's mode goes through the process umask, and the unit sets
		// UMask=0077: a directory the client sent as 0755 landed as 0700, the
		// manifest reported 0700 back, and the client saw a difference it could
		// never resolve — every pass re-uploaded the project's whole directory
		// tree, forever. chmod is not subject to the umask.
		if err := root.ChmodDir(rel, mode); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		_ = root.Chown(rel, dockerx.AgentUID, dockerx.AgentGID)
		writeJSON(w, http.StatusOK, map[string]any{"path": rel, "kind": "dir", "mode": mode.Perm()})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, syncMaxFileBytes)
	info, err := root.WriteAtomic(rel, r.Body, safefs.WriteOptions{
		Mode:            mode,
		Chown:           true,
		UID:             dockerx.AgentUID,
		GID:             dockerx.AgentGID,
		BestEffortChown: true,
		MaxBytes:        syncMaxFileBytes,
		Limit:           true,
	})
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"path": rel, "size": info.Size(), "mode": info.Mode().Perm()})
}

func (s *Server) deleteSyncFile(w http.ResponseWriter, root *safefs.Root, rel string) {
	info, err := root.Lstat(rel)
	if err != nil {
		writeErr(w, http.StatusNotFound, "文件不存在")
		return
	}
	if info.IsDir() {
		entries, err := root.ReadDir(rel)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		if len(entries) != 0 {
			writeErr(w, http.StatusConflict, "目录非空，请先删除子项")
			return
		}
	}
	if err := root.RemoveAll(rel); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"deleted": true})
}

func cleanSyncPath(value string) string {
	value = strings.TrimSpace(strings.ReplaceAll(value, "\\", "/"))
	if value == "" || strings.HasPrefix(value, "/") {
		return ""
	}
	clean := path.Clean(value)
	if clean == "." || clean == ".." || strings.HasPrefix(clean, "../") {
		return ""
	}
	return clean
}
