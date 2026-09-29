import Foundation

struct ReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: String
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case digest
    }
}

struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: String
    let draft: Bool
    let prerelease: Bool
    let assets: [ReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case draft
        case prerelease
        case assets
    }
}

enum UpdateLogic {
    static func normalizedVersion(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") {
            value.removeFirst()
        }
        return value
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let left = versionParts(candidate)
        let right = versionParts(current)
        for index in 0..<max(left.numbers.count, right.numbers.count) {
            let lhs = index < left.numbers.count ? left.numbers[index] : 0
            let rhs = index < right.numbers.count ? right.numbers[index] : 0
            if lhs != rhs {
                return lhs > rhs
            }
        }
        if left.prerelease == right.prerelease {
            return false
        }
        if left.prerelease == nil {
            return true
        }
        if right.prerelease == nil {
            return false
        }
        return left.prerelease! > right.prerelease!
    }

    static func selectMacAsset(_ assets: [ReleaseAsset]) -> ReleaseAsset? {
        assets.first { asset in
            let name = asset.name.lowercased()
            return name.hasSuffix(".zip") &&
                (name.contains("macos") || name.contains("darwin")) &&
                (name.contains("arm64") || name.contains("universal"))
        }
    }

    static func digestValue(_ digest: String?) -> String? {
        guard let digest else { return nil }
        let value = digest.lowercased()
        guard value.hasPrefix("sha256:") else { return nil }
        let hex = String(value.dropFirst("sha256:".count))
        return hex.count == 64 ? hex : nil
    }

    private static func versionParts(_ raw: String) -> (numbers: [Int], prerelease: String?) {
        let normalized = normalizedVersion(raw)
        let parts = normalized.split(separator: "-", maxSplits: 1).map(String.init)
        let numbers = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
        return (numbers, parts.count > 1 ? parts[1] : nil)
    }
}
