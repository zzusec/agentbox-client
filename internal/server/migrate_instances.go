package server

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"

	"agentbox/internal/config"
	"agentbox/internal/store"
	"agentbox/internal/workspace"
)

// migrateDryRun is set by AGENTBOX_MIGRATE_DRYRUN=1. It reports what the v11
// backfill would do without writing, so an operator can find instances that
// would be left without a proxy — and therefore refuse to start — before
// upgrading rather than after.
const migrateDryRunEnv = "AGENTBOX_MIGRATE_DRYRUN"

// migrateInstances brings pre-v11 rows up to the instance model: accounts split
// per tool, a proxy owned by the instance instead of inherited from an account,
// a per-tool default model, and absolute project paths.
//
// It cannot live in the migration transaction because it needs config.json
// (account types, the proxy pool) and the data directory (project paths), and
// the store only ever receives a database path. Every step is idempotent and
// only fills empty values, so running it on every boot is harmless; a second
// pass finds nothing left to do.
func (s *Server) migrateInstances() error {
	dryRun := os.Getenv(migrateDryRunEnv) != ""
	sessions := s.store.All()
	sort.Slice(sessions, func(i, j int) bool { return sessions[i].ID < sessions[j].ID })

	var withoutProxy, withoutAccount []string
	for _, sess := range sessions {
		next := sess
		changed := false

		// 1. Split the legacy single account into the per-tool columns.
		if next.ClaudeAccountID == "" && next.CodexAccountID == "" && next.AccountID != "" {
			if acct, ok := s.cfg.Account(next.AccountID); ok {
				switch acct.Type {
				case config.AgentClaude:
					next.ClaudeAccountID = next.AccountID
					changed = true
				case config.AgentCodex:
					next.CodexAccountID = next.AccountID
					changed = true
				}
			}
		}

		// 2. Give the instance its own proxy. Prefer whatever the bound account
		// already used, so an existing instance keeps its exit IP.
		if next.ProxyID == "" {
			if id, ok := s.inheritedProxy(next); ok {
				next.ProxyID = id
				changed = true
			}
		}
		// 3. A single default model cannot serve both tools, so seed each
		// column from the snapshot the instance was created with.
		if next.DefaultModel != "" {
			if next.DefaultModelClaude == "" && next.Agent == config.AgentClaude {
				next.DefaultModelClaude = next.DefaultModel
				changed = true
			}
			if next.DefaultModelCodex == "" && next.Agent == config.AgentCodex {
				next.DefaultModelCodex = next.DefaultModel
				changed = true
			}
		}

		if !next.HasTool(config.AgentClaude) && !next.HasTool(config.AgentCodex) {
			withoutAccount = append(withoutAccount, fmt.Sprintf("%s (%s)", next.ID, next.Name))
		}
		if next.ProxyID == "" {
			withoutProxy = append(withoutProxy, fmt.Sprintf("%s (%s)", next.ID, next.Name))
		}

		// 4. Project paths. Independent of the session update because it
		// touches a different table.
		dir := filepath.Join(workspace.SessionDir(s.cfg.DataDir, next), "workspace")
		if !dryRun {
			if err := s.store.BackfillSyncProjectPaths(next.ID, dir); err != nil {
				return fmt.Errorf("instance %s: 回填项目路径: %w", next.ID, err)
			}
		}

		if changed && !dryRun {
			if _, err := s.store.Update(next.ID, func(x *store.Session) {
				x.ClaudeAccountID = next.ClaudeAccountID
				x.CodexAccountID = next.CodexAccountID
				x.ProxyID = next.ProxyID
				x.DefaultModelClaude = next.DefaultModelClaude
				x.DefaultModelCodex = next.DefaultModelCodex
			}); err != nil {
				return fmt.Errorf("instance %s: %w", next.ID, err)
			}
		}
	}

	reportMigration(dryRun, withoutAccount, withoutProxy)
	return nil
}

// inheritedProxy returns the proxy any of the instance's accounts already used,
// so an existing instance keeps egressing from the same exit IP.
func (s *Server) inheritedProxy(sess store.Session) (string, bool) {
	for _, id := range []string{sess.ClaudeAccountID, sess.CodexAccountID, sess.AccountID} {
		if id == "" {
			continue
		}
		acct, ok := s.cfg.Account(id)
		if !ok || acct.ProxyID == "" {
			continue
		}
		if p, ok := s.cfg.Proxy(acct.ProxyID); ok && !p.Disabled {
			return acct.ProxyID, true
		}
	}
	return "", false
}

func reportMigration(dryRun bool, withoutAccount, withoutProxy []string) {
	prefix := "v11 回填"
	if dryRun {
		prefix = "v11 回填（dry-run，未写入）"
	}
	if len(withoutAccount) == 0 && len(withoutProxy) == 0 {
		return
	}
	if len(withoutAccount) > 0 {
		log.Printf("%s：%d 个实例没有可用账号：%v", prefix, len(withoutAccount), withoutAccount)
	}
	if len(withoutProxy) > 0 {
		log.Printf("%s：%d 个实例没有可用代理，启动会被拒绝：%v", prefix, len(withoutProxy), withoutProxy)
	}
}
