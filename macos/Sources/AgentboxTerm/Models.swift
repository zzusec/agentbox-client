import Foundation

struct Workspace: Decodable, Identifiable {
    let id: String
    let name: String
    let agent: String
    let accountID: String
    let accountLabel: String

    enum CodingKeys: String, CodingKey {
        case id, name, agent
        case accountID = "account_id"
        case accountLabel = "account_label"
    }
}

struct FileEntry: Decodable {
    let name: String
    let isDir: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case isDir = "is_dir"
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
