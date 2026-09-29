import Foundation

final class SyncManager {
    var onStatus: ((String) -> Void)?

    private let client: AgentboxClient
    private let workspace: Workspace
    private let localRoot: URL
    private let initialPolicy: String
    private var process: Process?
    private var output: Pipe?

    init(client: AgentboxClient, workspace: Workspace, localRoot: URL, initialPolicy: String) {
        self.client = client
        self.workspace = workspace
        self.localRoot = localRoot
        self.initialPolicy = initialPolicy
    }

    func start() {
        stop()
        guard let executable = Bundle.main.url(forResource: "abox-sync", withExtension: nil) else {
            onStatus?("找不到 abox-sync；请使用 build-app.sh 生成完整应用")
            return
        }
        do {
            let config = try writeConfig()
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
            "interval_seconds": 5,
            "projects": [],
            "initial_policy": initialPolicy,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: path, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return path
    }
}
