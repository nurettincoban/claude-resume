import Foundation

/// The only write ClaudeResume makes to a transcript: the same `custom-title` line `/rename` appends.
enum TranscriptWriter {
    static func appendTitle(_ title: String, sessionId: String, to url: URL) throws {
        let entry: [String: Any] = ["type": "custom-title", "customTitle": title, "sessionId": sessionId]
        var line = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes])
        line.append(0x0A)

        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if handle.readData(ofLength: 1) != Data([0x0A]) { line.insert(0x0A, at: 0) }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: line)
    }
}
