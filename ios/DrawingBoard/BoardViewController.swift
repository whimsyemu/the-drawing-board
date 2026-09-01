import UIKit
import WebKit

/// Hosts The Drawing Board (a single self-contained HTML page bundled with the app)
/// inside a full-screen web view. Everything the person writes stays in the web
/// view's localStorage on the device; a JSON mirror is kept in Application Support
/// as a safety net so their writing survives anything WebKit might do to its store.
final class BoardViewController: UIViewController {

    static let boardColor = UIColor(red: 0x24 / 255.0, green: 0x1F / 255.0, blue: 0x38 / 255.0, alpha: 1)

    private var webView: WKWebView!
    private(set) var sync: CloudSync?
    private var speech: SpeechBridge?
    private var restoreChecked = false
    private var pendingDownloadURL: URL?

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Self.boardColor

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.dataDetectorTypes = []

        // Hide the "add to home screen" hint (we already are the home-screen app)
        // and let the page know it is running natively.
        let startupScript = """
        (function(){
          var s=document.createElement('style');
          s.textContent='#installnote{display:none !important}';
          (document.head||document.documentElement).appendChild(s);
          window.__drawingBoardNative='ios';
        })();
        """
        config.userContentController.addUserScript(
            WKUserScript(source: startupScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addUserScript(
            WKUserScript(source: CloudSync.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addUserScript(
            WKUserScript(source: SpeechBridge.polyfill, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        webView = WKWebView(frame: .zero, configuration: config)
        let sync = CloudSync(webView: webView)
        config.userContentController.add(sync, name: CloudSync.handlerName)
        self.sync = sync
        let speech = SpeechBridge(webView: webView)
        config.userContentController.add(speech, name: SpeechBridge.handlerName)
        self.speech = speech
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = Self.boardColor
        webView.scrollView.backgroundColor = Self.boardColor
        webView.underPageBackgroundColor = Self.boardColor
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        loadBoard()

        // Tiny sync X-ray (temporary): a faint "sync" in the corner that
        // reports what this device and iCloud can see of each other.
        let syncBtn = UIButton(type: .system)
        syncBtn.setTitle("\u{00b7} sync", for: .normal)
        syncBtn.titleLabel?.font = .systemFont(ofSize: 11)
        syncBtn.tintColor = UIColor.white.withAlphaComponent(0.35)
        syncBtn.translatesAutoresizingMaskIntoConstraints = false
        syncBtn.addTarget(self, action: #selector(showSyncInfo), for: .touchUpInside)
        view.addSubview(syncBtn)
        NSLayoutConstraint.activate([
            syncBtn.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            syncBtn.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
        ])
    }

    @objc private func showSyncInfo() {
        let cloud = NSUbiquitousKeyValueStore.default
        let synced = cloud.synchronize()
        let dict = cloud.dictionaryRepresentation
        let dataKeys = dict.keys.filter { $0.hasPrefix(CloudSync.namespace) }
        let tsKeys = dict.keys.filter { $0.hasPrefix("ts:") }
        var bytes = 0
        for (k, v) in dict { bytes += k.utf8.count; if let s = v as? String { bytes += s.utf8.count } }
        let token = FileManager.default.ubiquityIdentityToken != nil ? "yes" : "NO"
        let ext: String
        if let d = CloudSync.lastExternal {
            ext = "\(Int(-d.timeIntervalSinceNow))s ago (\(CloudSync.lastExternalKeys) keys)"
        } else {
            ext = "never this launch"
        }
        webView.evaluateJavaScript("localStorage.length") { [weak self] result, _ in
            let localCount = (result as? Int) ?? -1
            let report = """
            iCloud signed in: \(token)
            synchronize(): \(synced)
            board keys in iCloud: \(dataKeys.count)
            ts markers in iCloud: \(tsKeys.count)
            approx iCloud bytes: \(bytes)
            last push from iCloud: \(ext)
            localStorage items here: \(localCount)
            """
            let alert = UIAlertController(title: "Sync check", message: report, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Copy", style: .default) { _ in UIPasteboard.general.string = report })
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            self?.present(alert, animated: true)
        }
    }

    private func loadBoard() {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html") else { return }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    // MARK: - Safety-net mirror of localStorage

    private var backupURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DrawingBoard", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("board-backup.json")
    }

    func snapshotStorage() {
        let js = "(function(){var o={};for(var i=0;i<localStorage.length;i++){var k=localStorage.key(i);o[k]=localStorage.getItem(k);}return JSON.stringify(o);})()"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self, let text = result as? String, text.count > 2,
                  let data = text.data(using: .utf8) else { return }
            try? data.write(to: self.backupURL, options: .atomic)
        }
    }

    private func restoreIfEmpty() {
        guard !restoreChecked else { return }
        restoreChecked = true
        webView.evaluateJavaScript("localStorage.length") { [weak self] result, _ in
            guard let self = self, let count = result as? Int, count == 0,
                  let data = try? Data(contentsOf: self.backupURL),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String], !dict.isEmpty,
                  let json = try? JSONSerialization.data(withJSONObject: dict),
                  let jsonText = String(data: json, encoding: .utf8) else { return }
            let js = "(function(d){for(var k in d){try{localStorage.setItem(k,d[k])}catch(e){}}})(\(jsonText));location.reload();"
            self.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - Alerts (WKWebView shows nothing for alert/confirm/prompt unless we do)

    private func present(_ alert: UIAlertController) {
        if let pop = alert.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        present(alert, animated: true)
    }

    private func shareDownloadedFile(_ url: URL) {
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = activity.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 1, width: 1, height: 1)
        }
        present(activity, animated: true)
    }
}

// MARK: - WKNavigationDelegate

extension BoardViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if url.isFileURL || scheme == "about" || scheme == "blob" || scheme == "data" {
            decisionHandler(.allow)
            return
        }
        // http(s), mailto, spotify … hand off to the system.
        UIApplication.shared.open(url)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        restoreIfEmpty()
        sync?.bootstrap()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadBoard()
    }
}

// MARK: - WKDownloadDelegate (the "export my writing" file)

extension BoardViewController: WKDownloadDelegate {

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(suggestedFilename)
        try? FileManager.default.removeItem(at: url)
        pendingDownloadURL = url
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = pendingDownloadURL else { return }
        pendingDownloadURL = nil
        shareDownloadedFile(url)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        pendingDownloadURL = nil
    }
}

// MARK: - WKUIDelegate

extension BoardViewController: WKUIDelegate {

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, !url.isFileURL {
            UIApplication.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(alert)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text ?? "")
        })
        present(alert)
    }
}
