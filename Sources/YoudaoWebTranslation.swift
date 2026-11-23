import WebKit

/// Each request owns its page so a late edit or DOM update cannot cross selections.
@MainActor
final class YoudaoWebTranslation: NSObject, WKNavigationDelegate {
    private let web: WKWebView
    private let url: URL
    private var completion: CheckedContinuation<BuiltinTranslationResult, Error>?
    private var reader: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    private init(url: URL) {
        self.url = url
        let configuration = WKWebViewConfiguration()
        // Keep the website from restoring an earlier selection from its own history.
        configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        super.init()
        web.navigationDelegate = self
    }

    static func translate(_ source: String) async throws -> BuiltinTranslationResult {
        if BuiltinTranslationClient.isEnglishWord(source), source.count <= 128 {
            var address = URLComponents(string: "https://dict.youdao.com/result")!
            address.queryItems = [URLQueryItem(name: "word", value: source), URLQueryItem(name: "lang", value: "en")]
            if let url = address.url {
                do {
                    return try await Self(url: url).read(source: source, script: dictionary, seconds: 10)
                } catch {
                    try Task.checkCancellation()
                }
            }
        }
        let page = Self(url: URL(string: "https://fanyi.youdao.com/index.html#/TextTranslate")!)
        return try await page.read(source: source, script: translation, seconds: 25)
    }

    private func read(source: String, script: String, seconds: Int) async throws -> BuiltinTranslationResult {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                web.load(URLRequest(url: url))
                timer = Task {
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    finish(.failure(QingyiError.message("有道网页未能及时返回完整译文，请稍后重试。")))
                }
                reader = Task {
                    do {
                        while !Task.isCancelled {
                            try await Task.sleep(for: .milliseconds(250))
                            guard web.url?.host == url.host else { continue }
                            let raw = try await web.callAsyncJavaScript(script, arguments: ["source": source], in: nil, contentWorld: .defaultClient)
                            if let value = Self.result(from: raw) {
                                finish(.success(value))
                                return
                            }
                        }
                    } catch { finish(.failure(error)) }
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<BuiltinTranslationResult, Error>) {
        guard let continuation = completion else { return }
        completion = nil
        reader?.cancel()
        timer?.cancel()
        reader = nil
        timer = nil
        web.navigationDelegate = nil
        web.stopLoading()
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
        let target = action.request.url
        let allowed = action.targetFrame != nil && target?.scheme == "https" && target?.host == url.host
        decisionHandler(allowed ? .allow : .cancel)
        if !allowed && action.targetFrame?.isMainFrame == true {
            finish(.failure(QingyiError.message("有道网页要求跳转，请稍后重试。")))
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(QingyiError.message("有道网页已停止响应，请重试。")))
    }

    static func result(from raw: Any?) -> BuiltinTranslationResult? {
        guard let fields = raw as? [String: Any] else { return nil }
        let text = (fields["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = fields["meanings"] as? [[String: String]] ?? []
        let meanings = rows.compactMap { row -> DictionaryMeaning? in
            guard let meaning = row["text"], !meaning.isEmpty else { return nil }
            return DictionaryMeaning(part: row["part"] ?? "", text: meaning)
        }
        guard !text.isEmpty || !meanings.isEmpty else { return nil }
        return BuiltinTranslationResult(text: text, phonetics: fields["phonetics"] as? [String] ?? [], meanings: meanings)
    }

    // Only read the dictionary entry for the submitted word, never examples or AI commentary.
    private static let dictionary = #"""
        if (location.origin !== 'https://dict.youdao.com') return null;
        const text = el => (el?.innerText || '').trim();
        if ((document.querySelector('.word-head .title')?.firstChild?.textContent || '').trim().toLowerCase() !== source.toLowerCase()) return null;
        return {
            phonetics: Array.from(document.querySelectorAll('.per-phone')).map(el =>
                [text(el.querySelector('span')), text(el.querySelector('.phonetic'))].filter(Boolean).join(' ')),
            meanings: Array.from(document.querySelectorAll('.word-exp > .trans')).map(el =>
                ({part: text(el.parentElement.querySelector('.pos')), text: text(el)}))
        };
        """#

    // Non-English pairs show their completion action in the target toolbar instead of the result group.
    static let translation = #"""
        if (location.origin !== 'https://fanyi.youdao.com') return null;
        const input = document.querySelector('#js_fanyi_input');
        if (!input) return null;
        if (!window.qingyiSubmitted) {
            input.focus();
            input.innerText = source;
            input.dispatchEvent(new InputEvent('input', {bubbles: true, inputType: 'insertText', data: source}));
            window.qingyiSubmitted = true;
            return null;
        }
        const normalize = text => text.trim().replace(/\s+/g, ' ');
        if (normalize(input.innerText) !== normalize(source)) return null;
        const output = document.querySelector('#js_fanyi_output');
        const group = output?.querySelector('.original-translation') || output?.querySelector('.current-translation');
        if (!group || group.querySelector('.parallel-comparison-loading, [aria-busy="true"]')) return null;
        const result = group.querySelector('.resultOutput');
        const text = result?.innerText.trim();
        if (!text) return null;
        if (group.querySelector('.translation-copy-button, .alternate-translation-button[aria-busy="false"]')) return {text};
        const pair = document.querySelector('.lang-text-ai')?.innerText.match(/^检测到(.+?)\s*[-→]\s*中文/);
        if (!pair || ['英语', '英文'].includes(pair[1].trim())) return null;
        const copy = output.closest('.target')?.querySelector('.targetAction .ic_translate_copy');
        const sentences = Array.from(result.querySelectorAll('p.tgt.un-step-trans > span.tgt'));
        return copy?.getClientRects().length && sentences.length && sentences.every(el => el.innerText.trim()) ? {text} : null;
        """#
}
