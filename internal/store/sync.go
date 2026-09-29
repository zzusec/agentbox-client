package store

import (
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"sort"
	"time"
)

type SyncProject struct {
	ID        string    `json:"id"`
	SessionID string    `json:"session_id"`
	Name      string    `json:"name"`
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
func (s *Store) ReconcileSyncProjects(sessionID string, names []string) ([]SyncProject, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	current := make(map[string]bool, len(names))
	for _, name := range names {
		current[name] = true
	}
	rows, err := tx.Query(`SELECT id, session_id, name, created_at, updated_at
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
			CreatedAt: now, UpdatedAt: now,
		}
		if _, err := tx.Exec(`INSERT INTO sync_projects
			(id, session_id, name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)`,
			p.ID, p.SessionID, p.Name, p.CreatedAt.Format(time.RFC3339Nano), p.UpdatedAt.Format(time.RFC3339Nano)); err != nil {
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

func (s *Store) SyncProject(id string) (SyncProject, bool) {
	p, err := scanSyncProject(s.db.QueryRow(`SELECT id, session_id, name, created_at, updated_at
		FROM sync_projects WHERE id = ?`, id))
	return p, err == nil
}

func (s *Store) RenameSyncProject(id, name string) (SyncProject, error) {
	now := time.Now()
	if _, err := s.db.Exec(`UPDATE sync_projects SET name = ?, updated_at = ? WHERE id = ?`,
		name, now.Format(time.RFC3339Nano), id); err != nil {
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

func scanSyncProject(row interface{ Scan(...any) error }) (SyncProject, error) {
	var p SyncProject
	var created, updated string
	if err := row.Scan(&p.ID, &p.SessionID, &p.Name, &created, &updated); err != nil {
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
