import Foundation

/// User-tunable behaviour, persisted as JSON under Application Support.
///
/// Every field has a safe default: a fresh install never needs the user to
/// open the settings file at all.
struct Preferences: Codable {
    /// Port to request first. DSH itself defaults to 3080, so matching it means
    /// the app and a hand-started `dsh web` agree on one URL.
    var preferredPort: Int = 3080
    /// When `preferredPort` is held by a server this app did not start, treat it
    /// as a DSH server and reuse it instead of searching for another port.
    ///
    /// Reusing is safe *and* desirable: the launcher authenticates with that
    /// process's own launch token, so nothing is bypassed. The cost is that
    /// closing the launcher cannot stop the server it merely attached to.
    var adoptExistingServer: Bool = true
    /// Stop the DSH server when the app quits, but only when this app started it.
    /// A server the user started in a terminal, or one this app merely adopted,
    /// is never touched.
    var stopServerOnQuit: Bool = true
    /// Send ⌘-clicked external links (docs, GitHub, …) to the system browser
    /// instead of loading them inside the harness window.
    var externalLinksInBrowser: Bool = true
    /// Window frame persistence.
    var windowWidth: Double = 1280
    var windowHeight: Double = 880
    /// Ask DSH to bind this port. Shared with the `dsh-cua` self-capture guard
    /// so it refuses to film any window pointed at the harness.
    var harnessPort: Int { preferredPort }

    static let directory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DSHLauncher", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static let fileURL = directory.appendingPathComponent("settings.json")
    static let logURL = directory.appendingPathComponent("dsh-web.log")

    static func load() -> Preferences {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Preferences.self, from: data)
        else { return Preferences() }
        return decoded
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Preferences.fileURL, options: .atomic)
    }
}

/// Minimal append-only log. The DSH server's own stdout/stderr goes to
/// `Preferences.logURL`; this is for launcher decisions, so a failed start can
/// be explained after the fact without a terminal.
enum Log {
    private static let lock = NSLock()
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "[\(stamp.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = Preferences.directory.appendingPathComponent("launcher.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
        FileHandle.standardError.write(data)
    }
}
