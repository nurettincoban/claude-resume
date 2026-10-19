import Foundation

enum AgentProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude" : "Codex" }
    var executable: String { rawValue }
}

/// A configuration folder with its own login and history: `CLAUDE_CONFIG_DIR` for Claude Code,
/// `CODEX_HOME` for Codex.
struct AgentProfile: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    let directory: URL
    var provider: AgentProvider = .claude

    init(id: String, name: String, directory: URL, provider: AgentProvider = .claude) {
        self.id = id
        self.name = name
        self.directory = directory
        self.provider = provider
    }

    private enum CodingKeys: String, CodingKey { case id, name, directory, provider }

    /// Accounts saved before Codex support have no provider and are Claude accounts.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        directory = try values.decode(URL.self, forKey: .directory)
        provider = try values.decodeIfPresent(AgentProvider.self, forKey: .provider) ?? .claude
    }

    /// `~/.claude`, the folder Claude Code uses when `CLAUDE_CONFIG_DIR` isn't set.
    static let personal = AgentProfile(
        id: "default", name: "Personal",
        directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    )

    /// `~/.codex`, the folder Codex uses when `CODEX_HOME` isn't set.
    static let defaultCodexDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)

    var isPersonal: Bool { id == Self.personal.id }

    /// The name, plus "Codex" for Codex accounts unless the name already says so.
    var label: String {
        provider == .codex && !name.localizedCaseInsensitiveContains("codex") ? "\(name) · Codex" : name
    }

    /// The folder the CLI uses on its own, so commands for it need no environment changes.
    var usesDefaultFolder: Bool {
        switch provider {
        case .claude: isPersonal
        case .codex: Self.canonicalDirectory(directory.path) == Self.canonicalDirectory(Self.defaultCodexDirectory.path)
        }
    }
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
            result.append(AgentProfile(id: profile.id, name: profile.name, directory: directory, provider: profile.provider))
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
    private var codexScanners: [AgentProfile: CodexSessionScanner] = [:]

    func scan(_ profiles: [AgentProfile]) -> [Session] {
        lock.withLock {
            scanners = scanners.filter { profiles.contains($0.key) }
            codexScanners = codexScanners.filter { profiles.contains($0.key) }
            return profiles.flatMap { profile -> [Session] in
                if profile.provider == .codex {
                    let scanner = codexScanners[profile] ?? CodexSessionScanner(profile: profile)
                    codexScanners[profile] = scanner
                    return scanner.scan()
                }
                let scanner = scanners[profile] ?? SessionScanner(profile: profile)
                scanners[profile] = scanner
                return scanner.scan()
            }.sorted { $0.lastActivity > $1.lastActivity }
        }
    }
}
