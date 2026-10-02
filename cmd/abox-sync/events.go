package main

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"os"
	"sync"
	"time"

	"agentbox/internal/syncclient"
)

const (
	// textProgressEvery throttles the human progress line. The engine ticks
	// every ~120ms on a large transfer; a log line that often is a wall.
	textProgressEvery = 500 * time.Millisecond
	// statusHeartbeat re-announces an unchanged "in sync" verdict so the
	// client can show when the two sides were last confirmed identical.
	// Passes run every second; reporting each one would flood the pipe.
	statusHeartbeat = 10 * time.Second
)

// reporter turns engine callbacks into output. With events on, each one is a
// JSON line on stdout for the Mac client to decode; the human log (stderr)
// keeps its own lines either way, because the client tees it into sync.log.
type reporter struct {
	events bool

	mu        sync.Mutex
	out       io.Writer
	lastText  time.Time
	lastPhase string
	statuses  map[string]statusMemo
}

type statusMemo struct {
	inSync bool
	err    string
	at     time.Time
}

func newReporter(events bool) *reporter {
	return &reporter{events: events, out: os.Stdout, statuses: map[string]statusMemo{}}
}

type progressEvent struct {
	Type string `json:"type"`
	syncclient.Progress
}

type transferEvent struct {
	Type string `json:"type"`
	syncclient.Transfer
}

type statusEvent struct {
	Type string `json:"type"`
	syncclient.Status
}

func (r *reporter) write(value any) {
	raw, err := json.Marshal(value)
	if err != nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	_, _ = r.out.Write(append(raw, '\n'))
}

func (r *reporter) progress(p syncclient.Progress) {
	if r.events {
		// The event carries everything; a parallel text line would drive the
		// client's progress bar a second time and make it flicker.
		r.write(progressEvent{Type: "progress", Progress: p})
		return
	}
	// The "name: done/total (pct%)" line predates events and is what a
	// one-shot forced pass is still read by, so keep it — throttled, but
	// never dropping a phase change or the final tick.
	r.mu.Lock()
	due := p.Phase == syncclient.PhaseDone || p.Phase != r.lastPhase ||
		time.Since(r.lastText) >= textProgressEvery
	if due {
		r.lastText, r.lastPhase = time.Now(), p.Phase
	}
	r.mu.Unlock()
	if due && p.Total > 0 {
		log.Printf("%s: %d/%d (%.0f%%)", p.Project, p.Index, p.Total, p.Percent)
	}
}

func (r *reporter) transfer(t syncclient.Transfer) {
	if r.events {
		r.write(transferEvent{Type: "transfer", Transfer: t})
	}
	log.Printf("%s: %s %s（%d 字节，%dms）", t.Project, phaseLabel(t.Phase), t.Path, t.Bytes, t.DurationMS)
}

// status reports the verdict of one pass. Changes, applied work and errors
// always go out; an unchanged verdict only on the heartbeat.
func (r *reporter) status(project syncclient.Project, result syncclient.SyncResult, err error) {
	if !r.events {
		return
	}
	st := syncclient.Status{
		Project:    project.Name,
		InSync:     err == nil && result.InSync,
		Applied:    result.Actions,
		Conflicts:  result.Conflicts,
		DurationMS: result.Duration.Milliseconds(),
		At:         time.Now().Format(time.RFC3339),
	}
	if err != nil {
		st.Error = err.Error()
		var conflicts *syncclient.ConflictError
		if errors.As(err, &conflicts) {
			st.Conflicts = conflicts.Paths
		}
	}
	r.mu.Lock()
	previous, seen := r.statuses[project.ID]
	due := !seen || st.Applied != 0 || st.InSync != previous.inSync ||
		st.Error != previous.err || time.Since(previous.at) >= statusHeartbeat
	if due {
		r.statuses[project.ID] = statusMemo{inSync: st.InSync, err: st.Error, at: time.Now()}
	}
	r.mu.Unlock()
	if due {
		r.write(statusEvent{Type: "status", Status: st})
	}
}

func phaseLabel(phase string) string {
	switch phase {
	case syncclient.PhaseUpload:
		return "上传"
	case syncclient.PhaseDownload:
		return "下载"
	case syncclient.PhaseDeleteLocal:
		return "移入本地回收站"
	case syncclient.PhaseDeleteRemote:
		return "删除服务器文件"
	default:
		return phase
	}
}
