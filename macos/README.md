# Agentbox Term for macOS

Agentbox Term is a native macOS terminal for agentbox workspaces. It uses
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
open "dist/Agentbox Term.app"
```

The build vendors SwiftTerm 1.5.0 under `third_party/swiftterm`, so building
does not fetch GitHub dependencies.

## First connection

1. Sign in to agentbox in a browser.
2. Open the user menu and choose `连接 Mac 终端`.
3. Paste the copied pairing code into Agentbox Term.
4. Select a workspace in the left sidebar.
5. Choose a local project root and select the initial side for projects that
   already exist both locally and remotely.
6. Click a project to attach to its Claude session.

The local root maps directly to the remote `/workspace`: remote project
`/workspace/demo` maps to `<local root>/demo`.

## Development

```bash
swift build
../macos/scripts/build-app.sh
```

The sync process currently polls every five seconds. The server owns project
IDs and sync leases; each project has one writable device at a time, while
other devices continue to receive server changes.

## Updates

Agentbox Term checks the latest GitHub release on launch and every four hours.
When `自动检查并准备更新` is enabled, it downloads `AgentboxTerm-macos-arm64.zip`,
verifies the release SHA-256 digest, verifies the `.app` code signature and only
then offers to restart into the new version. `检查更新…` in the application menu
runs the same flow immediately.

The release repository is read from `AgentboxUpdateRepository` in `Info.plist`
and currently points to `zzusec/agentbox`.

Create a release artifact with:

```bash
macos/scripts/release-app.sh 0.2.1
```

This produces:

```text
macos/dist/AgentboxTerm-macos-arm64-v0.2.1.zip
macos/dist/AgentboxTerm-macos-arm64-v0.2.1.zip.sha256
```

The GitHub release tag must be `v0.2.1` and the ZIP asset name must remain
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
