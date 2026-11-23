import Foundation
import Combine

enum TranslationServiceID: String, Codable, CaseIterable, Identifiable {
    case youdao, google, ai
    var id: String { rawValue }
    var name: String {
        switch self { case .youdao: return "有道翻译"; case .google: return "谷歌翻译"; case .ai: return "AI 翻译" }
    }
    var mark: String { switch self { case .youdao: return "有"; case .google: return "G"; case .ai: return "AI" } }
}

@MainActor
final class BuiltinTranslationSettings: ObservableObject {
    private let defaults: UserDefaults
    @Published var youdao: Bool { didSet { defaults.set(youdao, forKey: "translation.youdao") } }
    @Published var google: Bool { didSet { defaults.set(google, forKey: "translation.google") } }
    @Published var ai: Bool { didSet { defaults.set(ai, forKey: "translation.ai") } }
    @Published private(set) var order: [TranslationServiceID]
    init(defaults: UserDefaults = .standard, enabledByDefault: Bool = true) {
        self.defaults = defaults
        youdao = defaults.object(forKey: "translation.youdao") as? Bool ?? enabledByDefault
        google = defaults.object(forKey: "translation.google") as? Bool ?? enabledByDefault
        ai = defaults.object(forKey: "translation.ai") as? Bool ?? true
        order = Self.normalized(defaults.stringArray(forKey: "translation.order") ?? [])
    }
    static func normalized(_ values: [String]) -> [TranslationServiceID] {
        var result: [TranslationServiceID] = []
        for value in values.compactMap(TranslationServiceID.init(rawValue:)) + TranslationServiceID.allCases where !result.contains(value) { result.append(value) }
        return result
    }
    func enabled(_ id: TranslationServiceID) -> Bool {
        switch id { case .youdao: return youdao; case .google: return google; case .ai: return ai }
    }
    func move(_ id: TranslationServiceID, before target: TranslationServiceID) {
        guard id != target, let index = order.firstIndex(of: id), order.contains(target) else { return }
        var next = order; next.remove(at: index); next.insert(id, at: next.firstIndex(of: target)!)
        order = next; defaults.set(next.map(\.rawValue), forKey: "translation.order")
    }
    func move(_ id: TranslationServiceID, to target: TranslationServiceID) {
        guard id != target, let sourceIndex = order.firstIndex(of: id), let targetIndex = order.firstIndex(of: target) else { return }
        var next = order
        next.remove(at: sourceIndex)
        next.insert(id, at: targetIndex)
        order = next
        defaults.set(next.map(\.rawValue), forKey: "translation.order")
    }
    func move(_ id: TranslationServiceID, offset: Int) {
        guard let index = order.firstIndex(of: id), order.indices.contains(index + offset) else { return }
        var next = order; next.swapAt(index, index + offset)
        order = next; defaults.set(next.map(\.rawValue), forKey: "translation.order")
    }
}

struct DictionaryMeaning: Equatable {
    let part: String
    let text: String
}
struct BuiltinTranslationResult: Equatable {
    var text: String
    var phonetics: [String] = []
    var meanings: [DictionaryMeaning] = []
    var copyText: String {
        meanings.isEmpty ? text : meanings.map { [$0.part, $0.text].filter { !$0.isEmpty }.joined(separator: " ") }.joined(separator: "\n")
    }
}

final class BuiltinTranslationClient {
    private let session: URLSession
    private let canPrepareYoudao: Bool
    @MainActor private var preparation: (UUID, Task<Void, Never>)?
    private let google: GoogleWebTranslation
    private let youdao: @MainActor (String, @escaping @MainActor (String) -> Void) async throws -> BuiltinTranslationResult

    init(session: URLSession = HTTP.session(),
         youdao: (@MainActor (String) async throws -> BuiltinTranslationResult)? = nil) {
        self.session = session
        canPrepareYoudao = youdao == nil
        google = GoogleWebTranslation(session: session)
        let client = YoudaoTranslation(session: session)
        if let youdao { self.youdao = { text, _ in try await youdao(text) } }
        else { self.youdao = { text, update in try await client.translate(text, onUpdate: update) } }
    }

    @MainActor func prepareYoudaoConnection() {
        guard canPrepareYoudao, preparation == nil else { return }
        let id = UUID()
        let task = Task { [session, weak self] in
            defer { if self?.preparation?.0 == id { self?.preparation = nil } }
            // Resolve DNS and negotiate TLS while the app is becoming ready.
            // No original, query, cookie or credential is sent by this request.
            var request = URLRequest(url: URL(string: "https://dict.youdao.com/")!, timeoutInterval: 3)
            request.httpMethod = "HEAD"
            _ = try? await session.data(for: request)
        }
        preparation = (id, task)
    }
    @MainActor func cancelYoudaoPreparation() {
        preparation?.1.cancel(); preparation = nil
    }

    static func isEnglishWord(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z]+(?:['’-][A-Za-z]+)*$"#, options: .regularExpression) != nil
    }
    func translate(_ text: String, service: TranslationServiceID,
                   onUpdate: @escaping @MainActor (String) -> Void = { _ in }) async throws -> BuiltinTranslationResult {
        try Task.checkCancellation()
        let input = try TextPolicy.validate(text)
        guard input.count <= 5_000 else { throw QingyiError.message("该服务单次最多翻译 5,000 字，请缩小选区。") }
        switch service {
        case .google: return try await google.translate(input)
        case .youdao: return try await youdao(input, onUpdate)
        case .ai: throw QingyiError.message("请选择 AI 翻译模型。")
        }
    }
}
