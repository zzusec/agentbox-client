package server

import (
	"errors"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

// 实例磁盘占用。Docker 不提供容器磁盘用量（写入落在宿主 bind mount 上，容器
// 自己的可写层几乎是空的），只能在宿主侧遍历目录。一个活跃工作区可能有几十万个
// 文件，walk 一次要几十毫秒到几秒，所以：
//
//   - 结果按目录缓存，TTL 内直接复用；
//   - 只有「过期且当前没人在算」的目录才会被放进后台队列；
//   - 请求路径上永远不阻塞，拿不到就给「统计中」，下一帧自然有值。
const (
	diskUsageTTL = 60 * time.Second
	// 同时最多扫这么多个目录：磁盘是共享资源，把并发压住比早点拿到数字重要。
	diskUsageConcurrency = 4
	// 单个目录的遍历上限。超过就放弃这一轮并记日志，宁可显示旧值也不让一次
	// 误操作的巨型目录把服务拖住。
	diskUsageMaxEntries = 200000
)

type diskEntry struct {
	bytes   uint64
	at      time.Time
	checked time.Time
	valid   bool
	busy    bool
}

type diskUsageCache struct {
	mu      sync.Mutex
	entries map[string]diskEntry
	sem     chan struct{}
}

func newDiskUsageCache() *diskUsageCache {
	return &diskUsageCache{entries: map[string]diskEntry{}, sem: make(chan struct{}, diskUsageConcurrency)}
}

// peek returns the cached size of dir and whether it is still fresh. A miss
// returns (0, false): callers must not wait for the walk.
func (c *diskUsageCache) peek(dir string) (uint64, bool) {
	if dir == "" {
		return 0, false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.entries[dir]
	if !ok {
		return 0, false
	}
	return e.bytes, e.valid && time.Since(e.at) < diskUsageTTL
}

// warm schedules a background walk for every instance directory that is stale
// and not already being walked. Duplicate requests coalesce, so polling every
// few seconds cannot pile up work.
func (c *diskUsageCache) warm(sessionDirs []string) {
	for _, dir := range sessionDirs {
		if dir == "" {
			continue
		}
		c.mu.Lock()
		e, ok := c.entries[dir]
		stale := !ok || time.Since(e.checked) >= diskUsageTTL
		if !stale || e.busy {
			c.mu.Unlock()
			continue
		}
		select {
		case c.sem <- struct{}{}:
		default:
			c.mu.Unlock()
			return
		}
		e.busy = true
		c.entries[dir] = e
		c.mu.Unlock()

		go func(dir string) {
			defer func() { <-c.sem }()
			var total uint64
			complete := true
			for _, target := range instanceDiskTargets(dir) {
				size, ok := dirSize(target)
				total += size
				if !ok {
					complete = false
				}
			}
			c.mu.Lock()
			e := c.entries[dir]
			e.busy = false
			if complete {
				e.bytes = total
				e.at = time.Now()
				e.valid = true
			}
			// 不完整就保留旧值，只推后重试时间：宁可显示上一轮的旧数字，也不
			// 把一个已知偏小的值当成准确值发布出去。
			e.checked = time.Now()
			c.entries[dir] = e
			c.mu.Unlock()
			if !complete {
				log.Printf("disk usage %s: 遍历不完整（上限 %d 条或读取失败），保留上一次统计", dir, diskUsageMaxEntries)
			}
		}(dir)
	}
}

// instanceDiskTargets lists the directories whose size makes up one instance's
// disk footprint: the project workspace plus the home directory, which holds
// the CLI transcripts and is often the larger of the two.
func instanceDiskTargets(sessionDir string) []string {
	if sessionDir == "" {
		return nil
	}
	return []string{
		filepath.Join(sessionDir, "workspace"),
		filepath.Join(sessionDir, "home"),
	}
}

// dirSize sums regular file sizes under root. Symlinks are not followed: the
// workspace is user-controlled and a link out of it must not turn one stat
// into an unbounded walk of the host filesystem.
//
// ok=false means the walk was incomplete (entry budget or a hard error), in
// which case the caller keeps the previous value rather than publishing a
// number it knows is short.
func dirSize(root string) (uint64, bool) {
	info, err := os.Lstat(root)
	if errors.Is(err, fs.ErrNotExist) {
		return 0, true
	}
	if err != nil || !info.IsDir() || info.Mode()&fs.ModeSymlink != 0 {
		return 0, false
	}
	directory, err := os.OpenRoot(root)
	if err != nil {
		return 0, false
	}
	defer directory.Close()
	base, err := directory.Stat(".")
	if err != nil {
		return 0, false
	}
	device := base.Sys().(*syscall.Stat_t).Dev
	var total uint64
	var seen int
	err = fs.WalkDir(directory.FS(), ".", func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		seen++
		if seen > diskUsageMaxEntries {
			return errors.New("disk usage entry budget exceeded")
		}
		if entry.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if info.Sys().(*syscall.Stat_t).Dev != device {
			if entry.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if info.Mode().IsRegular() {
			total += uint64(info.Size())
		}
		return nil
	})
	// 目录还不存在是正常状态（实例刚建、home 还没播种），算 0 而不是算失败，
	// 否则这类实例的磁盘永远停在「统计中」。
	if err != nil {
		return total, false
	}
	return total, true
}
