import UIKit
import WebKit

/// A distinct WebKit instance for a source website. No message handler or native
/// JavaScript bridge is registered in this view, including on login pages.
@MainActor
final class LegadoBrowserController: UIViewController, WKNavigationDelegate, WKUIDelegate, UIAdaptivePresentationControllerDelegate {
    let webView: WKWebView
    private let interactive: Bool
    private let sourceTitle: String
    private let statusLabel = UILabel()
    private var continuation: CheckedContinuation<[String: Any], Error>?
    private var timeoutTask: Task<Void, Never>?
    private var extractionTask: Task<Void, Never>?
    private var script: String?
    private var delay: Double = 0
    private var latestResponse: HTTPURLResponse?
    private var initialURL: URL?
    private var pendingDialogCancellation: (() -> Void)?
    private var navigationCount = 0
    private let captureKey = "__yueduResult_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")

    init(title: String, interactive: Bool) {
        self.sourceTitle = title
        self.interactive = interactive
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: configuration)
        super.init(nibName: nil, bundle: nil)
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = sourceTitle
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(done))
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 2
        statusLabel.text = "请完成登录或验证，然后点击完成返回阅读。"
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 7),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            webView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 7),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        webView.accessibilityIdentifier = "sources.loginBrowser"
    }

    func run(request: URLRequest, html: String?, script: String?, delayMilliseconds: Double) async throws -> [String: Any] {
        try Task.checkCancellation()
        loadViewIfNeeded()
        initialURL = request.url
        self.script = script?.trimmingCharacters(in: .whitespacesAndNewlines)
        delay = delayMilliseconds.isFinite ? min(30, max(0, delayMilliseconds / 1000)) : 0
        // This facade only stores a string inside the webpage. It cannot invoke
        // Swift, send HTTP requests through the client, or access source secrets.
        let capture = "window['\(captureKey)']=null;window.legado={getHTML:function(value){window['\(captureKey)']=String(value)}};"
        webView.configuration.userContentController.addUserScript(WKUserScript(source: capture, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if interactive {
                    guard let presenter = Self.presenter() else { finish(.failure(LegadoHTTPError.noPresenter)); return }
                    let navigation = UINavigationController(rootViewController: self)
                    navigation.modalPresentationStyle = .pageSheet
                    navigation.presentationController?.delegate = self
                    presenter.present(navigation, animated: true)
                }
                timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: self?.interactive == true ? 300_000_000_000 : 60_000_000_000) }
                    catch { return }
                    self?.finish(.failure(LegadoHTTPError.invalid("网页处理超时，请重试或先完成书源登录。")))
                }
                if let html { webView.loadHTMLString(html, baseURL: request.url) }
                else { webView.load(request) }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) } })
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        do { _ = try LegadoHTTPClient.validURL(url.absoluteString) }
        catch { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame == true {
            navigationCount += 1
            if !interactive, navigationCount > 12 {
                decisionHandler(.cancel)
                finish(.failure(LegadoHTTPError.invalid("网页重定向次数过多。")))
                return
            }
            statusLabel.text = "\(sourceTitle)\n\(url.host ?? "") · 登录完成后点击完成"
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse {
            latestResponse = http
            if http.expectedContentLength > 8_000_000 { decisionHandler(.cancel); finish(.failure(LegadoHTTPError.tooLarge)); return }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !interactive { beginExtraction() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(LegadoHTTPError.invalid("网页处理进程已停止，请重试。"))) }

    // Ordinary website dialogs are UI only. They do not dispatch native source
    // operations and the headless renderer cannot present them during search.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard interactive, presentedViewController == nil else { completionHandler(); return }
        let alert = UIAlertController(title: frame.request.url?.host ?? sourceTitle, message: String(message.prefix(2_000)), preferredStyle: .alert)
        pendingDialogCancellation = completionHandler
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self] _ in self?.resolveDialog { completionHandler() } })
        present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard interactive, presentedViewController == nil else { completionHandler(false); return }
        let alert = UIAlertController(title: frame.request.url?.host ?? sourceTitle, message: String(message.prefix(2_000)), preferredStyle: .alert)
        pendingDialogCancellation = { completionHandler(false) }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in self?.resolveDialog { completionHandler(false) } })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self] _ in self?.resolveDialog { completionHandler(true) } })
        present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard interactive, presentedViewController == nil else { completionHandler(nil); return }
        let alert = UIAlertController(title: frame.request.url?.host ?? sourceTitle, message: String(prompt.prefix(2_000)), preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText; $0.autocapitalizationType = .none }
        pendingDialogCancellation = { completionHandler(nil) }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in self?.resolveDialog { completionHandler(nil) } })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self, weak alert] _ in self?.resolveDialog { completionHandler(alert?.textFields?.first?.text) } })
        present(alert, animated: true)
    }

    private func resolveDialog(_ action: () -> Void) {
        guard pendingDialogCancellation != nil else { return }
        pendingDialogCancellation = nil
        action()
    }

    private func navigationFailed(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        if interactive { statusLabel.text = "加载失败：\(error.localizedDescription)" }
        else { finish(.failure(error)) }
    }

    private func beginExtraction() {
        guard continuation != nil, extractionTask == nil else { return }
        extractionTask = Task { [weak self] in
            guard let self else { return }
            do {
                if self.delay > 0 { try await Task.sleep(nanoseconds: UInt64(self.delay * 1_000_000_000)) }
                var body: String?
                if let script = self.script, !script.isEmpty {
                    let value = try await webView.evaluateJavaScript(script)
                    if let text = value as? String, !text.isEmpty { body = text }
                    else if let value, !(value is NSNull), JSONSerialization.isValidJSONObject(value) {
                        body = String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)
                    }
                    if script.contains("getHTML"), body == nil {
                        for _ in 0..<150 {
                            try Task.checkCancellation()
                            if let captured = try await webView.evaluateJavaScript("window['\(captureKey)']") as? String { body = captured; break }
                            try await Task.sleep(nanoseconds: 100_000_000)
                        }
                    }
                }
                if body == nil { body = try await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String ?? "" }
                try Task.checkCancellation()
                let text = body ?? ""
                let bytes = Data(text.utf8)
                guard bytes.count <= 8_000_000 else { throw LegadoHTTPError.tooLarge }
                let headers = latestResponse?.allHeaderFields.reduce(into: [String: String]()) { result, field in result[String(describing: field.key)] = String(describing: field.value) } ?? [:]
                finish(.success(["body": text, "url": webView.url?.absoluteString ?? initialURL?.absoluteString ?? "", "status": latestResponse?.statusCode ?? 200, "headers": headers, "bytes": bytes.base64EncodedString()]))
            } catch { finish(.failure(error)) }
        }
    }

    private func finish(_ result: Result<[String: Any], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        extractionTask?.cancel()
        extractionTask = nil
        webView.stopLoading()
        let dismissDialog = pendingDialogCancellation
        pendingDialogCancellation = nil
        dismissDialog?()
        if let navigation = navigationController, navigation.presentingViewController != nil {
            navigation.dismiss(animated: true) { continuation.resume(with: result) }
        } else { continuation.resume(with: result) }
    }

    @objc private func cancel() { finish(.failure(CancellationError())) }
    @objc private func done() { beginExtraction() }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finish(.failure(CancellationError())) }

    static func presenter() -> UIViewController? {
        guard UIApplication.shared.applicationState == .active,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}

