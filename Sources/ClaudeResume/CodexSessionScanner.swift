import Foundation

/// Reads Codex rollouts from `<CODEX_HOME>/sessions`, both legacy and paginated event formats.
/// Titles come from `session_index.jsonl`. No authentication files are opened.
final class CodexSessionScanner {
    private let profile: AgentProfile
    private var cache: [String: (size: Int, modified: Date, session: Session?)] = [:]

    init(profile: AgentProfile) { self.profile = profile }

    func scan() -> [Session] {
        let root = profile.directory.appendingPathComponent("sessions", isDirectory: true)
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                         options: [.skipsHiddenFiles]) else { return [] }
        var result: [Session] = [], seen = Set<String>()
        let titles = readTitles()
        for case let url as URL in files where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0, modified = values.contentModificationDate ?? .distantPast
            seen.insert(url.path)
            let parsed: Session?
            if let hit = cache[url.path], hit.size == size, hit.modified == modified {
                parsed = hit.session
            } else {
                parsed = (try? Data(contentsOf: url, options: .alwaysMapped)).flatMap {
                    CodexTranscriptParser.parse($0, profile: profile, url: url, modified: modified)
                }
                cache[url.path] = (size, modified, parsed)
            }
            if var session = parsed {
                if let title = titles[session.id] { session.title = title }
                result.append(session)
            }
        }
        cache = cache.filter { seen.contains($0.key) }
        return result.sorted { $0.lastActivity > $1.lastActivity }
    }

    private func readTitles() -> [String: String] {
        guard let data = try? Data(contentsOf: profile.directory.appendingPathComponent("session_index.jsonl"), options: .alwaysMapped)
        else { return [:] }
        var titles: [String: String] = [:]
        data.withUnsafeBytes { raw in
            TranscriptParser.forEachLine(raw) { line, _ in
                guard line.count < 128 * 1024, let entry = TranscriptParser.decode(line),
                      let id = entry["id"] as? String,
                      let title = (entry["thread_name"] as? String ?? entry["name"] as? String).flatMap(TranscriptParser.clean)
                else { return }
                titles[id] = title
            }
        }
        return titles
    }
}

