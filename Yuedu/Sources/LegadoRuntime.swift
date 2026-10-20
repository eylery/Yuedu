import Foundation
import WebKit
import UIKit

/// Each operation runs in its own WebKit process context. Only the bundled
/// adapter page receives the finite JSON bridge; websites never receive it.
@MainActor
final class LegadoRuntime: NSObject, WKUIDelegate, WKNavigationDelegate {
    private let source: BookSource
    private let http: LegadoHTTPClient
    private let stateStore: LegadoStateStore
    private var webView: WKWebView?
    private var startup: CheckedContinuation<Void, Error>?
    private var result: CheckedContinuation<[String: Any], Error>?
    private var budget: Task<Void, Never>?
    private var requests: [UUID: Task<Void, Never>] = [:]
    private let bridgeName = "yuedu-legado-" + UUID().uuidString
    private var interactive = false
    private var requestCount = 0
    private var finished = false
    private var logs: [String] = []

    init(source: BookSource, http: LegadoHTTPClient, stateStore: LegadoStateStore? = nil) {
        self.source = source
        self.http = http
        self.stateStore = stateStore ?? .shared
    }

    func run(_ operation: String, payload: [String: Any] = [:], timeout: TimeInterval = 120) async throws -> [String: Any] {
        try Task.checkCancellation()
        interactive = payload["interactive"] as? Bool == true
        budget = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.1, timeout) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(SourceError.invalid("书源执行超过时间上限，已停止。可检查书源脚本或稍后重试。")))
        }
        return try await withTaskCancellationHandler(operation: {
            do {
                try await prepare()
                try Task.checkCancellation()
                let sourceData = try SourceStore.encode(source)
                var arguments = payload
                arguments["source"] = try JSONSerialization.jsonObject(with: sourceData)
                arguments["state"] = stateStore.state(for: source.id)
                arguments["bridgeName"] = bridgeName
                return try await withCheckedThrowingContinuation { continuation in
                    guard !finished, let webView else { continuation.resume(throwing: CancellationError()); return }
                    result = continuation
                    webView.callAsyncJavaScript("return JSON.stringify(Legado.run(operation, payload));", arguments: ["operation": operation, "payload": arguments], in: nil, in: .page) { [weak self] output in
                        guard let self, !self.finished else { return }
                        do {
                            let raw = try output.get()
                            guard let json = raw as? String, let data = json.data(using: .utf8),
                                  let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                                throw SourceError.invalid("书源执行没有返回有效结果。")
                            }
                            if let state = value["state"] as? [String: Any] { try self.stateStore.save(state, for: self.source.id) }
                            if let error = value["error"] as? String { throw SourceError.invalid("\(self.source.bookSourceName)：\(error)") }
                            self.finish(.success(value))
                        } catch { self.finish(.failure(error)) }
                    }
                }
            } catch { finish(.failure(error)); throw error }
        }, onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) } })
    }

    private func prepare() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        view.uiDelegate = self
        view.navigationDelegate = self
        webView = view
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startup = continuation
            view.loadHTMLString("<!doctype html><html><head><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; connect-src 'none'; img-src 'none'; style-src 'none'; frame-src 'none'\"></head><body></body></html>", baseURL: nil)
        }
        for name in ["rules", "runtime"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "Legado") ?? Bundle.main.url(forResource: name, withExtension: "js") else {
                throw SourceError.invalid("应用缺少书源规则组件 \(name)。请重新安装完整版本。")
            }
            let script = try String(contentsOf: url, encoding: .utf8)
            _ = try await view.evaluateJavaScript(script)
        }
    }

    private func finish(_ value: Result<[String: Any], Error>) {
        guard !finished else { return }
        finished = true
        budget?.cancel()
        budget = nil
        for task in requests.values { task.cancel() }
        requests.removeAll()
        let pendingStartup = startup
        startup = nil
        if let pendingStartup {
            switch value {
            case .failure(let error): pendingStartup.resume(throwing: error)
            case .success: pendingStartup.resume(throwing: SourceError.invalid("书源组件启动未完成。"))
            }
        }
        let pending = result
        result = nil
        pending?.resume(with: value)
        webView?.stopLoading()
        webView?.uiDelegate = nil
        webView?.navigationDelegate = nil
        webView = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let continuation = startup
        startup = nil
        continuation?.resume()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(SourceError.invalid("书源执行进程已结束。请重试或检查脚本。"))) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Source scripts may parse arbitrary markup, but cannot navigate the
        // adapter page or give a remote page access to its native bridge.
        let url = navigationAction.request.url
        decisionHandler(startup != nil && (url?.absoluteString == "about:blank" || url == nil) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard !finished, frame.isMainFrame, prompt == bridgeName,
              let data = defaultText?.data(using: .utf8), data.count <= 24_000_000,
              let call = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let action = call["action"] as? String else {
            completionHandler(nil); return
        }
        let id = UUID()
        requests[id] = Task { [weak self] in
            guard let self else { completionHandler(nil); return }
            let answer: [String: Any]
            do {
                let value = try await self.handle(action, call["payload"] as? [String: Any] ?? [:])
                answer = ["value": value]
            } catch { answer = ["error": error.localizedDescription] }
            let json = (try? JSONSerialization.data(withJSONObject: answer, options: [.fragmentsAllowed])).flatMap { String(data: $0, encoding: .utf8) }
            completionHandler(json)
            self.requests.removeValue(forKey: id)
        }
    }

    private func handle(_ action: String, _ payload: [String: Any]) async throws -> Any {
        try Task.checkCancellation()
        guard !finished else { throw CancellationError() }
        switch action {
        case "request":
            requestCount += 1
            guard requestCount <= 300 else { throw SourceError.invalid("单次书源操作的请求数量超过 300 次。") }
            return try await http.request(payload, sourceID: source.id)
        case "cookie": return try await http.cookie(payload, sourceID: source.id)
        case "utility":
            guard let method = payload["method"] as? String else { throw SourceError.invalid("工具调用缺少方法名。") }
            let arguments = payload["arguments"] as? [Any] ?? []
            return try await Task.detached(priority: .userInitiated) { try LegadoNativeUtilities.call(method, arguments: arguments) }.value
        case "browser":
            guard interactive else { throw SourceError.invalid("此书源需要登录或网页验证，请从书源的“登录与设置”入口完成后重试。") }
            var options = payload
            options["sourceName"] = source.bookSourceName
            options["interactive"] = true
            return try await http.browser(options, sourceID: source.id)
        case "input":
            guard interactive else { throw SourceError.invalid("此书源需要验证码或参数，请先打开“登录与设置”。") }
            return try await input(payload)
        case "sleep":
            let milliseconds = min(10_000, max(0, payload["milliseconds"] as? Double ?? 0))
            try await Task.sleep(nanoseconds: UInt64(milliseconds * 1_000_000))
            return NSNull()
        case "log":
            if logs.count < 100 { logs.append(String((payload["message"] as? String ?? "").prefix(2_000))) }
            return NSNull()
        case "clipboard":
            guard interactive else { throw SourceError.invalid("复制操作只能从书源设置中执行。") }
            UIPasteboard.general.string = payload["text"] as? String
            return NSNull()
        default: throw SourceError.unsupported("未知书源宿主调用：\(action)")
        }
    }

    private func input(_ payload: [String: Any]) async throws -> String {
        guard let presenter = Self.presenter else { throw SourceError.invalid("无法显示书源输入窗口。") }
        return try await withCheckedThrowingContinuation { continuation in
            let alert = UIAlertController(title: source.bookSourceName, message: payload["message"] as? String ?? "请输入验证码或书源所需参数", preferredStyle: .alert)
            alert.addTextField { $0.text = payload["defaultValue"] as? String; $0.autocapitalizationType = .none; $0.autocorrectionType = .no }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in continuation.resume(throwing: CancellationError()) })
            alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak alert] _ in continuation.resume(returning: alert?.textFields?.first?.text ?? "") })
            presenter.present(alert, animated: true)
        }
    }

    static var presenter: UIViewController? {
        var controller = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }
}

