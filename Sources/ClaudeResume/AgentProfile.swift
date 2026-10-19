import Foundation

/// A Claude Code configuration folder with its own login and history (`CLAUDE_CONFIG_DIR`).
struct AgentProfile: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    let directory: URL

    /// `~/.claude`, the folder Claude Code uses when `CLAUDE_CONFIG_DIR` isn't set.
    static let personal = AgentProfile(
        id: "default", name: "Personal",
        directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    )

    var isPersonal: Bool { id == Self.personal.id }
    var projectsRoot: URL { directory.appendingPathComponent("projects", isDirectory: true) }
    var sessionsRoot: URL { directory.appendingPathComponent("sessions", isDirectory: true) }

    /// Personal keeps bare session IDs, so existing pins, hidden sessions and renames still apply.
    /// Other accounts are prefixed, since a copied folder can hold the same session IDs.
    func sessionKey(_ sessionID: String) -> String {
        isPersonal ? sessionID : "\(id):\(sessionID)"
    }

    static func canonicalDirectory(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
    }
}

enum ProfilePreferences {
    static let key = "claudeProfiles"

    /// Personal first, then the saved accounts. Entries without a name or sharing a folder are dropped.
    static func load(from defaults: UserDefaults = .standard) -> [AgentProfile] {
        var result: [AgentProfile] = [.personal]
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode([AgentProfile].self, from: data) else { return result }
        for profile in saved {
            let directory = AgentProfile.canonicalDirectory(profile.directory.path)
            guard !profile.id.isEmpty, !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !result.contains(where: { $0.id == profile.id || AgentProfile.canonicalDirectory($0.directory.path) == directory })
            else { continue }
            result.append(AgentProfile(id: profile.id, name: profile.name, directory: directory))
        }
        return result
    }

    static func save(_ profiles: [AgentProfile], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(profiles.filter { !$0.isPersonal }) else { return }
        defaults.set(data, forKey: key)
    }
}

/// One scanner per account, so each keeps its transcript cache across refreshes.
final class ProfileScanner: @unchecked Sendable {
    private let lock = NSLock()
    private var scanners: [AgentProfile: SessionScanner] = [:]

    func scan(_ profiles: [AgentProfile]) -> [Session] {
        lock.withLock {
            scanners = scanners.filter { profiles.contains($0.key) }
            return profiles.flatMap { profile -> [Session] in
                let scanner = scanners[profile] ?? SessionScanner(profile: profile)
                scanners[profile] = scanner
                return scanner.scan()
            }.sorted { $0.lastActivity > $1.lastActivity }
        }
    }
}
