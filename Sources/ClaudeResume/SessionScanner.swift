import Foundation

/// A pull/merge request or a published artifact a session produced.
struct SessionLink: Hashable, Sendable, Identifiable {
    enum Kind: String, Sendable { case pullRequest, artifact }

    let kind: Kind
    let url: URL
    /// Short label: `!455`, `#5` or the artifact's title.
    let label: String
    /// Longer description for tooltips and the preview.
    let detail: String

    var id: String { url.absoluteString }
}

/// One Claude Code conversation, read from `~/.claude/projects/<project>/<id>.jsonl`.
struct Session: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var firstPrompt: String?
    var lastPrompt: String?
    var cwd: String?
    var branch: String?
    var promptCount: Int
    var startedAt: Date?
    var lastActivity: Date
    var transcriptURL: URL
    /// Claude's latest "while you were away" recap.
    var recap: String?
    /// The start of Claude's latest text reply.
    var lastReply: String?
    /// Files Claude edited or wrote, most recent first.
    var filesChanged: [String] = []
    /// Pull requests first, then artifacts, newest first within each.
    var links: [SessionLink] = []
    /// Tokens processed across the session and its subagents, cache reads included.
    var tokens: Int = 0
    var outputTokens: Int = 0
    /// Claude Code's own recorded total (`cost-state`), subagents included. Can be older than the transcript.
    var recordedCost: Double?
    /// Our estimate from token usage at list prices, subagents included.
    var estimatedCost: Double?
    /// Display names of the models used, most used first.
    var models: [String] = []
    /// The running turn, or the last one: everything since the latest prompt you typed.
    var lastTurn: TurnSummary?
    /// Shown instead of `cwd` (demo data only, so screenshots never show a real path).
    var displayPath: String?
    /// The account whose folder the transcript lives in.
    var profile: AgentProfile = .personal

    /// Identity for the list, pins, hidden sessions and running sessions. `id` stays the
    /// session ID that `claude --resume` takes.
    var key: String { profile.sessionKey(id) }

    /// The folder as shown and grouped in the UI.
    var projectPath: String? { displayPath ?? cwd }

    var folderName: String {
        guard let path = projectPath else { return "Unknown folder" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    var folderExists: Bool {
        guard let cwd else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) && isDir.boolValue
    }

    /// API-equivalent cost in USD: the larger of the recorded total and the estimate.
    var cost: Double? { [recordedCost, estimatedCost].compactMap { $0 }.max() }

    /// True unless the figure shown is Claude Code's own recorded total.
    var costIsEstimate: Bool {
        guard let recordedCost else { return true }
        return (estimatedCost ?? 0) > recordedCost
    }

    var pullRequests: [SessionLink] { links.filter { $0.kind == .pullRequest } }
    var artifacts: [SessionLink] { links.filter { $0.kind == .artifact } }
}

/// What happened since the latest prompt you typed.
struct TurnSummary: Hashable, Sendable {
    /// Claude Code's recorded turn duration, or the time from the prompt to the last reply.
    var duration: TimeInterval?
    /// Edit, Write, MultiEdit and NotebookEdit calls.
    var edits = 0
    /// Tool calls that returned an error.
    var errors = 0
    /// Estimated API cost of the turn's main-session requests.
    var cost: Double?
}