/// Mutable script state belongs to a source, never to the imported JSON file.
/// It contains only data exposed through the source APIs, not app files or keys.
@MainActor
final class LegadoStateStore {
    static let shared = LegadoStateStore()
    private var states: [String: [String: Any]] = [:]
    private let file: URL
    private var loadError: Error?

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Yuedu", isDirectory: true)
        file = base.appendingPathComponent("source-runtime-state.json")
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path) {
                states = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [String: Any]] ?? [:]
            }
        } catch { loadError = error }
    }
    func state(for id: UUID) -> [String: Any] { states[id.uuidString] ?? [:] }
    func save(_ state: [String: Any], for id: UUID) throws {
        if let loadError { throw SourceError.invalid("书源运行状态读取失败，原文件已保留：\(loadError.localizedDescription)") }
        var next = states
        next[id.uuidString] = state
        let data = try JSONSerialization.data(withJSONObject: next, options: [.sortedKeys])
        guard data.count <= 50_000_000 else { throw SourceError.invalid("书源缓存与变量超过 50 MB，请清理书源运行数据。") }
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        states = next
    }
    func clear(id: UUID) throws {
        var next = states
        next.removeValue(forKey: id.uuidString)
        let data = try JSONSerialization.data(withJSONObject: next)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        states = next
    }
}
