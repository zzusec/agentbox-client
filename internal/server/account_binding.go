package server

import (
	"fmt"
	"net/http"
	"sync"

	"agentbox/internal/store"
)

// instanceBindMu serialises "is this account free?" with the write that takes
// it, so two instances created at the same moment cannot both claim one
// account.
var instanceBindMu sync.Mutex

// accountBoundInstance reports the instance, other than except, that an
// account is bound to. One account belongs to one instance: two containers
// driving the same subscription race each other's OAuth refresh tokens and
// share one rate limit, and the user asked for that to be impossible.
// Instances of every user count — the rule is about the account, not the
// person.
func (s *Server) accountBoundInstance(accountID, except string) (store.Session, bool) {
	if accountID == "" {
		return store.Session{}, false
	}
	for _, sess := range s.store.All() {
		if sess.ID == except {
			continue
		}
		for _, id := range instanceAccountRefs(sess) {
			if id == accountID {
				return sess, true
			}
		}
	}
	return store.Session{}, false
}

// requireAccountsFree writes a 409 and returns false when any of ids is
// already bound to another instance. The other instance is named only to its
// owner or an admin; anyone else learns that the account is taken, not whose
// instance took it.
func (s *Server) requireAccountsFree(w http.ResponseWriter, r *http.Request, except string, ids ...string) bool {
	user := reqUser(r)
	for _, id := range ids {
		other, taken := s.accountBoundInstance(id, except)
		if !taken {
			continue
		}
		label := id
		if acct, ok := s.cfg.Account(id); ok && acct.Label != "" {
			label = acct.Label
		}
		where := "另一个实例"
		if user.Role == store.RoleAdmin || other.User == user.Name {
			where = fmt.Sprintf("实例「%s」", other.Name)
		}
		writeErr(w, http.StatusConflict, fmt.Sprintf("账号 %s 已绑定到%s；一个账号只能绑定一个实例", label, where))
		return false
	}
	return true
}

// accountBindings maps each bound account to the instance holding it, for the
// account list.
func (s *Server) accountBindings() map[string]store.Session {
	out := map[string]store.Session{}
	for _, sess := range s.store.All() {
		for _, id := range instanceAccountRefs(sess) {
			if _, seen := out[id]; !seen {
				out[id] = sess
			}
		}
	}
	return out
}
