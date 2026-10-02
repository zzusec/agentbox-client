import Foundation

struct Workspace: Decodable, Identifiable {
    let id: String
    let name: String
    let agent: String
    let accountID: String
    let accountLabel: String
    let claudeAccountID: String?
    let claudeAccountLabel: String?
    let codexAccountID: String?
    let codexAccountLabel: String?

    enum CodingKeys: String, CodingKey {
        case id, name, agent
        case accountID = "account_id"
        case accountLabel = "account_label"
        case claudeAccountID = "claude_account_id"
        case claudeAccountLabel = "claude_account_label"
        case codexAccountID = "codex_account_id"
        case codexAccountLabel = "codex_account_label"
    }

    /// An instance (a container VM) binds Claude, Codex or both; the picker
    /// shows the bound tools next to the instance name.
    /// The tools this instance has accounts for, Claude first. A project can
    /// only be pinned to one of these — the server refuses the others.
    var tools: [String] {
        var out: [String] = []
        let split = claudeAccountID?.isEmpty == false || codexAccountID?.isEmpty == false
        if claudeAccountID?.isEmpty == false || (!split && agent != "codex") { out.append("claude") }
        if codexAccountID?.isEmpty == false || (!split && agent == "codex") { out.append("codex") }
        return out
    }

    var toolsLabel: String {
        var tools: [String] = []
        if claudeAccountID?.isEmpty == false { tools.append("Claude") }
        if codexAccountID?.isEmpty == false { tools.append("Codex") }
        if tools.isEmpty {
            return agent == "codex" ? "Codex" : "Claude"
        }
        return tools.joined(separator: " + ")
    }
}

struct RemoteProject: Decodable, Identifiable {
    let id: String
    let name: String
    let path: String
    /// "claude" or "codex" when the project is pinned to a tool; empty means
    /// it follows the instance default.
    var agent: String = ""
    /// What the project terminal runs. The server fills in the default for
    /// the project's tool, so this is never empty on a current server.
    var command: String = ""
    var defaultCommand: String = ""
    /// Whether `command` was set explicitly rather than being the default.
    var customCommand: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, path, agent, command
        case defaultCommand = "default_command"
        case customCommand = "custom_command"
    }
}

extension RemoteProject {
    /// Written out so an older server, which sends none of the launch
    /// fields, still decodes. Declared in an extension to keep the memberwise
    /// initializer.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        path = try values.decode(String.self, forKey: .path)
        agent = try values.decodeIfPresent(String.self, forKey: .agent) ?? ""
        command = try values.decodeIfPresent(String.self, forKey: .command) ?? ""
        defaultCommand = try values.decodeIfPresent(String.self, forKey: .defaultCommand) ?? ""
        customCommand = try values.decodeIfPresent(Bool.self, forKey: .customCommand) ?? false
    }
}

/// Launch defaults, mirroring the server's. The server is the source of truth
/// — it stores a command equal to the default as "use the default" — so this
/// only decides what the new-project form shows before anything exists.
enum ProjectLaunch {
    static func defaultCommand(for agent: String) -> String {
        agent == "codex" ? "codex --yolo" : "claude --dangerously-skip-permissions"
    }

    static func label(for agent: String) -> String {
        agent == "codex" ? "Codex" : "Claude"
    }
}

/// One line of `abox-sync -events` output.
enum SyncEvent {
    case progress(SyncProgress)
    case transfer(SyncTransfer)
    case status(SyncStatus)

    private struct Envelope: Decodable {
        let type: String
    }

    static func decode(_ line: Data) -> SyncEvent? {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: line) else { return nil }
        switch envelope.type {
        case "progress":
            return (try? decoder.decode(SyncProgress.self, from: line)).map(SyncEvent.progress)
        case "transfer":
            return (try? decoder.decode(SyncTransfer.self, from: line)).map(SyncEvent.transfer)
        case "status":
            return (try? decoder.decode(SyncStatus.self, from: line)).map(SyncEvent.status)
        default:
            return nil
        }
    }

    /// The arrow and verb the status bar uses for an engine phase.
    static func phaseLabel(_ phase: String) -> String {
        switch phase {
        case "upload": return "↑ 上传"
        case "download": return "↓ 下载"
        case "delete_local": return "⌫ 移入本地回收站"
        case "delete_remote": return "⌫ 删除服务器文件"
        case "done": return "完成"
        default: return phase
        }
    }
}

