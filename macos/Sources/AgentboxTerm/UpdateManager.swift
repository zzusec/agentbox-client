import AppKit
import CryptoKit
import Foundation

@MainActor
final class UpdateManager {
    static let shared = UpdateManager()

    private let releaseAPI: URL = {
        let repository = Bundle.main.object(forInfoDictionaryKey: "AgentboxUpdateRepository") as? String
            ?? "zzusec/agentbox"
        return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }()
    private var timer: Timer?
    private var checking = false
    private var installing = false

    private init() {}

    func start() {
        if UserDefaults.standard.object(forKey: "agentbox.update.auto") == nil {
            UserDefaults.standard.set(true, forKey: "agentbox.update.auto")
        }
        schedule()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            check(interactive: false)
        }
    }

    func applyMenuState(_ item: NSMenuItem) {
        item.state = UserDefaults.standard.bool(forKey: "agentbox.update.auto") ? .on : .off
    }

    @objc func toggleAutomatic(_ sender: NSMenuItem) {
        let enabled = !UserDefaults.standard.bool(forKey: "agentbox.update.auto")
        UserDefaults.standard.set(enabled, forKey: "agentbox.update.auto")
        sender.state = enabled ? .on : .off
        schedule()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        check(interactive: true)
    }

    /// The server was redeployed. The two are released together — this app
    /// carries the sync engine that talks to that server — so look for a client
    /// build now instead of waiting out the four-hour timer.
    ///
    /// The matching client release is usually published minutes after the
    /// server is live, so a couple of follow-ups cover that gap. Nothing is
    /// installed unless 自动检查并准备更新 is on; the check is otherwise silent.
    func serverDidChange() {
        check(interactive: false)
        for delay in Self.followUpDelays {
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.check(interactive: false) }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private static let followUpDelays: [TimeInterval] = [10 * 60, 30 * 60]

    private func schedule() {
        timer?.invalidate()
        guard UserDefaults.standard.bool(forKey: "agentbox.update.auto") else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 4 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check(interactive: false) }
        }
    }

    private func check(interactive: Bool) {
        guard !checking, !installing else { return }
        checking = true
        Task { @MainActor in
            defer { checking = false }
            do {
                let release = try await latestRelease()
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                guard UpdateLogic.isVersion(release.tagName, newerThan: current) else {
                    if interactive {
                        presentInfo(title: "没有可用更新", message: "当前版本 \(current) 已是最新版本。")
                    }
                    return
                }
                let automatic = UserDefaults.standard.bool(forKey: "agentbox.update.auto")
                if interactive || automatic {
                    try await prepareAndInstall(release, interactive: interactive)
                }
            } catch {
                if interactive {
                    presentInfo(title: "检查更新失败", message: error.localizedDescription)
                }
            }
        }
    }

    private func latestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: releaseAPI)
        request.setValue("agentbox-client/\(Bundle.main.shortVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.message("GitHub 返回了 \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease else {
            throw UpdateError.message("最新版是草稿或预发布版本")
        }
        return release
    }

    private func prepareAndInstall(_ release: GitHubRelease, interactive: Bool) async throws {
        guard let asset = UpdateLogic.selectMacAsset(release.assets) else {
            throw UpdateError.message("发布中没有 macOS arm64 应用包")
        }
        let automatic = UserDefaults.standard.bool(forKey: "agentbox.update.auto")
        if interactive {
            let alert = NSAlert()
            alert.messageText = "发现新版本 \(release.tagName)"
            // Just what is about to happen. The release notes are written for
            // whoever maintains this, not for the person being asked to click
            // a button, and they filled the dialog with implementation detail.
            alert.informativeText = "将下载并校验更新，然后重启应用完成安装。"
            alert.addButton(withTitle: "下载并安装")
            alert.addButton(withTitle: "稍后")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        } else if !automatic {
            return
        }

        installing = true
        defer { installing = false }
        let download = try await download(asset)
        let digest = try verifyDigest(download, release: release, asset: asset)
        _ = digest
        let app = try unzipAndValidate(download, expectedVersion: release.tagName)
        try install(app)
    }

    private func download(_ asset: ReleaseAsset) async throws -> URL {
        guard let url = URL(string: asset.browserDownloadURL) else {
            throw UpdateError.message("更新包地址无效")
        }
        let (temporary, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.message("下载更新失败")
        }
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentbox-client-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }

    private func verifyDigest(
        _ archive: URL,
        release: GitHubRelease,
        asset: ReleaseAsset,
    ) throws -> String {
        var expected = UpdateLogic.digestValue(asset.digest)
        if expected == nil,
           let checksum = release.assets.first(where: { $0.name == asset.name + ".sha256" }),
           let url = URL(string: checksum.browserDownloadURL),
           let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            expected = text.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)?.lowercased()
        }
        guard let expected, expected.count == 64 else {
            throw UpdateError.message("发布缺少 SHA-256 校验值")
        }
        let actual = try sha256(archive)
        guard actual == expected else {
            throw UpdateError.message("更新包 SHA-256 校验失败")
        }
        return actual
    }

    private func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func unzipAndValidate(_ archive: URL, expectedVersion: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentbox-client-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.message("更新包中找不到 .app")
        }
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let version = info["CFBundleShortVersionString"] as? String,
              !UpdateLogic.isVersion(expectedVersion, newerThan: version) else {
            throw UpdateError.message("更新包的版本或 Bundle ID 不匹配")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        return app
    }

    private func install(_ source: URL) throws {
        let target = Bundle.main.bundleURL
        guard !target.path.contains("/AppTranslocation/") else {
            throw UpdateError.message("应用正从临时位置运行，请先移动到“应用程序”文件夹")
        }
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.message("没有权限替换 \(target.path)")
        }
        let staging = parent.appendingPathComponent(".agentbox-client-update-\(UUID().uuidString).app")
        try run("/usr/bin/ditto", [source.path, staging.path])
        let script = try writeInstaller()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), staging.path, target.path]
        try process.run()
        NSApp.terminate(nil)
    }

    private func writeInstaller() throws -> URL {
        let script = """
        #!/bin/sh
        set -eu
        pid="$1"
        src="$2"
        dst="$3"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        backup="${dst}.backup-$(date +%s)"
        moved=0
        if [ -e "$dst" ]; then
          mv "$dst" "$backup"
          moved=1
        fi
        if ! ditto "$src" "$dst"; then
          rm -rf "$dst"
          if [ "$moved" = "1" ]; then mv "$backup" "$dst"; fi
          open "$dst"
          exit 1
        fi
        rm -rf "$src"
        open "$dst"
        if [ "$moved" = "1" ]; then sleep 3; rm -rf "$backup"; fi
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentbox-term-update-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.message(text?.isEmpty == false ? text! : "\(executable) 执行失败")
        }
    }

    private func presentInfo(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

private enum UpdateError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(value): return value
        }
    }
}

private extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
