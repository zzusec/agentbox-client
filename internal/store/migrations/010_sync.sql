CREATE TABLE IF NOT EXISTS sync_projects (
	id         TEXT PRIMARY KEY,
	session_id TEXT NOT NULL,
	name       TEXT NOT NULL,
	created_at TEXT NOT NULL,
	updated_at TEXT NOT NULL,
	UNIQUE(session_id, name)
);
CREATE INDEX IF NOT EXISTS idx_sync_projects_session ON sync_projects(session_id);

CREATE TABLE IF NOT EXISTS sync_leases (
	project_id  TEXT PRIMARY KEY,
	lease_id    TEXT NOT NULL,
	device_id   TEXT NOT NULL,
	device_name TEXT NOT NULL DEFAULT '',
	expires_at  TEXT NOT NULL,
	updated_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_sync_leases_expiry ON sync_leases(expires_at);
