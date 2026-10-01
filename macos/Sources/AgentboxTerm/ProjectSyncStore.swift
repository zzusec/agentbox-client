import Foundation

/// Per-project sync overrides, persisted per workspace.
///
/// Entries are keyed by project ID rather than name so renaming a project
/// keeps its directory and policy. The two fields live in separate defaults
/// dictionaries rather than one encoded blob, so a partial write can never
/// lose the other half.
enum ProjectSyncStore {
    static func localDirKey(_ workspaceID: String) -> String {
        "agentbox.project-local-dir.\(workspaceID)"
    }

    static func policyKey(_ workspaceID: String) -> String {
        "agentbox.project-policy.\(workspaceID)"
    }

    static func settings(for workspaceID: String, defaults: UserDefaults = .standard) -> [String: ProjectSyncSetting] {
        let dirs = defaults.dictionary(forKey: localDirKey(workspaceID)) as? [String: String] ?? [:]
        let policies = defaults.dictionary(forKey: policyKey(workspaceID)) as? [String: String] ?? [:]
        var settings: [String: ProjectSyncSetting] = [:]
        for (id, dir) in dirs where !dir.isEmpty {
            settings[id, default: ProjectSyncSetting()].localDir = dir
        }
        for (id, policy) in policies where !policy.isEmpty {
            settings[id, default: ProjectSyncSetting()].policy = policy
        }
        return settings
    }

    static func store(
        _ settings: [String: ProjectSyncSetting],
        for workspaceID: String,
        defaults: UserDefaults = .standard
    ) {
        var dirs: [String: String] = [:]
        var policies: [String: String] = [:]
        for (id, setting) in settings {
            if let dir = setting.localDir, !dir.isEmpty {
                dirs[id] = dir
            }
            if let policy = setting.policy, !policy.isEmpty {
                policies[id] = policy
            }
        }
        defaults.set(dirs, forKey: localDirKey(workspaceID))
        defaults.set(policies, forKey: policyKey(workspaceID))
    }

    /// Applies one change and drops the entry entirely once it is back to
    /// carrying nothing, so "follow the workspace" stays the default state
    /// instead of an explicit empty override.
    static func update(
        _ workspaceID: String,
        projectID: String,
        defaults: UserDefaults = .standard,
        _ change: (inout ProjectSyncSetting) -> Void
    ) {
        var settings = settings(for: workspaceID, defaults: defaults)
        var setting = settings[projectID] ?? ProjectSyncSetting()
        change(&setting)
        if setting.isEmpty {
            settings.removeValue(forKey: projectID)
        } else {
            settings[projectID] = setting
        }
        store(settings, for: workspaceID, defaults: defaults)
    }

    static func remove(_ workspaceID: String, projectID: String, defaults: UserDefaults = .standard) {
        update(workspaceID, projectID: projectID, defaults: defaults) { setting in
            setting = ProjectSyncSetting()
        }
    }
}
