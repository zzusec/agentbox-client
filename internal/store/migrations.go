package store

import (
	"database/sql"
	_ "embed"
	"fmt"
	"time"
)

// SchemaVersion changes only with a committed, ordered migration. Versions
// predating this framework use user_version=0, including partially upgraded DBs.
const SchemaVersion = 12

//go:embed migrations/001_baseline.sql
var baselineSQL string

//go:embed migrations/002_usage_price.sql
var usagePriceSQL string

//go:embed migrations/004_git_profile.sql
var gitProfileSQL string

//go:embed migrations/005_git_connections.sql
var gitConnectionsSQL string

//go:embed migrations/009_usage_messages.sql
var usageMessagesSQL string

//go:embed migrations/010_sync.sql
var syncSQL string

type migration struct {
	version int
	apply   func(*sql.Tx) error
}

func migrations() []migration {
	return []migration{
		{1, baselineMigration},
		{2, func(tx *sql.Tx) error { _, err := tx.Exec(usagePriceSQL); return err }},
		{3, normalizeUsageTimestamps},
		{4, func(tx *sql.Tx) error { _, err := tx.Exec(gitProfileSQL); return err }},
		{5, func(tx *sql.Tx) error { _, err := tx.Exec(gitConnectionsSQL); return err }},
		{6, func(tx *sql.Tx) error {
			var found int
			if err := tx.QueryRow("SELECT COUNT(*) FROM pragma_table_info('git_operations') WHERE name='finished_at'").Scan(&found); err != nil {
				return err
			}
			if found == 0 {
				if _, err := tx.Exec("ALTER TABLE git_operations ADD COLUMN finished_at TEXT NOT NULL DEFAULT ''"); err != nil {
					return err
				}
			}
			return nil
		}},
		{7, func(tx *sql.Tx) error {
			var found int
			if err := tx.QueryRow("SELECT COUNT(*) FROM pragma_table_info('git_connections') WHERE name='network'").Scan(&found); err != nil {
				return err
			}
			if found == 0 {
				_, err := tx.Exec("ALTER TABLE git_connections ADD COLUMN network TEXT NOT NULL DEFAULT '{}'")
				return err
			}
			return nil
		}},
		{8, func(tx *sql.Tx) error {
			_, err := tx.Exec(`CREATE TABLE IF NOT EXISTS git_connection_shares(connection_id TEXT NOT NULL,user TEXT NOT NULL,can_write INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(connection_id,user)); CREATE INDEX IF NOT EXISTS idx_git_shares_user ON git_connection_shares(user);`)
			return err
		}},
		{9, func(tx *sql.Tx) error { _, err := tx.Exec(usageMessagesSQL); return err }},
		{10, func(tx *sql.Tx) error { _, err := tx.Exec(syncSQL); return err }},
		{11, instanceMigrationV11},
		{12, syncProjectCommandMigration},
	}
}

// instanceMigrationV11 turns a workspace into a multi-tool instance: it can
// hold a claude account and a codex account at the same time, it owns its
// outbound proxy instead of inheriting one from the account, and its projects
// record both the tool they are developed with and the absolute path they live
// at (which is the same path inside the container).
//
// Every column is additive with a benign default, so the rollback path is
// "restore the backup" rather than "undo a destructive rewrite". Rows are
// backfilled at the server layer, which is the only place with access to both
// the config (account types, proxies) and the data directory.
// syncProjectCommandMigration lets each project carry its own launch command.
// Empty means "the default command for the project's agent", so every row
// that predates this version keeps launching what it launched before the
// defaults changed only if the defaults say so.
func syncProjectCommandMigration(tx *sql.Tx) error {
	var found int
	if err := tx.QueryRow(
		"SELECT COUNT(*) FROM pragma_table_info('sync_projects') WHERE name='command'",
	).Scan(&found); err != nil {
		return err
	}
	if found != 0 {
		return nil
	}
	_, err := tx.Exec("ALTER TABLE sync_projects ADD COLUMN command TEXT NOT NULL DEFAULT ''")
	return err
}

