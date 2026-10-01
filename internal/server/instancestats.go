package server

import (
	"context"
	"net/http"
	"sort"
	"time"

	"agentbox/internal/store"
)

// instanceStat is one instance's resource footprint, as shown on the instance
// cards. It is deliberately narrower than the admin monitor: it carries only
// what belongs to the instance, never another user's data.
type instanceStat struct {
	SessionID string `json:"session_id"`
	Name      string `json:"name"`
	Agent     string `json:"agent"`
	Running   bool   `json:"running"`

	ClaudeAccountID string `json:"claude_account_id,omitempty"`
	CodexAccountID  string `json:"codex_account_id,omitempty"`
	ProxyID         string `json:"proxy_id,omitempty"`
	// ProxyBound is false when the instance has no usable exit. The card marks
	// those instances rather than letting the user discover it on start.
	ProxyBound bool `json:"proxy_bound"`

	CPUPercent float64 `json:"cpu_percent"` // 单核百分比，可 >100；window_ms=0 时无意义
	SampleOK   bool    `json:"sample_ok"`
	CPUReady   bool    `json:"cpu_ready"`
	MemUsage   uint64  `json:"mem_usage"`
	MemLimit   uint64  `json:"mem_limit"`
	Pids       uint64  `json:"pids"`
	// DiskBytes 是工作区 + home 的占用，来自宿主目录遍历；DiskStale 表示这一帧
	// 还没算出来，前端应显示「统计中」。
	DiskBytes uint64 `json:"disk_bytes"`
	DiskStale bool   `json:"disk_stale"`
	// 网络是累计字节，不是速率：速率由前端用相邻两帧自己求差，服务端不替它决定
	// 窗口。
	NetRxBytes uint64 `json:"net_rx_bytes"`
	NetTxBytes uint64 `json:"net_tx_bytes"`

	StartedAt int64 `json:"started_at"` // 容器本次启动时间(ms)，0=未运行/未知
}

type instanceStatsView struct {
	Now      int64          `json:"now"`       // 服务端当前时间(ms)
	WindowMS int64          `json:"window_ms"` // CPU 采样窗口；0 表示首帧，前端显示「测量中」
	Items    []instanceStat `json:"items"`
}

// handleInstanceStats serves one instance. withSession has already checked that
// the caller owns it, so this only has to produce the numbers.
func (s *Server) handleInstanceStats(w http.ResponseWriter, r *http.Request, sess store.Session) {
	writeJSON(w, http.StatusOK, s.instanceStats(r.Context(), monScopeForInstance(sess.ID), []store.Session{sess}))
}

// handleInstanceStatsList serves every instance of the calling user. It reads
// the session list itself rather than taking an owner parameter, so there is no
// path to someone else's instances.
func (s *Server) handleInstanceStatsList(w http.ResponseWriter, r *http.Request) {
	user := reqUser(r).Name
	writeJSON(w, http.StatusOK, s.instanceStats(r.Context(), monScopeForUser(user), s.store.List(user)))
}

// instanceStats samples the given instances once. CPU comes from diffing this
// frame against the previous one for the same scope, so the first call after a
// gap reports window_ms=0 and the client shows "measuring".
func (s *Server) instanceStats(ctx context.Context, scope string, sessions []store.Session) instanceStatsView {
	type meta struct {
		sess      store.Session
		running   bool
		startedAt time.Time
	}
	metas := make([]meta, 0, len(sessions))
	var runningIDs []string
	var diskKeys []string
	for _, sess := range sessions {
		m := meta{sess: sess}
		if sess.ContainerID != "" {
			m.running, m.startedAt = s.dock.ContainerState(ctx, sess.ContainerID)
		}
		if m.running {
			runningIDs = append(runningIDs, sess.ContainerID)
		}
		diskKeys = append(diskKeys, s.instanceDiskKey(sess))
		metas = append(metas, m)
	}

	cur := monSample{at: time.Now()}
	if len(runningIDs) > 0 {
		cur.stats = s.dock.StatSnapshots(ctx, runningIDs)
	}
	prev, window := s.mon.rotate(scope, cur)
	rate := window > 0

	view := instanceStatsView{
		Now:      cur.at.UnixMilli(),
		WindowMS: window.Milliseconds(),
		Items:    []instanceStat{},
	}
	for _, m := range metas {
		_, proxyErr := s.instanceProxy(m.sess)
		diskBytes, diskFresh := s.diskUsage().peek(s.instanceDiskKey(m.sess))
		row := instanceStat{
			SessionID:       m.sess.ID,
			Name:            m.sess.Name,
			Agent:           m.sess.Agent,
			Running:         m.running,
			ClaudeAccountID: m.sess.ClaudeAccountID,
			CodexAccountID:  m.sess.CodexAccountID,
			ProxyID:         m.sess.ProxyID,
			ProxyBound:      proxyErr == nil,
			DiskBytes:       diskBytes,
			DiskStale:       !diskFresh,
		}
		if m.running {
			if !m.startedAt.IsZero() {
				row.StartedAt = m.startedAt.UnixMilli()
			}
			if b := cur.stats[m.sess.ContainerID]; b.OK {
				row.SampleOK = true
				row.MemUsage = b.MemUsage
				row.MemLimit = b.MemLimit
				row.Pids = b.Pids
				row.NetRxBytes = b.NetRx
				row.NetTxBytes = b.NetTx
				if rate {
					if a, ok := prev.stats[m.sess.ContainerID]; ok && a.OK && b.Read.After(a.Read) && b.CPUTotal >= a.CPUTotal {
						row.CPUReady = true
						row.CPUPercent = containerCPUPercent(a, b)
					}
				}
			}
		}
		view.Items = append(view.Items, row)
	}
	// 磁盘遍历放到请求之后：卡片先出 CPU/内存，磁盘下一轮补上。
	s.diskUsage().warm(diskKeys)

	sort.SliceStable(view.Items, func(i, j int) bool {
		a, b := view.Items[i], view.Items[j]
		if a.Running != b.Running {
			return a.Running
		}
		return a.Name < b.Name
	})
	return view
}