@MainActor
final class LegadoInputController: UIViewController, UIAdaptivePresentationControllerDelegate {
    private let message: String
    private let initial: String
    private let secure: Bool
    private let imageData: Data?
    private let input = UITextField()
    private var continuation: CheckedContinuation<String, Error>?

    private init(title: String, message: String, initial: String, secure: Bool, imageData: Data?) {
        self.message = message; self.initial = initial; self.secure = secure; self.imageData = imageData
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func presentInput(title: String, message: String, initial: String, secure: Bool, imageData: Data?) async throws -> String {
        try Task.checkCancellation()
        guard let presenter = LegadoBrowserController.presenter() else { throw LegadoHTTPError.noPresenter }
        let controller = LegadoInputController(title: title, message: message, initial: initial, secure: secure, imageData: imageData)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                controller.continuation = continuation
                let navigation = UINavigationController(rootViewController: controller)
                navigation.modalPresentationStyle = .pageSheet
                navigation.sheetPresentationController?.detents = [.medium(), .large()]
                navigation.presentationController?.delegate = controller
                presenter.present(navigation, animated: true)
            }
        }, onCancel: { Task { @MainActor in controller.finish(.failure(CancellationError())) } })
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(done))
        let label = UILabel()
        label.text = message; label.font = .systemFont(ofSize: 15); label.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [label])
        stack.axis = .vertical; stack.spacing = 20
        if let imageData, let image = UIImage(data: imageData) {
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFit
            imageView.heightAnchor.constraint(equalToConstant: 120).isActive = true
            imageView.accessibilityLabel = "验证码图片"
            stack.addArrangedSubview(imageView)
        }
        input.borderStyle = .roundedRect
        input.text = initial
        input.isSecureTextEntry = secure
        input.autocorrectionType = .no
        input.autocapitalizationType = .none
        input.placeholder = "请输入"
        input.accessibilityIdentifier = "sources.interactionInput"
        input.heightAnchor.constraint(equalToConstant: 46).isActive = true
        stack.addArrangedSubview(input)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24)
        ])
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        dismiss(animated: true) { continuation.resume(with: result) }
    }
    @objc private func done() { finish(.success(input.text ?? "")) }
    @objc private func cancel() { finish(.failure(CancellationError())) }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: CancellationError())
    }
}
