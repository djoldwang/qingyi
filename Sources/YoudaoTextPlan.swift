import Foundation
import NaturalLanguage
import CryptoKit

// The public fast service clips input at 600 UTF-16 units. Partition explicitly
// at paragraph/sentence boundaries, retain ordering and protect code literals.
struct YoudaoTextPlan {
    enum Failure: Error { case unsupportedBoundary, changedLiteral }
    struct Piece {
        let source: String
        let prefix: String
        let suffix: String
        var original: String { prefix + source + suffix }
    }
    private struct Literal { let marker: String; let value: String }
    let pieces: [Piece]
    private let literals: [Literal]
    private let originalWords: [String: String]

    init(_ source: String, limit: Int = 600) throws {
        let fullRange = NSRange(source.startIndex..., in: source)
        var ranges: [NSRange] = []
        func collect(_ found: [NSRange]) {
            for range in found where range.length > 0 && !ranges.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                ranges.append(range)
            }
        }
        collect(try NSRegularExpression(pattern: #"(?s)```.*?```|`[^`\r\n]+`"#).matches(in: source, range: fullRange).map(\.range))
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            collect(detector.matches(in: source, range: fullRange).map(\.range))
        }
        for pattern in [#"\b[A-Z][A-Z0-9]*(?:[-_.][A-Z0-9]+)+\b"#,
                        #"(?<![A-Za-z0-9_])[vV]?\d+(?:\.\d+)+(?:[-+][A-Za-z0-9.]+)?"#] {
            collect(try NSRegularExpression(pattern: pattern).matches(in: source, range: fullRange).map(\.range))
        }
        // Stable markers let repeated originals reuse the provider's result
        // cache. Task/run IDs and echoed input still isolate late responses.
        var nonce = "QY" + SHA256.hash(data: Data(source.utf8)).prefix(4).map { String(format: "%02X", $0) }.joined()
        while source.localizedCaseInsensitiveContains(nonce) {
            nonce = "QY" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).uppercased()
        }
        let bindings = ranges.sorted { $0.location < $1.location }.enumerated().map { index, range in
            Literal(marker: nonce + "X\(index)QY", value: (source as NSString).substring(with: range))
        }
        var masked = source
        for (range, literal) in zip(ranges.sorted { $0.location < $1.location }, bindings).reversed() {
            masked = (masked as NSString).replacingCharacters(in: range, with: literal.marker)
        }
        literals = bindings
        let words = try NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9_]*"#).matches(in: source, range: fullRange)
        var spellings: [String: Set<String>] = [:]
        for word in words {
            let spelling = (source as NSString).substring(with: word.range)
            spellings[spelling.lowercased(), default: []].insert(spelling)
        }
        originalWords = spellings.compactMapValues { $0.count == 1 ? $0.first : nil }
        masked = masked.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        pieces = try Self.partition(masked, limit: limit)
        guard !pieces.isEmpty, pieces.map(\.original).joined() == masked else { throw Failure.unsupportedBoundary }
    }

    private static func partition(_ source: String, limit: Int) throws -> [Piece] {
        var raw: [String] = []
        let lines = source.components(separatedBy: "\n")
        for (lineNumber, line) in lines.enumerated() {
            var start = line.startIndex
            let sentences = NLTokenizer(unit: .sentence)
            sentences.string = line
            var ends: [String.Index] = []
            sentences.enumerateTokens(in: line.startIndex..<line.endIndex) { range, _ in ends.append(range.upperBound); return true }
            while line[start...].utf16.count > limit {
                var end = start, count = 0
                while end < line.endIndex, count + line[end].utf16.count <= limit {
                    count += line[end].utf16.count; end = line.index(after: end)
                }
                let cut: String.Index
                if let sentence = ends.last(where: { $0 > start && $0 <= end }) { cut = sentence }
                else if let space = line[start..<end].lastIndex(where: \.isWhitespace),
                        !TextPolicy.clean(String(line[start..<space])).isEmpty { cut = line.index(after: space) }
                else { throw Failure.unsupportedBoundary }
                raw.append(String(line[start..<cut])); start = cut
            }
            raw.append(String(line[start...]) + (lineNumber < lines.count - 1 ? "\n" : ""))
        }
        // Pack small adjacent paragraphs into one bounded request while retaining
        // their delimiters. Every request still has the full text of its pieces.
        var packed: [String] = []
        for part in raw {
            if let last = packed.last, TextPolicy.clean(last + part).utf16.count <= limit { packed[packed.count - 1] = last + part }
            else { packed.append(part) }
        }
        return try packed.map { text in
            guard let first = text.firstIndex(where: { !$0.isWhitespace }),
                  let last = text.lastIndex(where: { !$0.isWhitespace }) else { throw Failure.unsupportedBoundary }
            let end = text.index(after: last)
            let core = String(text[first..<end])
            guard core.utf16.count <= limit else { throw Failure.unsupportedBoundary }
            return Piece(source: core, prefix: String(text[..<first]), suffix: String(text[end...]))
        }
    }

    func render(_ translation: String, for index: Int) throws -> String {
        var text = translation
        let piece = pieces[index]
        for literal in literals {
            let expected = piece.source.contains(literal.marker)
            let found = text.range(of: literal.marker, options: .caseInsensitive)
            guard expected == (found != nil) else { throw Failure.changedLiteral }
            if let found {
                guard text.range(of: literal.marker, options: .caseInsensitive, range: found.upperBound..<text.endIndex) == nil else { throw Failure.changedLiteral }
                text.replaceSubrange(found, with: literal.value)
            }
        }
        // Restore the spelling of untranslated ASCII terms (e.g. a command
        // capitalized at the beginning of a sentence) without changing Chinese.
        let words = try NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9_]*"#)
        for match in words.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let spelling = (text as NSString).substring(with: match.range)
            if let original = originalWords[spelling.lowercased()] {
                text = (text as NSString).replacingCharacters(in: match.range, with: original)
            }
        }
        return piece.prefix + text + piece.suffix
    }
}
