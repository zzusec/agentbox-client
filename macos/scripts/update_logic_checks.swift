import Foundation

@main
struct UpdateLogicChecks {
    static func main() {
        precondition(UpdateLogic.isVersion("v0.2.0", newerThan: "0.1.9"))
        precondition(UpdateLogic.isVersion("1.0.0", newerThan: "1.0.0-beta.1"))
        precondition(!UpdateLogic.isVersion("1.0.0", newerThan: "1.0.0"))
        precondition(!UpdateLogic.isVersion("0.9.9", newerThan: "1.0.0"))

        let assets = [
            ReleaseAsset(
                name: "agentbox-linux-amd64.tar.gz",
                browserDownloadURL: "https://example.invalid/linux",
                digest: nil
            ),
            ReleaseAsset(
                name: "AgentboxTerm-macos-arm64.zip",
                browserDownloadURL: "https://example.invalid/mac",
                digest: "sha256:abc"
            ),
        ]
        precondition(UpdateLogic.selectMacAsset(assets)?.name == "AgentboxTerm-macos-arm64.zip")

        let digest = String(repeating: "a", count: 64)
        precondition(UpdateLogic.digestValue("sha256:\(digest)") == digest)
        precondition(UpdateLogic.digestValue("sha512:\(digest)") == nil)
    }
}
