package syncclient

import (
	"io"
	"sync"
	"time"
)

// Phase names what a progress event is reporting on. They double as the
// machine-readable `phase` field of abox-sync's JSON output, so the macOS
// client can label the bar without parsing Chinese text.
const (
	PhaseUpload       = "upload"
	PhaseDownload     = "download"
	PhaseDeleteLocal  = "delete_local"
	PhaseDeleteRemote = "delete_remote"
	PhaseDone         = "done"
)

// Progress is one transfer tick for a single project.
//
// Percent prefers bytes over action counts: a plan is usually one huge file
// plus a hundred tiny ones, and counting actions would sit at 1% for the whole
// transfer and then jump to 100%. With no file bytes in the plan (pure
// directory or delete actions) it falls back to the action index.
type Progress struct {
	Project    string  `json:"project"`
	Phase      string  `json:"phase"`
	Path       string  `json:"path,omitempty"`
	Index      int     `json:"index"`
	Total      int     `json:"total"`
	Bytes      int64   `json:"bytes"`
	TotalBytes int64   `json:"total_bytes"`
	Percent    float64 `json:"percent"`
}

// Transfer is one finished file (or directory, or deletion). The macOS status
// bar shows these: what moved, which way, and how long it took.
type Transfer struct {
	Project    string `json:"project"`
	Phase      string `json:"phase"`
	Path       string `json:"path"`
	Bytes      int64  `json:"bytes"`
	DurationMS int64  `json:"duration_ms"`
}

// Status is the answer to "are both sides identical right now?", emitted after
// every sync pass whether or not anything moved. InSync is only true when the
// pass ended with the local tree, the server tree and the saved base all
// agreeing — a conflict or a transport error leaves it false.
type Status struct {
	Project    string   `json:"project"`
	InSync     bool     `json:"in_sync"`
	Applied    int      `json:"applied"`
	Conflicts  []string `json:"conflicts,omitempty"`
	Error      string   `json:"error,omitempty"`
	DurationMS int64    `json:"duration_ms"`
	At         string   `json:"at"`
}

// progressThrottle keeps a large file from emitting thousands of lines: ticks
// in between are dropped, but phase changes and the final tick always go out.
const progressThrottle = 120 * time.Millisecond

type reporter struct {
	emit    func(Progress)
	project string
	total   int
	totalB  int64

	mu     sync.Mutex
	index  int
	phase  string
	path   string
	bytes  int64
	lastAt time.Time
}

func newReporter(emit func(Progress), project string, plan Plan) *reporter {
	r := &reporter{emit: emit, project: project, total: len(plan.Actions)}
	for _, action := range plan.Actions {
		if action.Entry.Kind != "file" {
			continue
		}
		if action.Type == ActionUpload || action.Type == ActionDownload {
			r.totalB += action.Entry.Size
		}
	}
	return r
}

// begin marks the start of one action and always emits, so the label and the
// index advance even when the action moves no bytes at all.
func (r *reporter) begin(index int, phase, path string) {
	if r == nil || r.emit == nil {
		return
	}
	r.mu.Lock()
	r.index, r.phase, r.path = index, phase, path
	r.lastAt = time.Now()
	snapshot := r.snapshotLocked()
	r.mu.Unlock()
	r.emit(snapshot)
}

// advance adds transferred bytes, emitting at most one tick per throttle slot.
func (r *reporter) advance(n int64) {
	if r == nil || r.emit == nil || n <= 0 {
		return
	}
	r.mu.Lock()
	r.bytes += n
	if time.Since(r.lastAt) < progressThrottle {
		r.mu.Unlock()
		return
	}
	r.lastAt = time.Now()
	snapshot := r.snapshotLocked()
	r.mu.Unlock()
	r.emit(snapshot)
}

// finish reports the plan as complete. Percent is pinned to 100 rather than
// computed: skipped bytes (an unreadable file, a short download) would
// otherwise leave the bar parked at 97% forever.
func (r *reporter) finish() {
	if r == nil || r.emit == nil {
		return
	}
	r.mu.Lock()
	snapshot := r.snapshotLocked()
	r.mu.Unlock()
	snapshot.Phase = PhaseDone
	snapshot.Path = ""
	snapshot.Index = snapshot.Total
	snapshot.Percent = 100
	r.emit(snapshot)
}

func (r *reporter) snapshotLocked() Progress {
	p := Progress{
		Project:    r.project,
		Phase:      r.phase,
		Path:       r.path,
		Index:      r.index,
		Total:      r.total,
		Bytes:      r.bytes,
		TotalBytes: r.totalB,
	}
	switch {
	case r.totalB > 0:
		p.Percent = float64(r.bytes) / float64(r.totalB) * 100
	case r.total > 0:
		p.Percent = float64(r.index-1) / float64(r.total) * 100
	}
	if p.Percent > 100 {
		p.Percent = 100
	}
	if p.Percent < 0 {
		p.Percent = 0
	}
	return p
}

// countingReader reports bytes as they stream, so progress reflects what has
// actually crossed the wire instead of jumping a whole file at a time.
type countingReader struct {
	inner io.Reader
	count func(int64)
}

func (c *countingReader) Read(p []byte) (int, error) {
	n, err := c.inner.Read(p)
	if n > 0 {
		c.count(int64(n))
	}
	return n, err
}
