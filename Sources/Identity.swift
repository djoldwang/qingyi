import Foundation
import CryptoKit
import Security
import Network

struct VerifiedIdentity { let subject: String; let email: String }

enum IdentityValidator {
    static func verify(_ token: String, clientID: String, nonce: String, jwks: Data, now: Date = Date()) throws -> VerifiedIdentity {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let headerData = Data(base64URL: String(parts[0])), let claimsData = Data(base64URL: String(parts[1])), let signature = Data(base64URL: String(parts[2])),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try JSONSerialization.jsonObject(with: claimsData) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String,
              let document = try JSONSerialization.jsonObject(with: jwks) as? [String: Any],
              let keys = document["keys"] as? [[String: Any]],
              let jwk = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" && ($0["use"] as? String ?? "sig") == "sig" && ($0["alg"] as? String ?? "RS256") == "RS256" }),
              let nString = jwk["n"] as? String, let eString = jwk["e"] as? String,
              let n = Data(base64URL: nString), let e = Data(base64URL: eString) else { throw QingyiError.message("登录身份签名格式无效。") }
        let publicData = derSequence(derInteger(n) + derInteger(e))
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(publicData as CFData, attributes as CFDictionary, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data("\(parts[0]).\(parts[1])".utf8) as CFData, signature as CFData, nil) else { throw QingyiError.message("登录身份签名验证失败。") }
        let audienceMatches = claims["aud"] as? String == clientID || (claims["aud"] as? [String] ?? []).contains(clientID)
        guard claims["iss"] as? String == "https://auth.openai.com", audienceMatches,
              let expires = claims["exp"] as? Double, expires > now.timeIntervalSince1970,
              claims["nonce"] as? String == nonce,
              let subject = claims["sub"] as? String, !subject.isEmpty else { throw QingyiError.message("登录身份校验失败或已过期，请重新登录。") }
        if let issued = claims["iat"] as? Double, issued > now.timeIntervalSince1970 + 60 { throw QingyiError.message("登录凭据时间无效，请检查系统时间。") }
        if let audiences = claims["aud"] as? [String], audiences.count > 1, claims["azp"] as? String != clientID { throw QingyiError.message("登录授权方不匹配。") }
        return VerifiedIdentity(subject: subject, email: claims["email"] as? String ?? "ChatGPT 账号")
    }
    private static func derLength(_ value: Int) -> Data {
        if value < 128 { return Data([UInt8(value)]) }
        var number = value; var bytes: [UInt8] = []
        while number > 0 { bytes.insert(UInt8(number & 255), at: 0); number >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
    private static func derInteger(_ data: Data) -> Data {
        var value = Data(data.drop(while: { $0 == 0 }))
        if value.isEmpty { value = Data([0]) }
        if value.first! & 0x80 != 0 { value.insert(0, at: 0) }
        return Data([0x02]) + derLength(value.count) + value
    }
    private static func derSequence(_ data: Data) -> Data { Data([0x30]) + derLength(data.count) + data }
}

enum CallbackParser {
    static func parse(_ target: String, expectedState: String, existingClient: String?) throws -> (code: String, client: String) {
        guard let url = URLComponents(string: "http://127.0.0.1" + target), url.path == "/auth/callback" else { throw QingyiError.message("登录回调路径无效。") }
        var fields: [String: String] = [:]
        for item in url.queryItems ?? [] {
            guard fields[item.name] == nil else { throw QingyiError.message("登录回调包含重复参数。") }
            fields[item.name] = item.value ?? ""
        }
        guard fields["state"] == expectedState else { throw QingyiError.message("登录回调校验失败，请重新登录。") }
        if fields["error"] != nil { throw QingyiError.message("未完成 ChatGPT 授权。请重新登录并允许轻译使用订阅额度。") }
        let client = fields["client_id"] ?? existingClient ?? ""
        guard !client.isEmpty, client != "dynamic_agent_client", existingClient == nil || client == existingClient,
              let code = fields["code"], !code.isEmpty else { throw QingyiError.message("登录回调缺少有效的授权码或客户端编号。") }
        return (code, client)
    }
}

// This page acknowledges the callback only. Token exchange and identity
// verification continue in the app after the browser receives the response.
enum OAuthCallbackPage: String, CaseIterable {
    case received, failed, notFound

    var title: String {
        switch self {
        case .received: return "授权信息已接收"
        case .failed: return "授权未完成"
        case .notFound: return "页面不存在"
        }
    }
    var message: String {
        switch self {
        case .received: return "请返回轻译查看登录结果。"
        case .failed: return "请返回轻译重新尝试。"
        case .notFound: return "请从轻译重新发起授权。"
        }
    }
    var httpStatus: String {
        switch self {
        case .received: return "200 OK"
        case .failed: return "400 Bad Request"
        case .notFound: return "404 Not Found"
        }
    }
    var html: String {
        """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="referrer" content="no-referrer">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
          <title>\(title) · 轻译</title>
          <style>
            :root {
              color-scheme: light dark;
              --page: #f6f7fb; --card: #ffffff; --ink: #252735;
              --body: #666b7b; --muted: #8a8f9e; --line: #eceef5;
              --accent: #6863d9; --accent-soft: #f0eefc;
              --warning: #a87527; --warning-soft: #fbf2e2;
              --neutral: #7b8192; --neutral-soft: #f0f2f6;
              --shadow: 0 16px 56px rgba(37, 39, 74, .065), 0 2px 8px rgba(37, 39, 74, .025);
            }
            * { box-sizing: border-box; }
            body {
              margin: 0; min-height: 100vh; min-height: 100svh;
              display: grid; place-items: center; padding: 32px 20px;
              background: var(--page); color: var(--ink);
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", sans-serif;
              -webkit-font-smoothing: antialiased;
            }
            .card {
              width: 100%; max-width: 440px; padding: 40px;
              background: var(--card); border: 1px solid var(--line);
              border-radius: 24px; box-shadow: var(--shadow); text-align: center;
            }
            .brand { display: flex; align-items: center; justify-content: center; gap: 12px; }
            .brand-mark {
              position: relative; display: grid; place-items: center;
              width: 44px; height: 44px; border-radius: 12px;
              background: linear-gradient(150deg, #777bf5, #5256ce);
              color: white; font-size: 28px; font-weight: 600; line-height: 1;
              box-shadow: 0 3px 8px rgba(86, 83, 200, .13);
            }
            .brand-mark::after {
              content: ""; position: absolute; top: 7px; right: 7px;
              width: 3px; height: 3px; border-radius: 50%; background: #c7f1df;
            }
            .brand-name { font-size: 22px; font-weight: 600; letter-spacing: .06em; }
            .status-icon {
              position: relative; width: 56px; height: 56px; margin: 36px auto 24px;
              border-radius: 50%; color: var(--accent); background: var(--accent-soft);
            }
            .received .status-icon::after {
              content: ""; position: absolute; left: 21px; top: 17px;
              width: 12px; height: 20px; border: solid currentColor;
              border-width: 0 2.5px 2.5px 0; transform: rotate(45deg);
            }
            .failed .status-icon { color: var(--warning); background: var(--warning-soft); }
            .failed .status-icon::before {
              content: ""; position: absolute; left: 26.5px; top: 16px;
              width: 3px; height: 16px; border-radius: 2px; background: currentColor;
            }
            .failed .status-icon::after {
              content: ""; position: absolute; left: 26.5px; top: 36px;
              width: 3px; height: 3px; border-radius: 50%; background: currentColor;
            }
            .notFound .status-icon { color: var(--neutral); background: var(--neutral-soft); }
            .notFound .status-icon::after {
              content: ""; position: absolute; left: 18px; top: 27px;
              width: 20px; height: 2px; border-radius: 2px; background: currentColor;
            }
            h1 { margin: 0; font-size: 26px; font-weight: 600; line-height: 1.45; letter-spacing: .02em; }
            .message { margin: 12px 0 0; color: var(--body); font-size: 16px; line-height: 1.8; }
            .footer { margin-top: 32px; padding-top: 20px; border-top: 1px solid var(--line); }
            .footer p { margin: 0; color: var(--muted); font-size: 13px; line-height: 1.7; }
            @media (max-width: 480px) {
              body { padding: 24px 16px; }
              .card { padding: 24px; border-radius: 20px; }
            }
            @media (prefers-color-scheme: dark) {
              :root {
                --page: #11131a; --card: #1b1e28; --ink: #eff0f6;
                --body: #b7bccd; --muted: #9299ad; --line: #2b2f3e;
                --accent: #b5adff; --accent-soft: #2d2947;
                --warning: #e3bd78; --warning-soft: #3b3022;
                --neutral: #b0b7c9; --neutral-soft: #2c303f;
                --shadow: 0 16px 56px rgba(0, 0, 0, .16), 0 2px 8px rgba(0, 0, 0, .1);
              }
            }
          </style>
        </head>
        <body>
          <main class="card \(rawValue)">
            <header class="brand" aria-label="轻译">
              <span class="brand-mark" aria-hidden="true">译</span>
              <span class="brand-name" aria-hidden="true">轻译</span>
            </header>
            <div class="status-icon" aria-hidden="true"></div>
            <h1>\(title)</h1>
            <p class="message">\(message)</p>
            <footer class="footer"><p>你可以关闭此页面。</p></footer>
          </main>
        </body>
        </html>
        """
    }
}

// Binds only to 127.0.0.1, lives for one OAuth attempt, accepts a bounded HTTP GET.
final class LoopbackReceiver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.laowang.qingyi.oauth-loopback")
    private var listener: NWListener?
    private var connectionSet: [ObjectIdentifier: NWConnection] = [:]
    private var continuation: CheckedContinuation<(String, String), Error>?
    private var result: Result<(String, String), Error>?
    private var timeout: DispatchWorkItem?
    let state: String
    let existingClient: String?
    init(state: String, existingClient: String?) { self.state = state; self.existingClient = existingClient }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { ready in
            queue.async {
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    parameters.allowLocalEndpointReuse = false
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    var hasReplied = false
                    listener.stateUpdateHandler = { status in
                        switch status {
                        case .ready:
                            guard !hasReplied, let port = listener.port else { return }
                            hasReplied = true
                            ready.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!)
                        case .failed(let error):
                            if !hasReplied { hasReplied = true; ready.resume(throwing: error) }
                            self.complete(.failure(error))
                        case .cancelled:
                            if !hasReplied { hasReplied = true; ready.resume(throwing: CancellationError()) }
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { connection in
                        guard self.connectionSet.count < 8 else { connection.cancel(); return }
                        let id = ObjectIdentifier(connection)
                        self.connectionSet[id] = connection
                        connection.start(queue: self.queue)
                        self.receive(connection, accumulated: Data())
                        self.queue.asyncAfter(deadline: .now() + 5) { connection.cancel(); self.connectionSet.removeValue(forKey: id) }
                    }
                    let timeout = DispatchWorkItem { self.complete(.failure(QingyiError.message("登录等待超时，请重新登录。"))) }
                    self.timeout = timeout
                    self.queue.asyncAfter(deadline: .now() + 180, execute: timeout)
                    listener.start(queue: self.queue)
                } catch { ready.resume(throwing: error) }
            }
        }
    }
    func wait() async throws -> (String, String) {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result { continuation.resume(with: result) }
                    else { self.continuation = continuation }
                }
            }
        }, onCancel: { self.cancel() })
    }
    func cancel() { queue.async { self.complete(.failure(CancellationError())) } }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, isComplete, error in
            var bytes = accumulated
            if let data = data { bytes.append(data) }
            guard bytes.count <= 16_384 else { connection.cancel(); return }
            guard let request = String(data: bytes, encoding: .utf8), request.contains("\r\n\r\n") else {
                if !isComplete && error == nil { self.receive(connection, accumulated: bytes) } else { connection.cancel() }
                return
            }
            let parts = request.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
            guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/auth/callback?") else { self.reply(connection, page: .notFound); return }
            do {
                let parsed = try CallbackParser.parse(String(parts[1]), expectedState: self.state, existingClient: self.existingClient)
                self.reply(connection, page: .received)
                self.complete(.success((parsed.code, parsed.client)), preserve: connection)
            } catch {
                // A bad state must not terminate a legitimate pending sign-in.
                self.reply(connection, page: .failed)
                if let components = URLComponents(string: "http://127.0.0.1" + String(parts[1])), components.queryItems?.first(where: { $0.name == "state" })?.value == self.state { self.complete(.failure(error), preserve: connection) }
            }
        }
    }
    private func reply(_ connection: NWConnection, page: OAuthCallbackPage) {
        let body = Data(page.html.utf8)
        let header = Data("HTTP/1.1 \(page.httpStatus)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: header + body, completion: .contentProcessed { _ in connection.cancel(); self.connectionSet.removeValue(forKey: ObjectIdentifier(connection)) })
    }
    private func complete(_ value: Result<(String, String), Error>, preserve: NWConnection? = nil) {
        guard result == nil else { return }
        result = value; timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        for connection in connectionSet.values where connection !== preserve { connection.cancel() }
        connectionSet = [:]
        continuation?.resume(with: value); continuation = nil
    }
}
