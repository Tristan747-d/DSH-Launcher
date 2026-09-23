import Cocoa
import WebKit

/// The one window: a native, Codex-style frame whose content is the DSH Web GUI.
///
/// **Why this shape.** The Codex desktop app on macOS is a frameless-feeling
/// window — no visible title, no toolbar, traffic lights floating over dark
/// chrome, and the app's own UI owning every other pixel. DSH's web frontend is
/// already a complete application shell (its PWA manifest declares
/// `display: fullscreen`, and it ships its own sidebar, header and composer), so
/// the correct native chrome around it is almost none. Anything drawn on top
/// would compete with the harness.
///
/// **Why a real 30pt strip and not a CSS drag region.** The tempting trick is
/// `-webkit-app-region: drag` on the page's top bar, but that is a
/// Chromium-only property: WKWebView ignores it. The native alternative,
/// `isMovableByWindowBackground`, would steal every text selection in the page.
/// A thin native strip above the web view buys real AppKit window dragging and
/// double-click-to-zoom, keeps the traffic lights on a matching dark surface,
/// and requires no CSS surgery on the harness.
final class MainWindowController: NSWindowController {

    private let preferences: Preferences
    private let controller: ServerController
    private var webView: WKWebView!
    private var statusLabel: NSTextField!
    private var retryButton: NSButton!

    /// Height of the native drag strip. 30pt comfortably contains the standard
    /// 28pt titlebar band the traffic lights are drawn into.
    static let titleStripHeight: CGFloat = 30

    /// One WKWebsiteDataStore id, reused forever, so cookies and localStorage
    /// belong to this app alone and persist across launches.
    static let dataStoreIdentifier = UUID(uuidString: "7C2B0D5A-9F1E-4E4B-9D4E-2E1B6B1F0A31")!

    /// The harness's own dark background, so native chrome and page never seam.
    static let surfaceColor = NSColor(calibratedRed: 0.129, green: 0.129, blue: 0.141, alpha: 1)

    init(preferences: Preferences, controller: ServerController) {
        self.preferences = preferences
        self.controller = controller

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0,
                                width: preferences.windowWidth,
                                height: preferences.windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "DeepSeek Harness"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.minSize = NSSize(width: 720, height: 480)
        window.backgroundColor = Self.surfaceColor
        window.center()
        window.setFrameAutosaveName("DSHLauncherMainWindow")

        super.init(window: window)

        configureContent()
        start()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Content

    private func configureContent() {
        guard let window else { return }

        let container = NSView(frame: window.contentLayoutRect)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.backgroundColor = Self.surfaceColor.cgColor

        // The window is `fullSizeContentView`, so this view sits exactly in the
        // titlebar band the traffic lights are drawn into: AppKit drags the
        // window from it with no extra work, and the buttons stay where muscle
        // memory expects them.
        let strip = NSView()
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.wantsLayer = true
        strip.layer?.backgroundColor = Self.surfaceColor.cgColor
        container.addSubview(strip)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.dataStoreIdentifier)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = Self.surfaceColor // no white flash on load
        self.webView = webView
        container.addSubview(webView)

        let label = NSTextField(labelWithString: "正在启动 DSH…")
        label.alignment = .center
        label.font = .systemFont(ofSize: 14)
        label.textColor = NSColor(calibratedWhite: 0.78, alpha: 1)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        self.statusLabel = label

        // Only revealed when startup fails and retrying can plausibly help.
        let button = NSButton(title: "重试", target: self, action: #selector(retryStartup(_:)))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        container.addSubview(button)
        self.retryButton = button

        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: container.topAnchor),
            strip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: Self.titleStripHeight),