struct SyncProgress: Decodable {
    let project: String
    let phase: String
    let path: String?
    let index: Int
    let total: Int
    let bytes: Int64
    let totalBytes: Int64
    let percent: Double

    enum CodingKeys: String, CodingKey {
        case project, phase, path, index, total, bytes, percent
        case totalBytes = "total_bytes"
    }
}

struct SyncTransfer: Decodable {
    let project: String
    let phase: String
    let path: String
    let bytes: Int64
    let durationMS: Int64

    enum CodingKeys: String, CodingKey {
        case project, phase, path, bytes
        case durationMS = "duration_ms"
    }
}

struct SyncStatus: Decodable {
    let project: String
    let inSync: Bool
    let applied: Int
    let conflicts: [String]?
    let error: String?
    let durationMS: Int64
    let at: String

    enum CodingKeys: String, CodingKey {
        case project, applied, conflicts, error, at
        case inSync = "in_sync"
        case durationMS = "duration_ms"
    }
}

/// Human sizes and durations for the status bar.
enum SyncFormat {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func duration(milliseconds: Int64) -> String {
        if milliseconds < 1000 {
            return "\(milliseconds)ms"
        }
        let seconds = Double(milliseconds) / 1000
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        return String(format: "%dm%02ds", Int(seconds) / 60, Int(seconds) % 60)
    }
}

/// Per-project sync overrides, keyed by project ID so a rename keeps them.
/// An absent or empty field means the workspace default applies: the project
/// syncs to `<local root>/<project name>` under the workspace policy.
struct ProjectSyncSetting: Equatable {
    var localDir: String?
    var policy: String?

    var isEmpty: Bool {
        (localDir ?? "").isEmpty && (policy ?? "").isEmpty
    }

    /// The sync policy only takes effect when a project has to build a fresh
    /// baseline, so the UI has to say so rather than implying a live switch.
    static func policyLabel(_ policy: String?) -> String {
        switch policy {
        case "server": return "从服务器下载到本地"
        case "local": return "从本地上传到服务器"
        default: return "双向同步（默认）"
        }
    }
}

struct UploadResponse: Decodable {
    let files: Int
    let mode: String
    let path: String?
    let containerPath: String?

    enum CodingKeys: String, CodingKey {
        case files, mode, path
        case containerPath = "container_path"
    }
}

struct PairIssueResponse: Decodable {
    let code: String
}

struct PairRedeemResponse: Decodable {
    let user: String
    let token: String
}

struct SavedConnection {
    let server: String
    let user: String
    let token: String
}

enum AgentboxClientError: LocalizedError {
    case invalidResponse
    case server(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器返回了无法识别的响应"
        case let .server(message):
            return message
        case let .transport(message):
            return message
        }
    }
}

/// A file dropped on a terminal is uploaded by that terminal, but its progress
/// belongs in the window's bottom bar, which the terminal does not own. The
/// two talk through this notification instead of holding references.
enum UploadProgressNote {
    static let name = Notification.Name("agentbox.upload.progress")

    enum State {
        case running(fraction: Double)
        case finished(bytes: Int64, milliseconds: Int64)
        case failed(message: String)
    }

    static func post(file: String, project: String, state: State) {
        NotificationCenter.default.post(
            name: name,
            object: nil,
            userInfo: ["file": file, "project": project, "state": state]
        )
    }

    static func decode(_ note: Notification) -> (file: String, project: String, state: State)? {
        guard let info = note.userInfo,
              let file = info["file"] as? String,
              let project = info["project"] as? String,
              let state = info["state"] as? State else { return nil }
        return (file, project, state)
    }
}