/// Scans the transcript folder, re-parsing only sessions whose files changed.
final class SessionScanner: @unchecked Sendable {
    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)

    /// Size and date of a transcript plus its subagent transcripts.
    private struct Stamp: Equatable {
        let modified: Date
        let size: Int
        let subagents: [String: Int]
    }

    private let root: URL
    private let profile: AgentProfile
    private let lock = NSLock()
    private var cache: [String: (stamp: Stamp, session: Session?)] = [:]
    private static let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]

    init(root: URL = SessionScanner.defaultRoot) {
        self.root = root
        profile = .personal
    }

    init(profile: AgentProfile) {
        root = profile.projectsRoot
        self.profile = profile
    }

    func scan() -> [Session] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles]) else { return [] }
        var sessions: [Session] = []
        var seen = Set<String>()
        for project in projects {
            // Only top-level transcripts: subfolders hold subagent and tool-result files.
            guard let files = try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: Self.keys,
                                                          options: [.skipsHiddenFiles]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: Set(Self.keys)), values.isRegularFile == true
                else { continue }
                let subagents = subagentFiles(for: file)
                let stamp = Stamp(modified: values.contentModificationDate ?? .distantPast, size: values.fileSize ?? 0,
                                  subagents: subagents.reduce(into: [:]) { $0[$1.url.lastPathComponent] = $1.size })
                seen.insert(file.path)
                if let session = cached(file.path, stamp) ?? parse(file, stamp, subagents: subagents.map(\.url)) {
                    sessions.append(session)
                }
            }
        }
        lock.withLock { cache = cache.filter { seen.contains($0.key) } }
        return sessions.sorted { $0.lastActivity > $1.lastActivity }
    }

    private func subagentFiles(for transcript: URL) -> [(url: URL, size: Int)] {
        let folder = transcript.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        else { return [] }
        return files.filter { $0.pathExtension == "jsonl" }.map {
            ($0, (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func cached(_ path: String, _ stamp: Stamp) -> Session?? {
        lock.withLock {
            guard let hit = cache[path], hit.stamp == stamp else { return nil }
            return .some(hit.session)
        }
    }

    private func parse(_ file: URL, _ stamp: Stamp, subagents: [URL]) -> Session? {
        var session = (try? Data(contentsOf: file, options: .alwaysMapped)).flatMap {
            TranscriptParser.parse($0, id: file.deletingPathExtension().lastPathComponent,
                                   url: file, modified: stamp.modified)
        }
        session?.profile = profile
        if session != nil, !subagents.isEmpty {
            var usage = UsageTally()
            for url in subagents {
                if let data = try? Data(contentsOf: url, options: .alwaysMapped) { TranscriptParser.tallyUsage(data, into: &usage) }
            }
            session?.addSubagentUsage(usage)
        }
        lock.withLock { cache[file.path] = (stamp, session) }
        return session
    }
}

/// Token usage per model, deduplicated by response (one response spans several transcript lines).
struct UsageTally {
    var byModel: [String: ModelCatalog.Usage] = [:]
    var seen = Set<String>()

    var tokens: Int { byModel.values.reduce(0) { $0 + $1.total } }
    var output: Int { byModel.values.reduce(0) { $0 + $1.output } }

    var cost: Double? {
        let costs = byModel.compactMap { ModelCatalog.cost(model: $0.key, usage: $0.value) }
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    mutating func add(key: String, model: String, usage: [String: Any]) {
        guard model != "<synthetic>", seen.insert(key).inserted else { return }
        var u = byModel[model] ?? ModelCatalog.Usage()
        u.input += usage["input_tokens"] as? Int ?? 0
        u.output += usage["output_tokens"] as? Int ?? 0
        u.cacheRead += usage["cache_read_input_tokens"] as? Int ?? 0
        let creation = usage["cache_creation_input_tokens"] as? Int ?? 0
        if let split = usage["cache_creation"] as? [String: Any] {
            u.cacheWrite5m += split["ephemeral_5m_input_tokens"] as? Int ?? 0
            u.cacheWrite1h += split["ephemeral_1h_input_tokens"] as? Int ?? 0
        } else {
            u.cacheWrite5m += creation
        }
        if usage["speed"] as? String == "fast" { u.fast = true }
        byModel[model] = u
    }
}

private extension Session {
    mutating func addSubagentUsage(_ usage: UsageTally) {
        tokens += usage.tokens
        outputTokens += usage.output
        if let extra = usage.cost { estimatedCost = (estimatedCost ?? 0) + extra }
    }
}

/// Pulls titles, prompts and metadata out of a transcript without decoding every line:
/// most of a transcript is tool output, which is skipped by looking at each line's first bytes.
enum TranscriptParser {
    private static let headLength = 600
    private static let maxDecodedLine = 256 * 1024
    private static let maxFiles = 40

    private static let userMarker = Array(#""type":"user""#.utf8)
    // `"type":"assistant"` comes after the message body, so match the message role near the start.
    private static let assistantMarker = Array(#""role":"assistant""#.utf8)
    private static let customTitleMarker = Array(#""type":"custom-title""#.utf8)
    private static let aiTitleMarker = Array(#""type":"ai-title""#.utf8)
    private static let lastPromptMarker = Array(#""type":"last-prompt""#.utf8)
    private static let prLinkMarker = Array(#""type":"pr-link""#.utf8)
    private static let frameLinkMarker = Array(#""type":"frame-link""#.utf8)
    private static let costStateMarker = Array(#""type":"cost-state""#.utf8)
    private static let awayMarker = Array(#""subtype":"away_summary""#.utf8)
    private static let turnDurationMarker = Array(#""subtype":"turn_duration""#.utf8)
    private static let isErrorMarker = Array(#""is_error":true"#.utf8)
    private static let toolResultMarker = Array(#""tool_result""#.utf8)
    private static let sidechainMarker = Array(#""isSidechain":true"#.utf8)
    private static let timestampMarker = Array(#""timestamp":""#.utf8)
    private static let textReplyMarker = Array(#""content":[{"type":"text""#.utf8)
    private static let toolUseMarker = Array(#""type":"tool_use""#.utf8)
    private static let modelMarker = Array(#""model":""#.utf8)
    private static let messageIdMarker = Array(#""id":""#.utf8)
    private static let requestIdMarker = Array(#""requestId":""#.utf8)
    private static let usageMarker = Array(#""usage":{"#.utf8)
    private static let filePathMarker = Array(#""file_path":""#.utf8)
    private static let notebookPathMarker = Array(#""notebook_path":""#.utf8)
    private static let editToolMarkers = ["Edit", "Write", "MultiEdit", "NotebookEdit"].map { Array(#""name":"\#($0)""#.utf8) }

    static func parse(_ data: Data, id: String, url: URL, modified: Date) -> Session? {
        var customTitle: String?, aiTitle: String?, lastPromptEntry: String?, recap: String?, lastReply: String?
        var prompts: [String] = []
        var cwd: String?, branch: String?
        var startedAt: Date?, lastActivity: Date?
        var files: [String] = []
        var pullRequests: [String: SessionLink] = [:], artifacts: [String: SessionLink] = [:]
        var linkOrder: [String] = []
        var recordedCost: Double?
        var usage = UsageTally()
        // The current turn: reset by every prompt you type.
        var turnUsage = UsageTally(), turnEdits = 0, turnErrors = 0
        var turnDuration: TimeInterval?, turnStarted: Date?

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var lastReplyLine: UnsafeBufferPointer<UInt8>?
            forEachLine(raw) { line, head in
                if contains(head, customTitleMarker) {
                    if let value = decode(line)?["customTitle"] as? String {
                        // Claude Code writes "Untitled session" as a placeholder before a real title exists.
                        customTitle = value.caseInsensitiveCompare("Untitled session") == .orderedSame
                            ? customTitle : clean(value) ?? customTitle
                    }
                } else if contains(head, aiTitleMarker) {
                    if let value = decode(line)?["aiTitle"] as? String { aiTitle = clean(value) ?? aiTitle }
                } else if contains(head, lastPromptMarker) {
                    if let value = decode(line)?["lastPrompt"] as? String { lastPromptEntry = cleanPrompt(value) ?? lastPromptEntry }
                } else if contains(head, prLinkMarker) {
                    if let entry = decode(line), let link = pullRequestLink(entry) {
                        if pullRequests[link.id] == nil { linkOrder.append(link.id) }
                        pullRequests[link.id] = link
                    }
                } else if contains(head, frameLinkMarker) {
                    if let entry = decode(line), let link = artifactLink(entry) {
                        if artifacts[link.id] == nil { linkOrder.append(link.id) }
                        artifacts[link.id] = link
                    }
                } else if contains(head, costStateMarker) {
                    if let value = decode(line)?["totalCostUSD"] as? Double { recordedCost = max(recordedCost ?? 0, value) }
                } else if contains(head, userMarker) {
                    guard !contains(head, sidechainMarker) else { return }
                    let stamp = timestamp(in: line)
                    if let stamp {
                        startedAt = startedAt ?? stamp
                        lastActivity = stamp
                    }
                    if contains(head, toolResultMarker) {
                        if contains(line, isErrorMarker) { turnErrors += 1 }
                        return
                    }
                    guard line.count <= maxDecodedLine, let entry = decode(line) else { return }
                    if let value = entry["cwd"] as? String, !value.isEmpty { cwd = cwd ?? value }
                    if let value = entry["gitBranch"] as? String, !value.isEmpty, value != "HEAD" { branch = value }
                    if let prompt = humanPrompt(entry) {
                        prompts.append(prompt)
                        turnUsage = UsageTally()
                        turnEdits = 0
                        turnErrors = 0
                        turnDuration = nil
                        turnStarted = stamp
                    }
                } else if contains(head, assistantMarker) {
                    guard !contains(head, sidechainMarker) else { return }
                    if let stamp = timestamp(in: line) { lastActivity = stamp }
                    if let response = usageEntry(line, head: head) {
                        usage.add(key: response.key, model: response.model, usage: response.values)
                        turnUsage.add(key: response.key, model: response.model, usage: response.values)
                    }
                    if contains(head, textReplyMarker) { lastReplyLine = line }
                    if contains(line, toolUseMarker) {
                        let edited = editedFiles(in: line)
                        turnEdits += edited.count
                        for path in edited {
                            files.removeAll { $0 == path }
                            files.insert(path, at: 0)
                        }
                        if files.count > maxFiles { files.removeLast(files.count - maxFiles) }
                    }
                } else if contains(head, turnDurationMarker) {
                    if let ms = decode(line)?["durationMs"] as? NSNumber { turnDuration = ms.doubleValue / 1000 }
                } else if contains(head, awayMarker) {
                    if let value = decode(line)?["content"] as? String {
                        recap = clean(value.replacingOccurrences(of: "(disable recaps in /config)", with: ""))
                    }
                }
            }
            if let line = lastReplyLine, line.count <= maxDecodedLine * 4,
               let content = (decode(line)?["message"] as? [String: Any])?["content"] as? [[String: Any]] {
                let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n")
                lastReply = excerpt(text, limit: 900)
            }
        }

        guard let first = prompts.first else { return nil }
        var elapsed: TimeInterval?
        if let turnStarted, let lastActivity { elapsed = max(0, lastActivity.timeIntervalSince(turnStarted)) }
        let lastTurn = TurnSummary(duration: turnDuration ?? elapsed, edits: turnEdits, errors: turnErrors,
                                   cost: turnUsage.cost)
        let ranked = usage.byModel.sorted { $0.value.output > $1.value.output }.map { ModelCatalog.displayName($0.key) }
        var models: [String] = []
        for name in ranked where !models.contains(name) { models.append(name) }
        let links = linkOrder.reversed().compactMap { pullRequests[$0] }
            + linkOrder.reversed().compactMap { artifacts[$0] }

        return Session(
            id: id,
            title: customTitle ?? aiTitle ?? first,
            firstPrompt: first,
            lastPrompt: lastPromptEntry ?? prompts.last,
            cwd: cwd,
            branch: branch,
            promptCount: prompts.count,
            startedAt: startedAt,
            // File dates are unreliable (Claude Code rewrites old transcripts), so prefer message times.
            lastActivity: lastActivity ?? modified,
            transcriptURL: url,
            recap: recap,
            lastReply: lastReply,
            filesChanged: files,
            links: links,
            tokens: usage.tokens,
            outputTokens: usage.output,
            recordedCost: recordedCost,
            estimatedCost: usage.cost,
            models: models,
            lastTurn: lastTurn
        )
    }

    /// Token usage of every response in a transcript (used for subagent files).
    static func tallyUsage(_ data: Data, into usage: inout UsageTally) {
        data.withUnsafeBytes { raw in
            forEachLine(raw) { line, head in
                guard contains(head, assistantMarker), let response = usageEntry(line, head: head) else { return }
                usage.add(key: response.key, model: response.model, usage: response.values)
            }
        }
    }

    // MARK: Entries

    private static func pullRequestLink(_ entry: [String: Any]) -> SessionLink? {
        guard let string = entry["prUrl"] as? String, let url = URL(string: string) else { return nil }
        let number = (entry["prNumber"] as? NSNumber)?.intValue
        let isGitLab = string.contains("/merge_requests/")
        let label = number.map { isGitLab ? "!\($0)" : "#\($0)" } ?? (isGitLab ? "MR" : "PR")
        let repository = (entry["prRepository"] as? String).map { $0.split(separator: "/").last.map(String.init) ?? $0 }
        let kind = isGitLab ? "Merge request" : "Pull request"
        return SessionLink(kind: .pullRequest, url: url, label: label,
                           detail: [kind + " " + label, repository].compactMap { $0 }.joined(separator: " · "))
    }

    private static func artifactLink(_ entry: [String: Any]) -> SessionLink? {
        guard let string = entry["frameUrl"] as? String, let url = URL(string: string) else { return nil }
        let title = (entry["title"] as? String).flatMap(clean) ?? "Artifact"
        return SessionLink(kind: .artifact, url: url, label: title, detail: "Artifact · \(title)")
    }

    /// A response's model, dedupe key and `usage` block, read from the raw line.
    private static func usageEntry(_ line: UnsafeBufferPointer<UInt8>, head: UnsafeBufferPointer<UInt8>)
        -> (key: String, model: String, values: [String: Any])? {
        guard let model = string(after: modelMarker, in: head),
              let object = objectBytes(afterLast: usageMarker, in: line),
              let values = (try? JSONSerialization.jsonObject(with: object)) as? [String: Any] else { return nil }
        let messageId = string(after: messageIdMarker, in: head) ?? ""
        let requestId = string(after: requestIdMarker, in: line, last: true) ?? ""
        return ("\(messageId)|\(requestId)", model, values)
    }

    private static func editedFiles(in line: UnsafeBufferPointer<UInt8>) -> [String] {
        var paths: [String] = []
        for marker in editToolMarkers {
            var from = 0
            while let index = firstIndex(of: marker, in: line, from: from) {
                from = index + marker.count
                let rest = UnsafeBufferPointer(rebasing: line[from...])
                if let path = string(after: filePathMarker, in: rest) ?? string(after: notebookPathMarker, in: rest),
                   !paths.contains(path) {
                    paths.append(path)
                }
            }
        }
        return paths
    }

    // MARK: Prompts

    /// The text of a prompt the person typed, or nil for tool results, hooks, notifications and meta lines.
    static func humanPrompt(_ entry: [String: Any]) -> String? {
        guard entry["type"] as? String == "user", entry["isMeta"] as? Bool != true,
              entry["isSidechain"] as? Bool != true else { return nil }
        if let kind = (entry["origin"] as? [String: Any])?["kind"] as? String, kind != "human" { return nil }
        guard let message = entry["message"] as? [String: Any] else { return nil }
        let text: String
        if let string = message["content"] as? String {
            text = string
        } else if let parts = message["content"] as? [[String: Any]] {
            guard !parts.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }
            text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: " ")
        } else {
            return nil
        }
        return cleanPrompt(text)
    }

    private static let ignoredPrefixes = [
        "<local-command", "<task-notification", "<system-reminder", "<bash-stdout", "<bash-stderr",
        "Caveat:", "[Request interrupted",
    ]

    /// Turns raw prompt text into a one-line label: slash commands become `/name args`,
    /// pasted blocks collapse to a marker and markup is stripped.
    static func cleanPrompt(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !ignoredPrefixes.contains(where: text.hasPrefix) else { return nil }

        if let name = tag("command-name", in: text) {
            let command = name.hasPrefix("/") ? name : "/" + name
            let args = tag("command-args", in: text) ?? ""
            if ["/clear", "/exit", "/compact", "/resume", "/login", "/logout", "/status", "/cost"].contains(command) {
                return nil
            }
            text = args.isEmpty ? command : "\(command) \(args)"
        }
        text = text.replacingOccurrences(of: #"<pasted_content[^>]*>[\s\S]*?</pasted_content>"#,
                                         with: " [pasted text] ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[Image[^\]]*\]"#, with: " [image] ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"</?[A-Za-z][\w-]*(\s[^>]*)?>"#, with: " ", options: .regularExpression)
        return clean(text)
    }

    /// Collapses whitespace and caps the length.
    static func clean(_ raw: String) -> String? {
        let words = raw.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return nil }
        let text = words.joined(separator: " ")
        return text.count > 400 ? String(text.prefix(400)) + "…" : text
    }

    /// Keeps paragraph breaks (for multi-line previews) but trims Markdown noise and length.
    static func excerpt(_ raw: String, limit: Int) -> String? {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") }
            .map { $0.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression) }
            .map { $0.replacingOccurrences(of: "**", with: "") }
        let text = lines.joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        return text.count > limit ? String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : text
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        let value = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: Bytes

    private static func forEachLine(_ raw: UnsafeRawBufferPointer,
                                    _ body: (UnsafeBufferPointer<UInt8>, UnsafeBufferPointer<UInt8>) -> Void) {
        guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        let count = raw.count
        var start = 0
        while start < count {
            let newline = memchr(base + start, 0x0A, count - start)
            let end = newline.map { start + (UnsafeRawPointer($0) - UnsafeRawPointer(base + start)) } ?? count
            let length = end - start
            if length > 2 {
                body(UnsafeBufferPointer(start: base + start, count: length),
                     UnsafeBufferPointer(start: base + start, count: min(length, headLength)))
            }
            start = end + 1
        }
    }

    private static func decode(_ line: UnsafeBufferPointer<UInt8>) -> [String: Any]? {
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: line.baseAddress!), count: line.count,
                        deallocator: .none)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The entry's own timestamp: the last unescaped `"timestamp":"…"` on the line.
    private static func timestamp(in line: UnsafeBufferPointer<UInt8>) -> Date? {
        string(after: timestampMarker, in: line, last: true).flatMap(parseDate)
    }

    /// The JSON string value following `marker` (which ends with the opening quote).
    private static func string(after marker: [UInt8], in buffer: UnsafeBufferPointer<UInt8>, last: Bool = false) -> String? {
        guard let index = last ? lastIndex(of: marker, in: buffer) : firstIndex(of: marker, in: buffer) else { return nil }
        let from = index + marker.count
        var i = from, escaped = false
        while i < buffer.count {
            let byte = buffer[i]
            if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { break }
            i += 1
        }
        guard i < buffer.count else { return nil }
        let raw = Data([0x22] + buffer[from..<i] + [0x22])
        return (try? JSONSerialization.jsonObject(with: raw, options: .fragmentsAllowed)) as? String
    }

    /// The bytes of the JSON object that follows the last `marker` (which ends with `{`).
    private static func objectBytes(afterLast marker: [UInt8], in line: UnsafeBufferPointer<UInt8>) -> Data? {
        guard let index = lastIndex(of: marker, in: line) else { return nil }
        let start = index + marker.count - 1
        var depth = 0, inString = false, escaped = false
        for i in start..<line.count {
            let byte = line[i]
            if inString {
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                continue
            }
            switch byte {
            case 0x22: inString = true
            case 0x7B: depth += 1
            case 0x7D:
                depth -= 1
                if depth == 0 { return Data(line[start...i]) }
            default: break
            }
        }
        return nil
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()
    private static let dateLock = NSLock()

    static func parseDate(_ string: String) -> Date? {
        dateLock.withLock { fractional.date(from: string) ?? plain.date(from: string) }
    }

    private static func contains(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        firstIndex(of: needle, in: haystack) != nil
    }

    private static func firstIndex(of needle: [UInt8], in haystack: UnsafeBufferPointer<UInt8>, from: Int = 0) -> Int? {
        guard haystack.count - from >= needle.count, let base = haystack.baseAddress else { return nil }
        return needle.withUnsafeBytes { n in
            memmem(base + from, haystack.count - from, n.baseAddress!, needle.count).map {
                UnsafeRawPointer($0) - UnsafeRawPointer(base)
            }
        }
    }

    private static func lastIndex(of needle: [UInt8], in haystack: UnsafeBufferPointer<UInt8>) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        var i = haystack.count - needle.count
        let first = needle[0]
        while i >= 0 {
            if haystack[i] == first {
                var match = true
                for j in 1..<needle.count where haystack[i + j] != needle[j] { match = false; break }
                if match { return i }
            }
            i -= 1
        }
        return nil
    }
}
