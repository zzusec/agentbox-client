import Foundation
import LocalAuthentication
import Security

enum KeychainStore {
    private static let service = "io.agentbox.term"
    private static let fileName = "credentials.json"

    static func saveToken(_ token: String, user: String) throws {
        var credentials = loadCredentials()
        credentials[user] = token
        try persist(credentials)
    }

    static func loadToken(user: String) -> String? {
        if let token = loadCredentials()[user] {
            return token
        }

        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: user,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        try? saveToken(token, user: user)
        return token
    }

    static func deleteToken(user: String) {
        var credentials = loadCredentials()
        credentials.removeValue(forKey: user)
        try? persist(credentials)
    }

    private static func credentialsURL() throws -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("agentbox-client", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }

    private static func loadCredentials() -> [String: String] {
        guard let url = try? credentialsURL(),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return values
    }

    private static func persist(_ credentials: [String: String]) throws {
        let url = try credentialsURL()
        let data = try JSONEncoder().encode(credentials)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
