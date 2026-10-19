import Foundation

/// Ranks sessions against a query. Every word has to match somewhere; a word matches the title
/// exactly, at a word start, or loosely as a subsequence (`frmw` → "Firmware"), and the other
/// fields (folder, branch, prompts, recap, links, files, id) by substring. Matching ignores case
/// and accents, and treats Turkish `ı`/`İ` as `i`, so `calis` finds "çalışıyor".
enum Search {
    struct Match {
        let score: Double
        /// Matched character ranges in the title, for highlighting.
        let titleRanges: [Range<String.Index>]
    }

    static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }.filter { !$0.isEmpty }
    }

    static func match(_ session: Session, terms: [String]) -> Match? {
        guard !terms.isEmpty else { return Match(score: 0, titleRanges: []) }
        var score = 0.0
        var ranges: [Range<String.Index>] = []
        let title = Folded(session.title)
        let near = fold([session.folderName, session.branch].compactMap { $0 }.joined(separator: " "))
        var far: String?
        // Folding prompts and the recap is the expensive part, so only do it when a term needs it.
        func inFar(_ term: String) -> Bool {
            if far == nil { far = fold(haystack(session)) }
            return far!.contains(term)
        }

        for term in terms {
            let needle = Array(term)
            if let hit = title.firstRange(of: needle) {
                score += title.isWordStart(hit.lowerBound) ? 100 : 70
                ranges.append(title.range(hit))
            } else if let fuzzy = title.fuzzy(needle) {
                score += 40 * fuzzy.tightness
                ranges += fuzzy.positions.map { title.range($0..<$0 + 1) }
            } else if near.contains(term) {
                score += 50
            } else if inFar(term) {
                score += 15
            } else {
                return nil
            }
        }
        return Match(score: score, titleRanges: merge(ranges))
    }

    /// Everything searchable besides the title, folder and branch.
    static func haystack(_ session: Session) -> String {
        var parts = [session.firstPrompt, session.lastPrompt, session.recap, session.cwd, session.id,
                     session.profile.isPersonal ? nil : session.profile.name].compactMap { $0 }
        parts += session.links.map(\.detail)
        parts += session.filesChanged.map { URL(fileURLWithPath: $0).lastPathComponent }
        return parts.joined(separator: "\n")
    }

    /// Loose match of `term` in `text`, for tests and callers outside `match`.
    static func fuzzyRanges(_ term: String, in text: String) -> (ranges: [Range<String.Index>], tightness: Double)? {
        let folded = Folded(text)
        guard let hit = folded.fuzzy(Array(fold(term))) else { return nil }
        return (hit.positions.map { folded.range($0..<$0 + 1) }, hit.tightness)
    }

    static func fold(_ text: String) -> String {
        text.replacingOccurrences(of: "ı", with: "i").replacingOccurrences(of: "İ", with: "i")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// A string folded one character at a time, so positions map back to the original for highlighting.
    private struct Folded {
        let original: String
        let indices: [String.Index]
        let characters: [Character]

        init(_ text: String) {
            original = text
            indices = Array(text.indices)
            characters = text.map { Search.fold(String($0)).first ?? $0 }
        }

        func range(_ positions: Range<Int>) -> Range<String.Index> {
            let upper = positions.upperBound < indices.count ? indices[positions.upperBound] : original.endIndex
            return indices[positions.lowerBound]..<upper
        }

        func isWordStart(_ position: Int) -> Bool {
            position == 0 || !characters[position - 1].isLetter
        }

        func firstRange(of needle: [Character]) -> Range<Int>? {
            guard !needle.isEmpty, needle.count <= characters.count else { return nil }
            for start in 0...(characters.count - needle.count)
            where characters[start] == needle[0] && Array(characters[start..<start + needle.count]) == needle {
                return start..<start + needle.count
            }
            return nil
        }

        /// The tightest in-order match of `needle`. Only accepts matches spanning at most twice
        /// the needle's length, and rates tighter ones higher.
        func fuzzy(_ needle: [Character]) -> (positions: [Int], tightness: Double)? {
            guard needle.count >= 3 else { return nil }
            var best: (positions: [Int], span: Int)?
            for start in characters.indices where characters[start] == needle[0] {
                var positions = [start]
                var i = start + 1, n = 1
                while n < needle.count, i < characters.count {
                    if characters[i] == needle[n] { positions.append(i); n += 1 }
                    i += 1
                }
                // From later starts there are fewer characters left, so they can't match either.
                guard n == needle.count else { break }
                let span = i - start
                if span <= needle.count * 2, span < (best?.span ?? .max) { best = (positions, span) }
            }
            return best.map { ($0.positions, Double(needle.count) / Double($0.span)) }
        }
    }

    /// Sorts and joins adjacent or overlapping ranges.
    private static func merge(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