func instanceMigrationV11(tx *sql.Tx) error {
	for _, c := range []struct{ table, name, definition string }{
		{"sessions", "claude_account_id", "TEXT NOT NULL DEFAULT ''"},
		{"sessions", "codex_account_id", "TEXT NOT NULL DEFAULT ''"},
		{"sessions", "proxy_id", "TEXT NOT NULL DEFAULT ''"},
		{"sessions", "default_model_claude", "TEXT NOT NULL DEFAULT ''"},
		{"sessions", "default_model_codex", "TEXT NOT NULL DEFAULT ''"},
		{"sync_projects", "agent", "TEXT NOT NULL DEFAULT ''"},
		{"sync_projects", "path", "TEXT NOT NULL DEFAULT ''"},
	} {
		var found int
		if err := tx.QueryRow("SELECT COUNT(*) FROM pragma_table_info(?) WHERE name=?", c.table, c.name).Scan(&found); err != nil {
			return err
		}
		if found == 0 {
			if _, err := tx.Exec("ALTER TABLE " + c.table + " ADD COLUMN " + c.name + " " + c.definition); err != nil {
				return err
			}
		}
	}
	_, err := tx.Exec(`CREATE INDEX IF NOT EXISTS idx_sessions_proxy ON sessions(proxy_id);
CREATE INDEX IF NOT EXISTS idx_sync_projects_agent ON sync_projects(agent);`)
	return err
}
func migrate(db *sql.DB) error { return runMigrations(db, migrations()) }
func runMigrations(db *sql.DB, steps []migration) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var version int
	if err := tx.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return err
	}
	latest := steps[len(steps)-1].version
	if version < 0 || version > latest {
		return fmt.Errorf("unsupported database schema version %d (maximum %d); use a compatible binary or restore a compatible backup", version, latest)
	}
	for i, step := range steps {
		if step.version != i+1 {
			return fmt.Errorf("non-contiguous migration version %d", step.version)
		}
		if step.version <= version {
			continue
		}
		if err := step.apply(tx); err != nil {
			return fmt.Errorf("migration %d: %w", step.version, err)
		}
		if _, err := tx.Exec(fmt.Sprintf("PRAGMA user_version=%d", step.version)); err != nil {
			return err
		}
	}
	return tx.Commit()
}
func baselineMigration(tx *sql.Tx) error {
	if _, err := tx.Exec(baselineSQL); err != nil {
		return err
	}
	// Bootstrap pre-versioned installations, including those stopped halfway
	// through an old additive migration. Inspect schema; never parse error text.
	for _, c := range []struct{ table, name, definition string }{
		{"sessions", "default_model", "TEXT NOT NULL DEFAULT ''"},
		{"sessions", "stop_reason", "TEXT NOT NULL DEFAULT ''"},
		{"usage_events", "kind", "TEXT NOT NULL DEFAULT 'chat'"},
		{"usage_events", "ttft_ms", "INTEGER NOT NULL DEFAULT 0"},
		{"usage_events", "provider", "TEXT NOT NULL DEFAULT ''"},
		{"usage_events", "wall_ms", "INTEGER NOT NULL DEFAULT 0"},
		{"usage_events", "req_id", "TEXT NOT NULL DEFAULT ''"},
	} {
		var found int
		if err := tx.QueryRow("SELECT count(*) FROM pragma_table_info(?) WHERE name=?", c.table, c.name).Scan(&found); err != nil {
			return err
		}
		if found == 0 {
			if _, err := tx.Exec("ALTER TABLE " + c.table + " ADD COLUMN " + c.name + " " + c.definition); err != nil {
				return err
			}
		}
	}
	_, err := tx.Exec(`CREATE UNIQUE INDEX IF NOT EXISTS idx_usage_req ON usage_events(req_id) WHERE req_id != '';
 CREATE INDEX IF NOT EXISTS idx_usage_ts ON usage_events(ts);`)
	return err
}

func normalizeUsageTimestamps(tx *sql.Tx) error {
	var lastID int64
	for {
		rows, err := tx.Query("SELECT id, ts FROM usage_events WHERE id > ? ORDER BY id LIMIT 1000", lastID)
		if err != nil {
			return err
		}
		type entry struct {
			id int64
			ts string
		}
		var batch []entry
		for rows.Next() {
			var e entry
			if err := rows.Scan(&e.id, &e.ts); err != nil {
				rows.Close()
				return err
			}
			batch = append(batch, e)
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return err
		}
		if len(batch) == 0 {
			return nil
		}
		for _, e := range batch {
			ts, err := time.Parse(time.RFC3339Nano, e.ts)
			if err != nil {
				return fmt.Errorf("usage event %d timestamp %q: %w", e.id, e.ts, err)
			}
			if _, err := tx.Exec("UPDATE usage_events SET ts = ? WHERE id = ?", usageTimestamp(ts), e.id); err != nil {
				return err
			}
		}
		lastID = batch[len(batch)-1].id
	}
}