enum CodexTranscriptParser {
    private static let eventNames = ["user_message", "agent_message", "item_completed", "task_complete", "token_count"]
    private static let itemNames = ["UserMessage", "AgentMessage", "FileChange", "userMessage", "agentMessage", "fileChange"]
    private static let primary = ["session_meta", "turn_context", "token_usage_record", "compacted"]
    private static let completedMarkers = [Array(#""type":"item_completed""#.utf8), Array(#""type": "item_completed""#.utf8)]
    private static let itemMarkers = itemNames.flatMap { [Array("\"type\":\"\($0)\"".utf8), Array("\"type\": \"\($0)\"".utf8)] }
    private static let markers = (eventNames + itemNames + primary + ["message"]).flatMap {
        [Array("\"type\":\"\($0)\"".utf8), Array("\"type\": \"\($0)\"".utf8)]
    }
    private static let linksPattern = try! NSRegularExpression(pattern: #"https?://[^\s<>\[\]()\"']+/(?:pull|merge_requests)/\d+"#)

    static func parse(_ data: Data, profile: AgentProfile, url: URL, modified: Date) -> Session? {
        var id: String?, resumeID: String?, cwd: String?, branch: String?, title: String?
        var created: Date?, activity: Date?, lastReply: String?, recap: String?
        var prompts: [String] = [], legacyPrompts: [String] = [], fallbackPrompts: [String] = [], files: [String] = [], models: [String] = []
        var tokens = 0, outputTokens = 0, seenItems = Set<String>(), rejected = false
        var links: [SessionLink] = []

        func addLinks(_ text: String) {
            let range = NSRange(text.startIndex..., in: text)
            for match in linksPattern.matches(in: text, range: range).prefix(20) {
                guard let range = Range(match.range, in: text), let url = URL(string: String(text[range])),
                      !links.contains(where: { $0.url == url }) else { continue }
                let number = url.lastPathComponent
                links.append(SessionLink(kind: .pullRequest, url: url, label: "#" + number, detail: "Pull request #" + number))
            }
        }
        func addPrompt(_ text: String) {
            guard let prompt = cleanPrompt(text) else { return }
            prompts.append(prompt); addLinks(text)
        }
        func addItem(_ item: [String: Any]) {
            if let itemID = item["id"] as? String, !seenItems.insert(itemID).inserted { return }
            switch (item["type"] as? String ?? "").lowercased() {
            case "usermessage": addPrompt(text(item["content"]))
            case "agentmessage":
                let value = item["text"] as? String ?? text(item["content"])
                if let value = TranscriptParser.excerpt(value, limit: 900) { lastReply = value; addLinks(value) }
            case "filechange":
                let paths = (item["changes"] as? [[String: Any]])?.compactMap { $0["path"] as? String }
                    ?? (item["changes"] as? [String: Any]).map { Array($0.keys) } ?? []
                for path in paths { files.removeAll { $0 == path }; files.insert(path, at: 0) }
                files = Array(files.prefix(40))
            default: break
            }
        }
        func addUsage(_ usage: [String: Any]) {
            let input = usage["input_tokens"] as? Int ?? 0, output = usage["output_tokens"] as? Int ?? 0
            tokens = max(tokens, usage["total_tokens"] as? Int ?? input + output)
            outputTokens = max(outputTokens, output)
        }

        data.withUnsafeBytes { raw in
            TranscriptParser.forEachLine(raw) { line, head in
                if completedMarkers.contains(where: { TranscriptParser.contains(head, $0) }),
                   !itemMarkers.contains(where: { TranscriptParser.contains(head, $0) }) { return }
                guard !rejected, line.count <= 2 * 1024 * 1024,
                      markers.contains(where: { TranscriptParser.contains(head, $0) }),
                      let entry = TranscriptParser.decode(line), let payload = entry["payload"] as? [String: Any] else { return }
                let stamp = (entry["timestamp"] as? String).flatMap(TranscriptParser.parseDate)
                switch entry["type"] as? String {
                case "session_meta":
                    if let source = payload["source"] as? [String: Any], source.keys.contains(where: { $0.lowercased().contains("subagent") }) { rejected = true; return }
                    if let source = payload["source"] as? String, source.lowercased().hasPrefix("subagent") { rejected = true; return }
                    id = payload["id"] as? String
                    resumeID = payload["session_id"] as? String
                    cwd = payload["cwd"] as? String
                    branch = (payload["git"] as? [String: Any])?["branch"] as? String
                    title = payload["name"] as? String
                    created = (payload["timestamp"] as? String).flatMap(TranscriptParser.parseDate) ?? stamp
                case "turn_context":
                    if let model = payload["model"] as? String, !models.contains(model) { models.insert(model, at: 0) }
                case "token_usage_record":
                    if let usage = payload["thread_token_usage"] as? [String: Any] { addUsage(usage) }
                case "compacted": recap = (payload["message"] as? String).flatMap { TranscriptParser.excerpt($0, limit: 900) }
                case "event_msg":
                    switch payload["type"] as? String {
                    case "user_message":
                        if let value = cleanPrompt(payload["message"] as? String ?? "") { legacyPrompts.append(value); addLinks(value) }
                        activity = stamp ?? activity
                    case "agent_message":
                        let value = payload["message"] as? String ?? ""
                        lastReply = TranscriptParser.excerpt(value, limit: 900); addLinks(value); activity = stamp ?? activity
                    case "item_completed":
                        if let item = payload["item"] as? [String: Any] { addItem(item); activity = stamp ?? activity }
                    case "task_complete":
                        if let value = payload["last_agent_message"] as? String, !value.isEmpty {
                            lastReply = TranscriptParser.excerpt(value, limit: 900); addLinks(value)
                        }
                        activity = stamp ?? activity
                    case "token_count":
                        if let usage = (payload["info"] as? [String: Any])?["total_token_usage"] as? [String: Any] { addUsage(usage) }
                    default: break
                    }
                case "response_item" where payload["type"] as? String == "message":
                    let value = text(payload["content"])
                    if payload["role"] as? String == "user", let value = cleanPrompt(value) { fallbackPrompts.append(value) }
                    if payload["role"] as? String == "assistant", payload["phase"] as? String == "final_answer" {
                        lastReply = TranscriptParser.excerpt(value, limit: 900)
                    }
                default: break
                }
            }
        }
        if prompts.isEmpty { prompts = legacyPrompts.isEmpty ? fallbackPrompts : legacyPrompts }
        guard !rejected, let id, let first = prompts.first else { return nil }
        return Session(id: id, title: title.flatMap(TranscriptParser.clean) ?? first,
                       firstPrompt: first, lastPrompt: prompts.last, cwd: cwd, branch: branch,
                       promptCount: prompts.count, startedAt: created, lastActivity: activity ?? created ?? modified,
                       transcriptURL: url, recap: recap, lastReply: lastReply, filesChanged: files,
                       links: Array(links.suffix(30).reversed()), tokens: tokens, outputTokens: outputTokens,
                       models: models, profile: profile, resumeID: resumeID)
    }

    static func text(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? [String] { return value.joined(separator: "\n") }
        guard let parts = value as? [[String: Any]] else { return "" }
        return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    static func cleanPrompt(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = value.range(of: "</environment_context>"), value.hasPrefix("<environment_context>") {
            value = String(value[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !["# AGENTS.md", "<INSTRUCTIONS>", "<permissions instructions>", "<system-reminder>"].contains(where: value.hasPrefix)
        else { return nil }
        return TranscriptParser.clean(value)
    }
}
