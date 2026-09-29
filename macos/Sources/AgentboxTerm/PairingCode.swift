import Foundation

struct PairingCode {
    let server: URL
    let secret: String

    static func decode(_ raw: String) throws -> PairingCode {
        let compact = raw.filter { !$0.isWhitespace }
        let prefix = "ABOX1-"
        guard compact.hasPrefix(prefix) else {
            throw AgentboxClientError.server("这不像一个配对码")
        }
        var encoded = String(compact.dropFirst(prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 {
            encoded.append("=")
        }
        guard let data = Data(base64Encoded: encoded),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let server = URL(string: payload.server),
              server.scheme == "http" || server.scheme == "https",
              !payload.code.isEmpty else {
            throw AgentboxClientError.server("配对码格式错误，请重新复制")
        }
        return PairingCode(server: server, secret: payload.code)
    }

    private struct Payload: Decodable {
        let server: String
        let code: String

        enum CodingKeys: String, CodingKey {
            case server = "s"
            case code = "c"
        }
    }
}