            webView.topAnchor.constraint(equalTo: strip.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            label.centerXAnchor.constraint(equalTo: webView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: webView.centerYAnchor, constant: -24),
            button.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 18),
            button.centerXAnchor.constraint(equalTo: webView.centerXAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 620)
        ])

        window.contentView = container
        window.makeFirstResponder(webView)
    }

    // MARK: - Startup

    private func start() {
        controller.start(cookieProbe: { [weak self] port, done in
            guard let self else { done(false); return }
            self.probeCookie(on: port, done: done)
        }, completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.started(let url, let port)):
                Log.write("loading harness on port \(port) with a fresh token")
                self.retryButton.isHidden = true
                self.statusLabel.stringValue = "正在加载界面…"
                self.webView.load(URLRequest(url: url))
            case .success(.adopted(let port)):
                Log.write("loading harness on port \(port) (adopted server)")
                self.retryButton.isHidden = true
                self.statusLabel.stringValue = "正在连接已在运行的 DSH…"
                // A minted cookie must land in WebKit's store *before* the first
                // navigation, otherwise the load hits the 401 fence and the
                // window shows an authentication error instead of the harness.
                self.installPendingCookieThenLoad(port: port)
            case .failure(let error):
                let body = (error as? LauncherError)?.localizedBody ?? error.localizedDescription
                Log.write("startup failed: \(body)")
                self.showFailure(body,
                                 retryable: (error as? LauncherError)?.isRetryable ?? true)
            }
        })
    }

    /// Restart the server from scratch. This is the whole point of the app, so a
    /// failure is recoverable in one click rather than by reading a log and
    /// relaunching by hand.
    @objc func retryStartup(_ sender: Any?) {
        Log.write("retrying startup on user request")
        retryButton.isHidden = true
        statusLabel.textColor = NSColor(calibratedWhite: 0.78, alpha: 1)
        statusLabel.stringValue = "正在重新启动 DSH…"
        controller.reset()
        start()
    }

    /// Ask WebKit's cookie store for `dsh-auth-…` and try it against `port`.
    ///
    /// This is the cheap path: one loopback request carrying the cookie already
    /// saved in the app's WebKit store. The harness answers 200 when the cookie
    /// is valid and 401 when it is not, so the answer is the server's own rather
    /// than a guess. When it fails, `ServerController` mints a fresh cookie from
    /// the shared activation secret rather than falling back to a second server,
    /// because a second server would split the harness's in-memory state.
    private func probeCookie(on port: Int, done: @escaping (Bool) -> Void) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let relevant = cookies.filter { $0.name.hasPrefix("dsh-auth-") }
            guard !relevant.isEmpty else { done(false); return }

            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
            request.timeoutInterval = 2
            request.setValue(relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; "),
                             forHTTPHeaderField: "Cookie")
            URLSession.shared.dataTask(with: request) { _, response, _ in
                let status = (response as? HTTPURLResponse)?.statusCode
                let ok = status == 200 || status == 303
                DispatchQueue.main.async { done(ok) }
            }.resume()
        }
    }

    /// Seed WebKit's cookie store with the cookie minted for an adopted server,
    /// then navigate. This is what makes the app and a browser pointed at the
    /// same server show the *same* harness session.
    private func installPendingCookieThenLoad(port: Int) {
        let target = URL(string: "http://127.0.0.1:\(port)/")!

        guard let pending = controller.pendingCookie else {
            // No minted cookie needed: the stored one already authenticated.
            webView.load(URLRequest(url: target))
            return
        }

        // The header is `name=value`; split on the first `=` only, since the
        // value is dotted base64url and may itself contain no `=`.
        let parts = pending.header.split(separator: "=", maxSplits: 1,
                                        omittingEmptySubsequences: false)
        guard parts.count == 2,
              let cookie = HTTPCookie(properties: [
                  .domain: "127.0.0.1",
                  .path: "/",
                  .name: String(parts[0]),
                  .value: String(parts[1]),
                  .secure: "FALSE",
                  // A *persistent* cookie, mirroring DSH's own `Max-Age`. Without
                  // an expiry WebKit treats it as session-only and drops it on
                  // quit, which would force a re-mint on every launch and defeat
                  // the point of caching it here.
                  .expires: pending.expiresAt,
              ])
        else {
            webView.load(URLRequest(url: target))
            return
        }

        let name = cookie.name
        webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { [weak self] in
            DispatchQueue.main.async {
                Log.write("installed browser-session cookie \(name) for \(pending.authority)")
                self?.webView.load(URLRequest(url: target))
            }
        }
    }

    /// Show a failure without turning it into a dead end.
    ///
    /// The app's entire reason to exist is "open it and the harness is there", so
    /// an error that only tells the user to go read a log file is a bug in itself.
    /// A retry button is offered whenever retrying could plausibly work, and the
    /// log path is secondary rather than the instruction.
    private func showFailure(_ body: String, retryable: Bool) {
        statusLabel.isHidden = false
        statusLabel.textColor = NSColor(calibratedRed: 1, green: 0.45, blue: 0.4, alpha: 1)
        statusLabel.stringValue = body
        retryButton.isHidden = !retryable
    }

    // MARK: - Window menu actions

    @objc func reloadPage(_ sender: Any?) {
        if webView.url == nil { start() } else { webView.reload() }
    }

    @objc func openInBrowser(_ sender: Any?) {
        guard let url = webView.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Copy the tokenized URL, so the same session can be opened in a real
    /// browser when a web-only feature misbehaves inside WKWebView.
    @objc func copyHarnessURL(_ sender: Any?) {
        guard let url = controller.url ?? webView.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

// MARK: - Navigation policy

extension MainWindowController: WKNavigationDelegate {

    /// Keep the harness itself in-app; hand anything external to the browser.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow); return
        }

        let scheme = url.scheme?.lowercased() ?? ""
        let isWebScheme = ["http", "https"].contains(scheme)

        // Loopback HTTP and non-network schemes the harness itself uses stay in.
        if !isWebScheme || Self.isHarnessURL(url) {
            decisionHandler(.allow); return
        }

        // A genuinely foreign host — docs, a repo link, an OAuth page — must not
        // be silently loaded inside the harness frame.
        if preferences.externalLinksInBrowser {
            NSWorkspace.shared.open(url)
            Log.write("handed \(url.absoluteString) to the system browser")
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// A loopback URL is the harness; anything else is somebody else's page.
    static func isHarnessURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url, Self.isHarnessURL(url) {
            statusLabel.isHidden = true
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.write("navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        let ns = error as NSError
        Log.write("provisional navigation failed: \(ns.domain) \(ns.code) \(error.localizedDescription)")
        // -1004 cannot-connect means the server died under us; say so plainly
        // instead of leaving WebKit's English error page on a dark window.
        if ns.code == NSURLErrorCannotConnectToHost {
            showFailure("DSH 服务已断开。", retryable: true)
        }
    }

    /// A target=_blank inside the harness opens the system browser rather than a
    /// chromeless popup that would read as a rendering bug.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if Self.isHarnessURL(url) {
                webView.load(navigationAction.request)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }
}

// MARK: - UI delegate

extension MainWindowController: WKUIDelegate {

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "DeepSeek Harness"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "DeepSeek Harness"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "DeepSeek Harness"
        alert.informativeText = prompt
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }
}
