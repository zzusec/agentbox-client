package server

import (
	"errors"
	"fmt"

	"agentbox/internal/config"
	"agentbox/internal/store"
	"agentbox/internal/workspace"
)

var errAccountAccess = jsonError("当前用户无权使用该账号，请联系管理员调整账号使用范围")

// Use the session owner's current role, never the role of an unrelated caller.
func (s *Server) canUseAccount(acct config.Account, user string) bool {
	u, _ := s.store.GetUser(user)
	return acct.CanUse(user, u.Role == store.RoleAdmin)
}

func (s *Server) sessionAccount(sess store.Session) (config.Account, error) {
	a, ok := s.cfg.Account(sess.AccountID)
	if !ok {
		return config.Account{}, errAccountGone
	}
	if !s.canUseAccount(a, sess.User) {
		return config.Account{}, errAccountAccess
	}
	return a, nil
}

// sessionAccounts returns every account bound to an instance, one per tool.
// An instance may carry a claude account and a codex account at once, so the
// container is seeded with both and each project picks one.
//
// The legacy single account is included while a row has not been split yet, so
// an unmigrated instance keeps working instead of refusing to start.
func (s *Server) sessionAccounts(sess store.Session) ([]workspace.AccountBinding, error) {
	var out []workspace.AccountBinding
	seen := map[string]bool{}
	for _, tool := range []string{config.AgentClaude, config.AgentCodex} {
		id := sess.AccountForTool(tool)
		if id == "" || seen[id] {
			continue
		}
		acct, ok := s.cfg.Account(id)
		if !ok {
			return nil, errAccountGone
		}
		if acct.Type != tool {
			return nil, fmt.Errorf("实例绑定的 %s 账号类型不匹配", tool)
		}
		if !s.canUseAccount(acct, sess.User) {
			return nil, errAccountAccess
		}
		seen[id] = true
		out = append(out, workspace.AccountBinding{Agent: tool, Account: acct})
	}
	if len(out) == 0 {
		return nil, errAccountGone
	}
	if _, err := s.instanceProxy(sess); err != nil && !errors.Is(err, errNoInstanceProxy) {
		return nil, err
	}
	return out, nil
}

// Config loading permits names not yet restored into SQLite. Administrative
// HTTP edits require existing users so a typo cannot silently grant future access.
func (s *Server) validateAccountAccess(a *config.AccountAccess) error {
	if err := a.Validate(); err != nil {
		return err
	}
	if a != nil {
		for _, name := range a.Users {
			if _, ok := s.store.GetUser(name); !ok {
				return fmt.Errorf("用户 %q 不存在", name)
			}
		}
	}
	return nil
}
