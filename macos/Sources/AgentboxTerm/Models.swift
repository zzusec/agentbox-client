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

    enum CodingKeys: String, CodingKey {
        case id, name, path
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
        case "server": return "以服务器为准"
        case "local": return "以本地为准"
        default: return "跟随工作空间"
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
