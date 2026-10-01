import Foundation

final class SyncManager {
    var onStatus: ((String) -> Void)?

    private let client: AgentboxClient
    private let workspace: Workspace
    private let localRoot: URL
    private let initialPolicy: String
    private let projectSettings: [String: ProjectSyncSetting]
    private var process: Process?
    private var output: Pipe?
    private var configURL: URL?

    init(
        client: AgentboxClient,
        workspace: Workspace,
        localRoot: URL,
        initialPolicy: String,
        projectSettings: [String: ProjectSyncSetting] = [:]
    ) {
        self.client = client
        self.workspace = workspace
        self.localRoot = localRoot
        self.initialPolicy = initialPolicy
        self.projectSettings = projectSettings
    }

    func start() {
        stop()
        guard let executable = Bundle.main.url(forResource: "abox-sync", withExtension: nil) else {
            onStatus?("找不到 abox-sync；请使用 build-app.sh 生成完整应用")
            return
        }
        do {
            let config = try writeConfig()
            configURL = config
            let process = Process()
            process.executableURL = executable
            process.arguments = ["-config", config.path, "-watch"]
            process.environment = ProcessInfo.processInfo.environment.merging([
                "AGENTBOX_TOKEN": client.token,
            ]) { _, new in new }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    self?.onStatus?(text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            try process.run()
            self.process = process
            self.output = pipe
            onStatus?("同步已启动：\(localRoot.path)")
        } catch {
            onStatus?("同步启动失败：\(error.localizedDescription)")
        }
    }

    func stop() {
        output?.fileHandleForReading.readabilityHandler = nil
        output = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }

    /// Runs a single forced-overwrite pass for one project and reports what the
    /// engine printed.
    ///
    /// Output is streamed through `onStatus` as it arrives — a full overwrite
    /// of a big tree takes a while, and waiting for the exit before showing
    /// anything makes the button look dead. The completion carries the last
    /// line so the status bar can settle on the result.
    ///
    /// The watcher must already be stopped and restarted by the caller: two
    /// engines syncing the same project at once would fight over the lease and
    /// the baseline. `-force-policy` is deliberately a one-shot flag — the
    /// engine refuses to combine it with `-watch`, because it overwrites the
    /// other side every time it runs.
    func runForcedPass(project: String, policy: String, completion: @escaping (String) -> Void) {
        guard let executable = Bundle.main.url(forResource: "abox-sync", withExtension: nil) else {
            completion("找不到 abox-sync；请使用 build-app.sh 生成完整应用")
            return
        }
        guard let config = configURL ?? (try? writeConfig()) else {
            completion("无法写入同步配置")
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "-config", config.path,
            "-project", project,
            "-force-policy", policy,
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "AGENTBOX_TOKEN": client.token,
        ]) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let lock = NSLock()
        var collected = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            lock.lock()
            collected += text
            lock.unlock()
            DispatchQueue.main.async {
                self?.onStatus?(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try process.run()
                process.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                lock.lock()
                let output = collected
                lock.unlock()
                let status = process.terminationStatus
                let last = output
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .last { !$0.isEmpty }
                DispatchQueue.main.async {
                    if status != 0 {
                        completion(last ?? "全量同步失败（退出码 \(status)）")
                    } else if let last {
                        completion(last)
                    } else {
                        completion("全量同步完成（没有需要变更的文件）")
                    }
                }
            } catch {
                DispatchQueue.main.async { completion("全量同步启动失败：\(error.localizedDescription)") }
            }
        }
    }

    private func writeConfig() throws -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("agentbox-client", isDirectory: true)
        try FileManager.default.createDirectory(
            at: support,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let path = support.appendingPathComponent("sync-\(workspace.id).json")
        let deviceID: String
        if let existing = UserDefaults.standard.string(forKey: "agentbox.sync.device-id"), !existing.isEmpty {
            deviceID = existing
        } else {
            deviceID = UUID().uuidString
            UserDefaults.standard.set(deviceID, forKey: "agentbox.sync.device-id")
        }
        let payload: [String: Any] = [
            "server": client.server.absoluteString,
            "session_id": workspace.id,
            "local_root": localRoot.path,
            "device_id": deviceID,
            "device_name": Host.current().localizedName ?? "Mac",
            "interval_seconds": 1,
            "projects": [],
            "initial_policy": initialPolicy,
            "project_settings": encodedProjectSettings(),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: path, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return path
    }

    /// Per-project overrides, keyed by project ID (which survives a rename).
    /// Projects with neither a directory nor a policy are left out so the
    /// classic `<local root>/<project name>` layout keeps applying.
    private func encodedProjectSettings() -> [String: [String: String]] {
        var encoded: [String: [String: String]] = [:]
        for (id, setting) in projectSettings {
            var entry: [String: String] = [:]
            if let dir = setting.localDir, !dir.isEmpty {
                entry["local_dir"] = dir
            }
            if let policy = setting.policy, !policy.isEmpty {
                entry["initial_policy"] = policy
            }
            if !entry.isEmpty {
                encoded[id] = entry
            }
        }
        return encoded
    }
}
