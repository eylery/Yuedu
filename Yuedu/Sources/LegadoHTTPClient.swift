import Foundation
import CoreFoundation
import WebKit

/// Transport for evaluated source requests. It does not evaluate source JavaScript.
@MainActor
final class LegadoHTTPClient {
    static let shared = LegadoHTTPClient()
    private let session: URLSession
    private let cookieFile: URL
    private let backgroundTransfers: YueduBackgroundTransfer?
    private var cookies: [String: [StoredCookie]] = [:]
    private var active: [UUID: Int] = [:]
    private var rateWindows: [UUID: (start: TimeInterval, count: Int)] = [:]
    private nonisolated static let responseLimit = 8_000_000

    init(session: URLSession? = nil, cookieDirectory: URL? = nil, backgroundTransfers: YueduBackgroundTransfer? = nil) {
        self.backgroundTransfers = backgroundTransfers ?? (session == nil ? .shared : nil)
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            configuration.httpMaximumConnectionsPerHost = 3
            self.session = URLSession(configuration: configuration)
        }
        let directory = cookieDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Yuedu", isDirectory: true)
        cookieFile = directory.appendingPathComponent("source-cookies-v1.json")
        if let data = try? Data(contentsOf: cookieFile), let saved = try? JSONDecoder().decode([String: [StoredCookie]].self, from: data) { cookies = saved }
    }

    /// Returns HTTP error statuses as responses, since loginCheckJs may need them.
    /// cookieJar (default true) controls saving HTTP response cookies. Stored
    /// cookies and explicit Cookie headers remain available when it is false.
    func request(_ payload: [String: Any], sourceID: UUID) async throws -> [String: Any] {
        try Task.checkCancellation()
        try await acquire(sourceID, rate: payload["concurrentRate"] as? String ?? "")
        defer { active[sourceID, default: 1] -= 1 }
        // Build after waiting so requests use cookies saved by the previous request.
        let cookieJar = Self.cookieJarEnabled(payload)
        let request = try makeRequest(payload, sourceID: sourceID)
        if Self.bool(payload["webView"]) {
            return try await render(payload, request: request, sourceID: sourceID, interactive: false)
        }
        var prefetched: (Data, HTTPURLResponse)?
        if payload["followRedirects"] as? Bool != false {
            do {
                prefetched = try await backgroundTransfers?.response(for: request, sourceID: sourceID)
            } catch {
                try Task.checkCancellation()
                // A failed system transfer must not break a source that works
                // through the regular transport (e.g. redirect-set cookies).
            }
        }
        if let cached = prefetched, cached.1.statusCode < 400 {
            if let url = cached.1.url { _ = try Self.validURL(url.absoluteString) }
            if cookieJar { receiveCookies(cached.1, sourceID: sourceID) }
            let processed = try await Self.processInBackground(data: cached.0, response: cached.1,
                                                               charset: payload["charset"] as? String)
            try Task.checkCancellation()
            return processed.dictionary(fallbackURL: request.url!.absoluteString)
        }
        let explicitCookie = (payload["headers"] as? [String: Any])?.first(where: { $0.key.lowercased() == "cookie" })?.value as? String
        let delegate = LegadoRedirectDelegate { [weak self] response, proposed, count in
            guard let self else { throw CancellationError() }
            guard count <= 8 else { throw LegadoHTTPError.invalid("重定向次数过多，已停止请求。") }
            if cookieJar { self.receiveCookies(response, sourceID: sourceID) }
            if payload["followRedirects"] as? Bool == false { return nil }
            guard let url = proposed.url else { throw LegadoHTTPError.invalid("重定向缺少网址。") }
            _ = try Self.validURL(url.absoluteString)
            var redirected = proposed
            redirected.httpShouldHandleCookies = false
            // Rebuild Cookie from explicit input and the current jar. Retaining
            // the previous merged header would mask a fresh Set-Cookie value.
            redirected.setValue(nil, forHTTPHeaderField: "Cookie")
            let changesHost = response.url?.host?.lowercased() != url.host?.lowercased()
            let downgradesTLS = response.url?.scheme == "https" && url.scheme == "http"
            if changesHost || downgradesTLS { redirected.setValue(nil, forHTTPHeaderField: "Authorization") }
            if request.url?.host?.lowercased() == url.host?.lowercased(), !(request.url?.scheme == "https" && url.scheme == "http") {
                redirected.setValue(explicitCookie, forHTTPHeaderField: "Cookie")
            }
            self.applyCookies(to: &redirected, sourceID: sourceID)
            return redirected
        }
        let processed = try await Self.receiveInBackground(session: session, request: request, delegate: delegate,
                                                           charset: payload["charset"] as? String)
        try Task.checkCancellation()
        if let failure = delegate.failure { throw failure }
        if let url = processed.response.url { _ = try Self.validURL(url.absoluteString) }
        if cookieJar { receiveCookies(processed.response, sourceID: sourceID) }
        return processed.dictionary(fallbackURL: request.url!.absoluteString)
    }

    private nonisolated static func receiveInBackground(session: URLSession, request: URLRequest,
                                                        delegate: LegadoRedirectDelegate, charset: String?) async throws -> YueduHTTPResponse {
        let task = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
                defer { bytes.task.cancel() }
                if let failure = await delegate.failure { throw failure }
                guard response.expectedContentLength <= Int64(responseLimit) else { throw LegadoHTTPError.tooLarge }
                var data = Data()
                var chunk = [UInt8]()
                chunk.reserveCapacity(32_768)
                for try await byte in bytes {
                    guard data.count + chunk.count < responseLimit else { throw LegadoHTTPError.tooLarge }
                    chunk.append(byte)
                    if chunk.count == 32_768 {
                        try Task.checkCancellation()
                        data.append(contentsOf: chunk)
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                try Task.checkCancellation()
                data.append(contentsOf: chunk)
                guard let http = response as? HTTPURLResponse else {
                    throw LegadoHTTPError.invalid("服务器没有返回 HTTP 响应。")
                }
                return try process(data: data, response: http, charset: charset)
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func processInBackground(data: Data, response: HTTPURLResponse,
                                                        charset: String?) async throws -> YueduHTTPResponse {
        let task = Task.detached(priority: .userInitiated) {
            try process(data: data, response: response, charset: charset)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func process(data: Data, response: HTTPURLResponse,
                                            charset: String?) throws -> YueduHTTPResponse {
        try Task.checkCancellation()
        guard data.count <= responseLimit else { throw LegadoHTTPError.tooLarge }
        let text = try decode(data, preferred: charset, response: response.textEncodingName)
        try Task.checkCancellation()
        let encoded = data.base64EncodedString()
        try Task.checkCancellation()
        return YueduHTTPResponse(response: response, text: text, encoded: encoded,
                                 headers: responseHeaders(response))
    }

    /// Interactive browser, text input, or image captcha. User cancellation throws.
    func browser(_ payload: [String: Any], sourceID: UUID) async throws -> Any {
        guard Self.bool(payload["interactive"]) else {
            throw LegadoHTTPError.invalid("此书源需要登录或网页验证，请先打开书源的“登录与设置”。")
        }
        let method = (payload["method"] as? String ?? "browser").lowercased()
        if ["input", "code"].contains(method) {
            var imageData: Data?
            if method == "code", let imageURL = payload["url"] as? String {
                let response = try await request(["url": imageURL], sourceID: sourceID)
                imageData = (response["bytes"] as? String).flatMap { Data(base64Encoded: $0) }
            }
            return try await LegadoInputController.presentInput(title: sourceTitle(payload, sourceID), message: payload["message"] as? String ?? (method == "code" ? "请输入图片中的验证码" : "请输入内容"), initial: payload["value"] as? String ?? "", secure: Self.bool(payload["secure"]), imageData: imageData)
        }
        var browserPayload = payload
        var requestPayload = payload
        if let address = payload["url"] as? String, address.lowercased().hasPrefix("data:"), let comma = address.firstIndex(of: ",") {
            let metadata = String(address[..<comma]).lowercased()
            guard metadata.hasPrefix("data:text/html") || metadata.hasPrefix("data:text/plain") else { throw LegadoHTTPError.invalid("交互页面只支持 HTML 或文本数据地址。") }
            let content = String(address[address.index(after: comma)...])
            let bytes = metadata.contains(";base64") ? Data(base64Encoded: content, options: .ignoreUnknownCharacters) : (content.removingPercentEncoding ?? content).data(using: .utf8)
            guard let bytes, bytes.count <= Self.responseLimit else { throw LegadoHTTPError.tooLarge }
            browserPayload["html"] = String(decoding: bytes, as: UTF8.self)
            requestPayload["url"] = payload["baseUrl"] as? String ?? "https://local.yuedu.invalid/"
        }
        // Locally supplied login HTML still needs an HTTP origin for cookie scope.
        if payload["html"] is String, payload["url"] == nil { requestPayload["url"] = payload["baseUrl"] }
        requestPayload["method"] = "GET"
        let request = try makeRequest(requestPayload, sourceID: sourceID)
        return try await render(browserPayload, request: request, sourceID: sourceID, interactive: true)
    }

    func cookieHeader(for urlString: String, sourceID: UUID) -> String {
        guard let address = try? Self.cookieURL(urlString) else { return "" }
        return matchingCookies(address.url, sourceID: sourceID, allPaths: address.bareDomain).map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// The script Cookie API exchanges Cookie header pairs, not Set-Cookie attributes.
    func setCookies(_ value: String, for urlString: String, sourceID: UUID, replace: Bool = false) throws {
        let url = try Self.cookieURL(urlString).url
        guard !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw LegadoHTTPError.invalid("Cookie 包含无效控制字符。") }
        if replace { removeCookies(for: urlString, sourceID: sourceID) }
        let properties: [HTTPCookiePropertyKey: Any] = [.domain: url.host!, .path: "/", .originURL: url]
        let simple = value.split(separator: ";").compactMap { pair -> HTTPCookie? in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { return nil }
            var fields = properties
            fields[.name] = parts[0].trimmingCharacters(in: .whitespaces)
            fields[.value] = parts[1].trimmingCharacters(in: .whitespaces)
            return HTTPCookie(properties: fields)
        }
        mergeCookies(simple, sourceID: sourceID)
    }

    func cookie(_ payload: [String: Any], sourceID: UUID) async throws -> Any {
        guard let url = payload["url"] as? String else { throw LegadoHTTPError.invalid("Cookie 操作缺少网址。") }
        let address = try Self.cookieURL(url)
        switch (payload["action"] as? String ?? "get").lowercased() {
        case "get":
            if let key = payload["key"] as? String {
                return matchingCookies(address.url, sourceID: sourceID, allPaths: address.bareDomain).first(where: { $0.name == key })?.value ?? ""
            }
            return cookieHeader(for: url, sourceID: sourceID)
        case "set", "replace":
            try setCookies(payload["value"] as? String ?? "", for: url, sourceID: sourceID, replace: (payload["action"] as? String)?.lowercased() == "replace")
            return NSNull()
        case "remove":
            removeCookies(for: url, sourceID: sourceID)
            return NSNull()
        default: throw LegadoHTTPError.invalid("未知 Cookie 操作。")
        }
    }

    func removeCookies(for urlString: String, sourceID: UUID) {
        guard let url = try? Self.cookieURL(urlString).url, let host = url.host?.lowercased() else { return }
        cookies[sourceID.uuidString, default: []].removeAll { Self.domainMatches(host, cookieDomain: $0.domain) }
        persistCookies()
    }

    func backgroundRequest(url: String, headers: [String: String], sourceID: UUID) throws -> URLRequest? {
        // Background sessions follow redirects without consulting the delegate.
        // Keep authenticated, cookie-dependent and custom-header requests in the
        // foreground transport, where source isolation and redirect policy apply.
        let safeHeaders: Set<String> = ["user-agent", "accept", "accept-language", "accept-encoding", "referer", "origin"]
        guard headers.keys.allSatisfy({ safeHeaders.contains($0.lowercased()) }),
              cookieHeader(for: url, sourceID: sourceID).isEmpty else { return nil }
        return try makeRequest(["url": url, "headers": headers], sourceID: sourceID)
    }

    private func makeRequest(_ payload: [String: Any], sourceID: UUID) throws -> URLRequest {
        guard let urlText = payload["url"] as? String else { throw LegadoHTTPError.invalid("请求缺少网址。") }
        let charset = payload["charset"] as? String
        let encoding = try Self.encoding(charset == "escape" ? "utf-8" : charset ?? "utf-8")
        var encodedURL = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Preserve URL punctuation and existing escapes. Encoding only {{key}}
        // would break source expressions that return a complete request URL.
        if let question = encodedURL.firstIndex(of: "?") {
            let prefix = String(encodedURL[...question])
            let tail = String(encodedURL[encodedURL.index(after: question)...])
            let fragment = tail.firstIndex(of: "#")
            let query = fragment.map { String(tail[..<$0]) } ?? tail
            let suffix = fragment.map { String(tail[$0...]) } ?? ""
            let encoded = charset == "escape" ? try Self.encodeForm(query, encoding: encoding, preserveEscapes: false, legacyEscape: true) : try Self.encodeQuery(query, encoding: encoding)
            encodedURL = prefix + encoded + suffix
        }
        let url = try Self.validURL(encodedURL)
        var request = URLRequest(url: url)
        let method = (payload["method"] as? String ?? "GET").uppercased()
        guard !method.isEmpty, method.unicodeScalars.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) && $0.isASCII }) else { throw LegadoHTTPError.invalid("请求方法无效。") }
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.timeoutInterval = min(90, max(1, (payload["timeout"] as? NSNumber)?.doubleValue.mapMilliseconds ?? 30))
        request.setValue("Yuedu-iOS/1.0", forHTTPHeaderField: "User-Agent")
        if let values = payload["headers"] as? [String: Any] {
            for (name, raw) in values {
                guard let value = raw as? String else { throw LegadoHTTPError.invalid("请求头值必须为字符串。") }
                try Self.validateHeader(name, value)
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        if let body = payload["body"], !(body is NSNull), method != "HEAD", method != "GET" {
            if let text = body as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasExplicitType = request.value(forHTTPHeaderField: "Content-Type") != nil
                if !hasExplicitType {
                    let type = (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")) ? "application/json" : (trimmed.hasPrefix("<") ? "application/xml" : "application/x-www-form-urlencoded")
                    request.setValue(type, forHTTPHeaderField: "Content-Type")
                }
                let contentType = request.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                let encoded = !hasExplicitType && contentType.contains("application/x-www-form-urlencoded") ? try Self.encodeForm(text, encoding: encoding, preserveEscapes: charset == nil || charset == "", legacyEscape: charset == "escape") : text
                guard let bytes = encoded.data(using: encoding, allowLossyConversion: false) else { throw LegadoHTTPError.invalid("请求内容无法使用指定字符集编码。") }
                request.httpBody = bytes
            } else if JSONSerialization.isValidJSONObject(body) {
                request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
                if request.value(forHTTPHeaderField: "Content-Type") == nil { request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type") }
            } else { throw LegadoHTTPError.invalid("请求正文应为字符串或 JSON 对象。") }
        }
        if (request.httpBody?.count ?? 0) > Self.responseLimit { throw LegadoHTTPError.tooLarge }
        applyCookies(to: &request, sourceID: sourceID)
        return request
    }

    private func acquire(_ sourceID: UUID, rate: String) async throws {
        let parts = rate.split(separator: "/", omittingEmptySubsequences: false).compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let valid = (parts.count == 1 || parts.count == 2) && parts.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 86_400_000 }
        let interval = valid ? parts.last! / 1000 : 0
        let windowCount = valid && parts.count == 2 ? max(1, Int(parts[0])) : 1
        let serial = valid && parts.count == 1 && interval > 0
        while true {
            try Task.checkCancellation()
            let now = ProcessInfo.processInfo.systemUptime
            let window = rateWindows[sourceID]
            let elapsed = now - (window?.start ?? 0)
            // A single millisecond number means one in-flight request AND a
            // minimum interval between starts. n/ms is a fixed window of starts.
            let rateAllows = interval == 0 || window == nil || elapsed >= interval || (!serial && window!.count < windowCount)
            if active[sourceID, default: 0] < (serial ? 1 : 3), rateAllows {
                active[sourceID, default: 0] += 1
                if window == nil || elapsed >= interval { rateWindows[sourceID] = (now, 1) }
                else { rateWindows[sourceID] = (window!.start, window!.count + 1) }
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func render(_ payload: [String: Any], request: URLRequest, sourceID: UUID, interactive: Bool) async throws -> [String: Any] {
        // Legado's enabledCookieJar controls saving HTTP response cookies. The browser owns
        // a separate cookie session and syncs it even for an HTTP-disabled jar.
        let web = LegadoBrowserController(title: sourceTitle(payload, sourceID), interactive: interactive)
        let original = cookies[sourceID.uuidString, default: []]
        let jar = original.compactMap(\.cookie)
        for cookie in jar { await web.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) }
        if let agent = request.value(forHTTPHeaderField: "User-Agent") { web.webView.customUserAgent = agent }
        let html = (payload["html"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        do {
            let result = try await web.run(request: request, html: html, script: payload["webJs"] as? String ?? payload["js"] as? String, delayMilliseconds: (payload["webViewDelayTime"] as? NSNumber)?.doubleValue ?? 0)
            let updated = await web.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            replaceBrowserCookies(updated, original: original, sourceID: sourceID)
            return result
        } catch {
            let updated = await web.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            replaceBrowserCookies(updated, original: original, sourceID: sourceID)
            throw error
        }
    }

    private func sourceTitle(_ payload: [String: Any], _ sourceID: UUID) -> String {
        let source = payload["sourceName"] as? String ?? "书源 \(sourceID.uuidString.prefix(8))"
        if let title = payload["title"] as? String, !title.isEmpty { return "\(source) · \(title)" }
        return source
    }

    private func applyCookies(to request: inout URLRequest, sourceID: UUID) {
        guard let url = request.url else { return }
        let stored = cookieHeader(for: url.absoluteString, sourceID: sourceID)
        let explicit = request.value(forHTTPHeaderField: "Cookie") ?? ""
        guard !stored.isEmpty else { return }
        let names = Set(explicit.split(separator: ";").map { $0.split(separator: "=", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "" })
        let missing = matchingCookies(url, sourceID: sourceID).filter { !names.contains($0.name) }.map { "\($0.name)=\($0.value)" }
        request.setValue(([explicit].filter { !$0.isEmpty } + missing).joined(separator: "; "), forHTTPHeaderField: "Cookie")
    }

    private func matchingCookies(_ url: URL, sourceID: UUID, allPaths: Bool = false) -> [StoredCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        return cookies[sourceID.uuidString, default: []].filter {
            let path = url.path.isEmpty ? "/" : url.path
            let pathMatches = path == $0.path || (path.hasPrefix($0.path) && ($0.path.hasSuffix("/") || path.dropFirst($0.path.count).first == "/"))
            return Self.domainMatches(host, cookieDomain: $0.domain) && (allPaths || pathMatches) && (!$0.secure || url.scheme == "https") && ($0.expires == nil || $0.expires! > Date())
        }.sorted { $0.path.count > $1.path.count }
    }

    private static func domainMatches(_ host: String, cookieDomain: String) -> Bool {
        let domain = cookieDomain.lowercased()
        if domain.hasPrefix(".") { let suffix = String(domain.dropFirst()); return host == suffix || host.hasSuffix("." + suffix) }
        return host == domain
    }

    private func receiveCookies(_ response: HTTPURLResponse, sourceID: UUID) {
        guard let url = response.url else { return }
        let received = HTTPCookie.cookies(withResponseHeaderFields: Self.responseHeaders(response), for: url)
        mergeCookies(received.filter { Self.domainMatches(url.host?.lowercased() ?? "", cookieDomain: $0.domain) }, sourceID: sourceID)
    }

    private func mergeCookies(_ added: [HTTPCookie], sourceID: UUID) {
        guard !added.isEmpty else { return }
        var jar = cookies[sourceID.uuidString, default: []]
        for cookie in added {
            jar.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
            if cookie.expiresDate == nil || cookie.expiresDate! > Date() { jar.append(StoredCookie(cookie)) }
        }
        cookies[sourceID.uuidString] = Array(jar.suffix(400))
        persistCookies()
    }

    private func replaceBrowserCookies(_ added: [HTTPCookie], original: [StoredCookie], sourceID: UUID) {
        let updated = added.map(StoredCookie.init)
        // Preserve cookies from parallel URLSession requests. Only remove a
        // browser-deleted cookie when it has not since changed in the shared jar.
        let removed = original.filter { old in !updated.contains { $0.name == old.name && $0.domain == old.domain && $0.path == old.path } }
        cookies[sourceID.uuidString, default: []].removeAll { removed.contains($0) }
        let changed = added.filter { !original.contains(StoredCookie($0)) }
        mergeCookies(changed, sourceID: sourceID)
        if changed.isEmpty { persistCookies() }
    }

    private func persistCookies() {
        do {
            try FileManager.default.createDirectory(at: cookieFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(cookies).write(to: cookieFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { /* A cookie persistence failure must not corrupt the source library. */ }
    }

    static func validURL(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host?.isEmpty == false, url.user == nil, url.password == nil else { throw LegadoHTTPError.invalid("请求网址必须为有效的 HTTP/HTTPS 地址。") }
        return url
    }

    /// Android CookieManager also accepts a bare domain. Such lookups cover
    /// that host's saved paths; HTTP request cookies still obey normal paths.
    private static func cookieURL(_ text: String) throws -> (url: URL, bareDomain: Bool) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://") { return (try validURL(value), false) }
        let domain = value.hasPrefix(".") ? String(value.dropFirst()) : value
        let pattern = #"^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?::[0-9]{1,5})?$"#
        guard domain.range(of: pattern, options: .regularExpression) != nil else { throw LegadoHTTPError.invalid("Cookie 网址应为 HTTP/HTTPS 地址或有效域名。") }
        let url = try validURL("https://" + domain)
        if let port = url.port, !(1...65535).contains(port) { throw LegadoHTTPError.invalid("Cookie 域名端口无效。") }
        return (url, true)
    }

    static func validateHeader(_ name: String, _ value: String) throws {
        let token = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        let blocked = ["host", "content-length", "connection", "transfer-encoding", "upgrade", "te", "trailer", "proxy-connection"]
        guard !name.isEmpty, name.unicodeScalars.allSatisfy({ token.contains($0) }), !blocked.contains(name.lowercased()), !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw LegadoHTTPError.invalid("请求头包含无效字符或连接管理字段：\(name)") }
    }

    nonisolated static func encoding(_ name: String) throws -> String.Encoding {
        switch name.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "", "utf-8", "utf8": return .utf8
        case "gbk", "gb2312", "gb18030", "gb-18030": return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case "big5", "big-5": return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        case "iso-8859-1", "latin1": return .isoLatin1
        case "utf-16", "utf16": return .utf16
        default:
            let code = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            guard code != kCFStringEncodingInvalidId else { throw LegadoHTTPError.invalid("暂不支持字符集：\(name)") }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(code))
        }
    }

    private nonisolated static func decode(_ data: Data, preferred: String?, response: String?) throws -> String {
        guard !data.isEmpty else { return "" }
        for name in [preferred, response, "utf-8", "gb18030"].compactMap({ $0 }).filter({ !$0.isEmpty }) {
            if let encoding = try? encoding(name), let text = String(data: data, encoding: encoding) { return text }
        }
        // Binary downloads still need their original bytes for captcha/images.
        return String(decoding: data, as: UTF8.self)
    }

    private static func encodeQuery(_ text: String, encoding: String.Encoding) throws -> String {
        let allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$%&()*+,/:;=?@[\\]^`{|}"
        guard let bytes = text.data(using: encoding, allowLossyConversion: false) else { throw LegadoHTTPError.invalid("网址无法使用指定字符集编码。") }
        return bytes.map { allowed.utf8.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
    }

    private static func encodeForm(_ text: String, encoding: String.Encoding, preserveEscapes: Bool, legacyEscape: Bool) throws -> String {
        try text.split(separator: "&", omittingEmptySubsequences: false).map { pair in
            try pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map { component in
                let raw = String(component)
                let allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._*"
                if preserveEscapes, raw.utf8.allSatisfy({ allowed.utf8.contains($0) || $0 == 37 || $0 == 43 }) { return raw }
                if legacyEscape {
                    let escapeAllowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@*_+-./"
                    return raw.utf16.map { value in
                        if value < 128, escapeAllowed.utf8.contains(UInt8(value)) { return String(UnicodeScalar(value)!) }
                        return value < 256 ? String(format: "%%%02X", value) : String(format: "%%u%04X", value)
                    }.joined()
                }
                guard let bytes = raw.data(using: encoding, allowLossyConversion: false) else { throw LegadoHTTPError.invalid("表单无法使用指定字符集编码。") }
                return bytes.map { byte -> String in
                    if allowed.utf8.contains(byte) { return String(UnicodeScalar(byte)) }
                    if byte == 32 { return "+" }
                    return String(format: "%%%02X", byte)
                }.joined()
            }.joined(separator: "=")
        }.joined(separator: "&")
    }

    private nonisolated static func responseHeaders(_ response: HTTPURLResponse) -> [String: String] {
        response.allHeaderFields.reduce(into: [:]) { result, entry in result[String(describing: entry.key)] = String(describing: entry.value) }
    }
    private static func cookieJarEnabled(_ payload: [String: Any]) -> Bool { (payload["cookieJar"] as? Bool) ?? true }
    private static func bool(_ value: Any?) -> Bool { (value as? Bool) ?? ((value as? String)?.lowercased() == "true") }
}

private struct YueduHTTPResponse {
    let response: HTTPURLResponse
    let text: String
    let encoded: String
    let headers: [String: String]

    func dictionary(fallbackURL: String) -> [String: Any] {
        ["body": text, "url": response.url?.absoluteString ?? fallbackURL,
         "status": response.statusCode, "headers": headers, "bytes": encoded]
    }
}

private extension Double { var mapMilliseconds: Double { self / 1000 } }

private struct StoredCookie: Codable, Equatable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expires: Date?
    let secure: Bool
    let httpOnly: Bool

    init(_ cookie: HTTPCookie) {
        name = cookie.name; value = cookie.value; domain = cookie.domain; path = cookie.path
        expires = cookie.expiresDate; secure = cookie.isSecure; httpOnly = cookie.isHTTPOnly
    }
    var cookie: HTTPCookie? {
        var fields: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if let expires { fields[.expires] = expires }
        if secure { fields[.secure] = "TRUE" }
        if httpOnly { fields[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: fields)
    }
}

@MainActor
private final class LegadoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let handler: @MainActor (HTTPURLResponse, URLRequest, Int) throws -> URLRequest?
    private var count = 0
    private(set) var failure: Error?
    init(handler: @escaping @MainActor (HTTPURLResponse, URLRequest, Int) throws -> URLRequest?) { self.handler = handler }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        Task { @MainActor in
            self.count += 1
            do { completionHandler(try self.handler(response, request, self.count)) }
            catch { self.failure = error; completionHandler(nil) }
        }
    }
}

enum LegadoHTTPError: LocalizedError {
    case invalid(String), tooLarge, noPresenter
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .tooLarge: return "书源响应或请求超过 8 MB，已停止处理。"
        case .noPresenter: return "当前无法打开书源交互页面，请返回应用后重试。"
        }
    }
}
