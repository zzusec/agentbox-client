# agentbox-client for macOS

agentbox-client is a native macOS terminal for agentbox workspaces. It uses
SwiftTerm for terminal emulation and a Go `abox-sync` sidecar for project
synchronization.

## Build

Requirements:

- macOS 14 or newer on Apple Silicon
- Xcode Command Line Tools
- Go 1.26 or newer
- Swift 5.9 or newer

```bash
cd macos
./scripts/build-app.sh
open "dist/agentbox-client.app"
```

The build vendors SwiftTerm 1.5.0 under `third_party/swiftterm`, so building
does not fetch GitHub dependencies.

## First connection

1. Sign in to agentbox in a browser.
2. Open the user menu and choose `连接 Mac 终端`.
3. Paste the copied pairing code into agentbox-client.
4. Select a workspace in the left sidebar.
5. Choose a local project root and select the initial side for projects that
   already exist both locally and remotely.
6. Click a project to attach to its Claude session.

The local root maps directly to the remote `/workspace`: remote project
`/workspace/demo` maps to `<local root>/demo` by default. Right-click a project
(or use the new-project sheet) to point it at its own directory instead, and to
choose its sync mode.

## Per-project sync settings

Both the new-project sheet and a project's right-click menu carry the same three
settings:

- **项目名称 / name** — creating uses the name field; right-click offers
  `修改项目名称…`, which renames the server directory and the classic local
  folder together.
- **本地工作空间 / local workspace** — `修改本地工作空间…` points one project at
  any local directory. Overrides are keyed by project ID, so renaming a project
  keeps them. Picking the classic `<local root>/<name>` again clears the
  override.
- **同步方式 / sync mode** — `修改同步方式` picks which side wins when the
  project has to build a **fresh baseline**: 跟随工作空间, 以服务器为准 or
  以本地为准. This is not a live switch — routine syncs keep three-way merging
  and pause on real conflicts. The two real modes also carry a ⟳ that runs a
  full overwrite **right now**: the watcher stops, one `abox-sync
  -force-policy` pass overwrites the other side, and the watcher resumes. It
  confirms first, because 以服务器为准 deletes local files the server lacks
  (and 以本地为准 deletes server files the local copy lacks), and it records
  the mode it just applied.

Changing a project's directory discards that project's baseline on purpose. The
engine records the directory each baseline describes and ignores a baseline
whose directory no longer matches; reusing the old one would read as "every file
was deleted locally" and wipe the server copy. The next sync therefore
bootstraps from the chosen sync mode.

## Terminal settings

The palette toolbar button opens the terminal settings sheet:

- Color schemes: seven presets plus a custom scheme. The default is `Clear Dark`,
  taken verbatim from this Mac's Apple Terminal profile so the app matches the
  terminal you already work in (that profile is translucent, so the stored
  background `#191D27` is a touch darker than the composited screenshot). The
  custom card seeds from the current preset and exposes
  background/foreground/cursor color wells and hex fields for all 16 ANSI slots;
  every change applies to open terminals live.
- Font family and size: the family picker lists monospaced fonts installed on
  this machine (Monaco by default); CJK glyphs fall back to PingFang and friends
  regardless of the family.
- Mouse reporting has three modes: off (default; drag selects and copies),
  on (mouse events reach TUI apps like vim/tmux), and smart (reports like on,
  but holding ⇧ while dragging selects locally).

## Sync status bar

The strip along the bottom of the window is where sync reports itself. It shows
the engine's latest line and spins while a pass is in flight — a line ending in
`done/total` is progress, anything else is a result. Sync needs a local
directory; without one the bar says so, and picking ⟳ on a sync mode offers to
choose one instead of quietly doing nothing.

Every line also lands in `~/Library/Logs/agentbox-client/sync.log` (rotated at
2 MB). The status bar only keeps the last line, so the log is the only way to
answer "what did sync just do to that file?" afterwards. `打开同步日志` in the
project menu reveals it.

To ask what a pass *would* do without touching anything:

```bash
abox-sync -config ~/Library/Application\ Support/agentbox-client/sync-<id>.json -dry-run
```

## Development

```bash
swift build
../macos/scripts/build-app.sh
```

The sync process polls once a second (`interval_seconds: 1` in the sync
config). The server owns project IDs and sync leases; each project has one
writable device at a time, while other devices continue to receive server
changes.

## Updates

agentbox-client checks the latest GitHub release on launch and every four hours.
When `自动检查并准备更新` is enabled, it downloads `agentbox-client-macos-arm64.zip`,
verifies the release SHA-256 digest, verifies the `.app` code signature and only
then offers to restart into the new version. `检查更新…` in the application menu
runs the same flow immediately.

The release repository is read from `AgentboxUpdateRepository` in `Info.plist`
and currently points to `zzusec/agentbox-client`.

Create a release artifact with:

```bash
macos/scripts/release-app.sh 0.2.8
```

This produces:

```text
macos/dist/agentbox-client-macos-arm64-v0.2.8.zip
macos/dist/agentbox-client-macos-arm64-v0.2.8.zip.sha256
macos/dist/agentbox-client-macos-arm64-v0.2.8.dmg
macos/dist/agentbox-client-macos-arm64-v0.2.8.dmg.sha256
```

The DMG includes an Applications shortcut for drag-to-install. The app is
ad-hoc signed, not Developer ID signed or notarized.

The GitHub release tag must be `v0.2.8` and the ZIP asset name must remain
stable. Do not publish an update without the checksum file; the client refuses
archives whose SHA-256 cannot be verified.

Current limitations:

- Full iTerm2 feature parity is not implemented yet; tabs, native rendering,
  search, IME, Fonts and basic terminal protocols come from SwiftTerm.
- Sync conflict resolution is exposed through the sidecar status, not a
  graphical merge UI yet.
- Live `.git` synchronization is intentionally disabled. Git metadata must be
  seeded or managed separately.
- Background sync currently runs while the app is open. LaunchAgent
  installation and a conflict/trash browser are the next milestone.
