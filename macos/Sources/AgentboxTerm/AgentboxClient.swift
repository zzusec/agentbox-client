import Foundation

final class AgentboxClient {
    let server: URL
    let user: String
    let token: String

    init(server: URL, user: String, token: String) {
        self.server = server
        self.user = user
        self.token = token
    }

    static func redeem(_ rawCode: String) async throws -> SavedConnection {
        let pairing = try PairingCode.decode(rawCode)
        let url = endpoint(pairing.server, "api/clients/pair/redeem")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": pairing.secret])
        let data = try await perform(request, token: nil)
        let result = try JSONDecoder().decode(PairRedeemResponse.self, from: data)
        let server = pairing.server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        try KeychainStore.saveToken(result.token, user: result.user)
        UserDefaults.standard.set(server, forKey: "agentbox.server")
        UserDefaults.standard.set(result.user, forKey: "agentbox.user")
        return SavedConnection(server: server, user: result.user, token: result.token)
    }

    func workspaces() async throws -> [Workspace] {
        try await request("api/sessions")
    }

    func projects(in workspace: Workspace) async throws -> [RemoteProject] {
        let projects: [RemoteProject] = try await request(
            "api/sessions/\(escaped(workspace.id))/projects"
        )
        return projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Creates a project. A nil agent follows the instance default; a nil or
    /// default command lets the server pick the agent's default command.
    func createProject(
        name: String,
        agent: String? = nil,
        command: String? = nil,
        in workspace: Workspace
    ) async throws -> RemoteProject {
        let url = Self.endpoint(server, "api/sessions/\(escaped(workspace.id))/projects")
        var request = authorizedRequest(url: url, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: String] = ["name": name]
        if let agent { body["agent"] = agent }
        if let command { body["command"] = command }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await Self.perform(request, token: token)
        return try JSONDecoder().decode(RemoteProject.self, from: data)
    }

    /// Server-side project rename: the handler renames the workspace directory
    /// on disk and updates the database row in one request.
    func renameProject(_ project: RemoteProject, to newName: String, in workspace: Workspace) async throws -> RemoteProject {
        let url = Self.endpoint(
            server,
            "api/sessions/\(escaped(workspace.id))/projects/\(escaped(project.id))"
        )
        var request = authorizedRequest(url: url, method: "PATCH")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": newName])
        let data = try await Self.perform(request, token: token)
        return try JSONDecoder().decode(RemoteProject.self, from: data)
    }

    /// Changes which tool a project terminal starts and with what command. An
    /// empty command restores the default for the chosen tool. Terminals that
    /// are already running keep their process; the next one uses the change.
    func updateProjectLaunch(
        _ project: RemoteProject,
        agent: String,
        command: String,
        in workspace: Workspace
    ) async throws -> RemoteProject {
        let url = Self.endpoint(
            server,
            "api/sessions/\(escaped(workspace.id))/projects/\(escaped(project.id))"
        )
        var request = authorizedRequest(url: url, method: "PATCH")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["agent": agent, "command": command])
        let data = try await Self.perform(request, token: token)
        return try JSONDecoder().decode(RemoteProject.self, from: data)
    }

    /// Server-side project deletion: the handler moves the workspace directory
    /// into a trash folder rather than unlinking it outright.
    func deleteProject(_ project: RemoteProject, in workspace: Workspace) async throws {
        let url = Self.endpoint(
            server,
            "api/sessions/\(escaped(workspace.id))/projects/\(escaped(project.id))"
        )
        let request = authorizedRequest(url: url, method: "DELETE")
        _ = try await Self.perform(request, token: token)
    }

    /// Uploads one file into a project. onProgress receives 0...1 as the body
    /// goes out, on a background queue.
    func upload(
        file: URL,
        workspace: Workspace,
        project: String,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> String? {
        let boundary = "Agentbox-\(UUID().uuidString)"
        let multipart = try MultipartFile(file: file, boundary: boundary)
        defer { multipart.remove() }

        var components = URLComponents(
            url: Self.endpoint(server, "api/sessions/\(escaped(workspace.id))/upload"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "path", value: project)]
        guard let url = components?.url else {
            throw AgentboxClientError.invalidResponse
        }
        var request = authorizedRequest(url: url, method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let delegate = onProgress.map { UploadProgressDelegate(onProgress: $0) }
        let (data, response) = try await URLSession.shared.upload(
            for: request,
            fromFile: multipart.url,
            delegate: delegate
        )
        try Self.validate(response: response, data: data, accepted: 200..<300)
        let result = try JSONDecoder().decode(UploadResponse.self, from: data)
        return result.containerPath
    }

    func terminalURL(workspace: Workspace, project: String) -> URL? {
        var components = URLComponents(url: Self.endpoint(
            server,
            "api/sessions/\(escaped(workspace.id))/term"
        ), resolvingAgainstBaseURL: false)
        components?.scheme = server.scheme == "https" ? "wss" : "ws"
        components?.queryItems = [
            URLQueryItem(name: "mode", value: "agent"),
            URLQueryItem(name: "project", value: project),
            URLQueryItem(name: "token", value: token),
        ]
        return components?.url
    }

    private func request<T: Decodable>(_ path: String) async throws -> T {
        let request = authorizedRequest(url: Self.endpoint(server, path), method: "GET")
        let data = try await Self.perform(request, token: token)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func authorizedRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func perform(_ request: URLRequest, token: String?) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data, accepted: 200..<300)
            return data
        } catch let error as AgentboxClientError {
            throw error
        } catch {
            throw AgentboxClientError.transport(error.localizedDescription)
        }
    }

    private static func validate(
        response: URLResponse,
        data: Data,
        accepted: Range<Int>
    ) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AgentboxClientError.invalidResponse
        }
        guard accepted.contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ServerError.self, from: data).error)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw AgentboxClientError.server(message)
        }
    }

    private func escaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private static func endpoint(_ server: URL, _ path: String) -> URL {
        path.split(separator: "/").reduce(server) { partial, component in
            partial.appendingPathComponent(String(component))
        }
    }

    private struct ServerError: Decodable {
        let error: String
    }
}

private final class MultipartFile {
    let url: URL

    init(file: URL, boundary: String) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentbox-upload-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }

        func write(_ string: String) throws {
            try output.write(contentsOf: Data(string.utf8))
        }
        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"file\"; filename=\"\(escapedName(file.lastPathComponent))\"\r\n")
        try write("Content-Type: application/octet-stream\r\n\r\n")

        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while true {
            let chunk = try input.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
        }
        try write("\r\n--\(boundary)--\r\n")
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    private func escapedName(_ name: String) -> String {
        name.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}

/// Reports how much of an upload body has been sent. A task delegate rather
/// than a session delegate, so the shared session needs no configuration.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}
