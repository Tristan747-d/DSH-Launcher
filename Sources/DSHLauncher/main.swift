import Cocoa

/// DSH Launcher — a native macOS shell around the DeepSeek Harness Web GUI.
///
/// Opening this app is exactly "run `dsh web`, but show it here": it locates the
/// `dsh` binary, starts `dsh web --no-open --port <free>` as its child, reads the
/// tokenized URL from the child's stdout, and renders that page in an in-app
/// WKWebView. No browser window is ever opened, and the terminal is not needed.
///
/// It is a normal (foreground, Dock-visible) app on purpose. The DSH window is
/// where the user's work happens, so an accessory app with no Dock tile or menu
/// bar would remove the standard macOS affordances — ⌘W, ⌘Q, the Window menu,
/// full screen — that make it feel like an application rather than a web page.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var preferences = Preferences()
    private var controller: ServerController!
    private var windowController: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences = Preferences.load()
        preferences.save() // materialize defaults so the file is discoverable
        controller = ServerController(preferences: preferences)

        buildMenu()
        windowController = MainWindowController(preferences: preferences, controller: controller)
        windowController.showWindow(nil)

        // A DSH server is a long-lived service; bringing the window up front once
        // at launch is what the user asked for by opening the app.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Quitting the app must not silently kill a server the user started in a
    /// terminal, but it must not leave an orphan either when this app started it.
    /// `ServerController.stopOwnedServer()` enforces exactly that split.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller?.stopOwnedServer()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Clicking the Dock icon with no visible window reopens one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowController?.showWindow(nil) }
        return true
    }

    // MARK: - Menu bar

    /// A compact Codex-like menu: the standard app menu, Edit (so ⌘C/⌘V/⌘A work
    /// through the responder chain inside the web view), View, and Window.
    private func buildMenu() {
        let mainMenu = NSMenu()

        // ── App menu ─────────────────────────────────────────────────────────
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        let name = "DSH Launcher"
        appMenu.addItem(withTitle: "关于 \(name)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 \(name)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他",
                                        action: #selector(NSApplication.hideOtherApplications(_:)),
                                        keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "全部显示",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 \(name)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // ── Edit menu ────────────────────────────────────────────────────────
        // Essential: without it, ⌘C/⌘V/⌘Z never reach the web view's field editor.
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // ── View menu ────────────────────────────────────────────────────────
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "显示")
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "重新载入界面",
                         action: #selector(MainWindowController.reloadPage(_:)), keyEquivalent: "r")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "用浏览器打开当前页",
                         action: #selector(MainWindowController.openInBrowser(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "复制带 token 的地址",
                         action: #selector(MainWindowController.copyHarnessURL(_:)), keyEquivalent: "")
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(withTitle: "进入全屏幕",
                                          action: #selector(NSWindow.toggleFullScreen(_:)),
                                          keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control, .function]

        // ── Window menu ──────────────────────────────────────────────────────
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "最小化",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放",
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "前置全部窗口",
                           action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}

// ── Entry point ──────────────────────────────────────────────────────────────
// Written explicitly rather than relying on @main, so the app can be built as a
// plain `swiftc` executable and still get a real NSApplication run loop.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
