package store

import (
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"path/filepath"
	"sort"
	"time"
)

// SyncProject is one project directory inside an instance.
//
// Agent overrides the instance default tool for this project; empty means
// "whatever the instance defaults to". Path is the absolute host path of the
// directory, which is also the path inside the container — the container binds
// the host directory at that same absolute path, so a path printed in a
// terminal is valid on both sides.
type SyncProject struct {
	ID        string `json:"id"`
	SessionID string `json:"session_id"`
	Name      string `json:"name"`
	Agent     string `json:"agent"`
	Path      string `json:"path"`
	// Command is the project's own launch command; empty means the default
	// for its agent (see server.projectLaunch).
	Command   string    `json:"command"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

type SyncLease struct {
	ProjectID  string    `json:"project_id"`
	LeaseID    string    `json:"lease_id"`
	DeviceID   string    `json:"device_id"`
	DeviceName string    `json:"device_name"`
	ExpiresAt  time.Time `json:"expires_at"`
	UpdatedAt  time.Time `json:"updated_at"`
}

// ReconcileSyncProjects assigns stable IDs to the current top-level project
// directories and removes registry rows whose directories no longer exist.
//
// dir is the instance workspace directory on the host; new rows record
// dir/<name> as their path so the path is known from the moment a project
// appears instead of waiting for a backfill pass.
func (s *Store) ReconcileSyncProjects(sessionID, dir string, names []string) ([]SyncProject, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	current := make(map[string]bool, len(names))
	for _, name := range names {
		current[name] = true
	}
	rows, err := tx.Query(`SELECT `+syncProjectCols+`
		FROM sync_projects WHERE session_id = ?`, sessionID)
	if err != nil {
		return nil, err
	}
	existing := map[string]SyncProject{}
	for rows.Next() {
		p, err := scanSyncProject(rows)
		if err != nil {
			rows.Close()
			return nil, err
		}
		if !current[p.Name] {
			if _, err := tx.Exec(`DELETE FROM sync_leases WHERE project_id = ?`, p.ID); err != nil {
				rows.Close()
				return nil, err
			}
			if _, err := tx.Exec(`DELETE FROM sync_projects WHERE id = ?`, p.ID); err != nil {
				rows.Close()
				return nil, err
			}
			continue
		}
		existing[p.Name] = p
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}

	now := time.Now()
	for _, name := range names {
		if _, ok := existing[name]; ok {
			continue
		}
		p := SyncProject{
			ID: NewID(), SessionID: sessionID, Name: name,
			Path:      projectPath(dir, name),
			CreatedAt: now, UpdatedAt: now,
		}
		if _, err := tx.Exec(`INSERT INTO sync_projects
			(id, session_id, name, agent, path, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
			p.ID, p.SessionID, p.Name, p.Agent, p.Path,
			p.CreatedAt.Format(time.RFC3339Nano), p.UpdatedAt.Format(time.RFC3339Nano)); err != nil {
			return nil, err
		}
		existing[name] = p
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	out := make([]SyncProject, 0, len(existing))
	for _, p := range existing {
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// SyncProjects returns every registered project of an instance, by name.
func (s *Store) SyncProjects(sessionID string) ([]SyncProject, error) {
	rows, err := s.db.Query(`SELECT `+syncProjectCols+`
		FROM sync_projects WHERE session_id = ? ORDER BY name`, sessionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SyncProject
	for rows.Next() {
		p, err := scanSyncProject(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func (s *Store) SyncProject(id string) (SyncProject, bool) {
	p, err := scanSyncProject(s.db.QueryRow(`SELECT `+syncProjectCols+`
		FROM sync_projects WHERE id = ?`, id))
	return p, err == nil
}

// projectPath is the absolute host path of a project directory. It is also the
// path inside the container, which is why it is derived rather than stored
// per-row at insert time only.
func projectPath(dir, name string) string {
	if dir == "" {
		return ""
	}
	return filepath.Join(dir, name)
}

func (s *Store) RenameSyncProject(id, name string) (SyncProject, error) {
	now := time.Now()
	// A rename moves the directory, so the stored path has to move with it.
	// Compute it in Go rather than with a SQL replace(): string surgery on the
	// old path would misbehave whenever the name also occurs in a parent
	// directory. Rows created before the path column existed keep an empty
	// path; the server-layer backfill fills those in.
	current, ok := s.SyncProject(id)
	if !ok {
		return SyncProject{}, sql.ErrNoRows
	}
	newPath := ""
	if current.Path != "" {
		newPath = filepath.Join(filepath.Dir(current.Path), name)
	}
	if _, err := s.db.Exec(`UPDATE sync_projects SET name = ?, path = ?, updated_at = ? WHERE id = ?`,
		name, newPath, now.Format(time.RFC3339Nano), id); err != nil {
		return SyncProject{}, err
	}
	project, ok := s.SyncProject(id)
	if !ok {
		return SyncProject{}, sql.ErrNoRows
	}
	return project, nil
}

// BackfillSyncProjectPaths fills in the absolute path for rows created before
// the column existed. Only empty paths are touched, so it is safe to run on
// every boot.
func (s *Store) BackfillSyncProjectPaths(sessionID, dir string) error {
	if dir == "" {
		return nil
	}
	rows, err := s.db.Query(`SELECT `+syncProjectCols+` FROM sync_projects WHERE session_id = ? AND path = ''`, sessionID)
	if err != nil {
		return err
	}
	defer rows.Close()
	var pending []SyncProject
	for rows.Next() {
		p, err := scanSyncProject(rows)
		if err != nil {
			return err
		}
		pending = append(pending, p)
	}
	if err := rows.Err(); err != nil {
		return err
	}
	for _, p := range pending {
		if _, err := s.db.Exec(`UPDATE sync_projects SET path = ? WHERE id = ?`, filepath.Join(dir, p.Name), p.ID); err != nil {
			return err
		}
	}
	return nil
}

// SetSyncProjectAgent pins a project to claude or codex. An empty agent clears
// the override so the project falls back to the instance default.
func (s *Store) SetSyncProjectAgent(id, agent string) (SyncProject, error) {
	if _, err := s.db.Exec(`UPDATE sync_projects SET agent = ?, updated_at = ? WHERE id = ?`,
		agent, time.Now().Format(time.RFC3339Nano), id); err != nil {
		return SyncProject{}, err
	}
	project, ok := s.SyncProject(id)
	if !ok {
		return SyncProject{}, sql.ErrNoRows
	}
	return project, nil
}

// SetSyncProjectCommand stores a project's launch command. Empty restores the
// default for the project's agent.
func (s *Store) SetSyncProjectCommand(id, command string) (SyncProject, error) {
	if _, err := s.db.Exec(`UPDATE sync_projects SET command = ?, updated_at = ? WHERE id = ?`,
		command, time.Now().Format(time.RFC3339Nano), id); err != nil {
		return SyncProject{}, err
	}
	project, ok := s.SyncProject(id)
	if !ok {
		return SyncProject{}, sql.ErrNoRows
	}
	return project, nil
}

func (s *Store) DeleteSyncProject(id string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM sync_leases WHERE project_id = ?`, id); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM sync_projects WHERE id = ?`, id); err != nil {
		return err
	}
	return tx.Commit()
}

const syncProjectCols = "id, session_id, name, agent, path, command, created_at, updated_at"

func scanSyncProject(row interface{ Scan(...any) error }) (SyncProject, error) {
	var p SyncProject
	var created, updated string
	if err := row.Scan(&p.ID, &p.SessionID, &p.Name, &p.Agent, &p.Path, &p.Command, &created, &updated); err != nil {
		return SyncProject{}, err
	}
	var err error
	if p.CreatedAt, err = time.Parse(time.RFC3339Nano, created); err != nil {
		return SyncProject{}, err
	}
	if p.UpdatedAt, err = time.Parse(time.RFC3339Nano, updated); err != nil {
		return SyncProject{}, err
	}
	return p, nil
}

// AcquireSyncLease grants or refreshes a project lease. ok=false means another
// device currently holds it; lease still describes that holder for diagnostics.
func (s *Store) AcquireSyncLease(
	projectID, deviceID, deviceName string,
	ttl time.Duration,
	now time.Time,
) (SyncLease, bool, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return SyncLease{}, false, err
	}
	defer tx.Rollback()

	current, err := scanSyncLease(tx.QueryRow(`SELECT project_id, lease_id, device_id, device_name, expires_at, updated_at
		FROM sync_leases WHERE project_id = ?`, projectID))
	if err != nil && err != sql.ErrNoRows {
		return SyncLease{}, false, err
	}
	if err == nil && current.ExpiresAt.After(now) && current.DeviceID != deviceID {
		return current, false, nil
	}
	lease := SyncLease{
		ProjectID:  projectID,
		LeaseID:    newLeaseID(),
		DeviceID:   deviceID,
		DeviceName: deviceName,
		ExpiresAt:  now.Add(ttl),
		UpdatedAt:  now,
	}
	if _, err := tx.Exec(`INSERT INTO sync_leases
		(project_id, lease_id, device_id, device_name, expires_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(project_id) DO UPDATE SET
			lease_id=excluded.lease_id,
			device_id=excluded.device_id,
			device_name=excluded.device_name,
			expires_at=excluded.expires_at,
			updated_at=excluded.updated_at`,
		lease.ProjectID, lease.LeaseID, lease.DeviceID, lease.DeviceName,
		lease.ExpiresAt.Format(time.RFC3339Nano), lease.UpdatedAt.Format(time.RFC3339Nano)); err != nil {
		return SyncLease{}, false, err
	}
	if err := tx.Commit(); err != nil {
		return SyncLease{}, false, err
	}
	return lease, true, nil
}

func (s *Store) ValidateSyncLease(projectID, leaseID string, now time.Time) (SyncLease, bool) {
	lease, err := scanSyncLease(s.db.QueryRow(`SELECT project_id, lease_id, device_id, device_name, expires_at, updated_at
		FROM sync_leases WHERE project_id = ? AND lease_id = ?`, projectID, leaseID))
	if err != nil {
		return SyncLease{}, false
	}
	return lease, lease.ExpiresAt.After(now)
}

func (s *Store) ReleaseSyncLease(projectID, leaseID string) error {
	_, err := s.db.Exec(`DELETE FROM sync_leases WHERE project_id = ? AND lease_id = ?`, projectID, leaseID)
	return err
}

func scanSyncLease(row interface{ Scan(...any) error }) (SyncLease, error) {
	var lease SyncLease
	var expires, updated string
	if err := row.Scan(&lease.ProjectID, &lease.LeaseID, &lease.DeviceID, &lease.DeviceName, &expires, &updated); err != nil {
		return SyncLease{}, err
	}
	var err error
	if lease.ExpiresAt, err = time.Parse(time.RFC3339Nano, expires); err != nil {
		return SyncLease{}, err
	}
	if lease.UpdatedAt, err = time.Parse(time.RFC3339Nano, updated); err != nil {
		return SyncLease{}, err
	}
	return lease, nil
}

func newLeaseID() string {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(raw)
}
