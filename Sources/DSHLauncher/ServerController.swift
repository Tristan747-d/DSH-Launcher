import Foundation
import Darwin

/// Owns the `dsh web` child process and the URL/token handshake.
///
/// Three facts about DSH drive this design:
///
/// 1. `dsh web --no-open` prints exactly one line at startup —
///    `dsh web: http://127.0.0.1:<port>/?token=<launchToken>` — and that token is
///    this process's browser-session key. There is no other way to learn it, so
///    the launcher must read the child's stdout.
/// 2. Visiting that URL mints a 30-day `dsh-auth-…` cookie and 303-redirects to
///    clean `/`. Subsequent requests are authenticated by that cookie. Keeping
///    the cookie in the WebKit data store therefore lets a *later* app launch —
///    even one that merely attaches to an already-running server — load the GUI
///    with no token at all.
/// 3. A server someone started by hand in a terminal has its own process-scoped
///    token, which this app can never obtain. So an external server is only
///    adopted when the app's saved cookie still authenticates against it;
///    otherwise the app starts its own child on a free port rather than
///    hijacking or killing the user's terminal session.
///
/// Every probe is callback-based and lands back on the main thread:
/// `WKHTTPCookieStore` must be touched from the main thread, so blocking that
/// thread while waiting on a cookie callback would deadlock.
final class ServerController {

    enum Outcome {
        /// The app spawned the server and knows its URL and token.
        case started(url: URL, port: Int)
        /// Reusing a server already running on `port`, with a cookie this app
        /// verified against it just now.
        case adopted(port: Int)
    }

    /// Answers "would a request carrying this app's saved dsh-auth cookie be
    /// accepted by the server on this port?" — implemented by the window layer
    /// because only WebKit holds the cookie. Called on the main thread; `done`
    /// must also be called on the main thread.
    typealias CookieProbe = (Int, @escaping (Bool) -> Void) -> Void

    private(set) var process: Process?
    private(set) var url: URL?
    private(set) var token: String?
    private(set) var port: Int?

    /// A cookie minted for an adopted server, handed to the window so it can be
    /// injected into WebKit's cookie store before the first navigation.
    /// `expiresAt` mirrors the signed payload's lifetime, so WebKit stores the
    /// cookie persistently rather than dropping it at quit.
    private(set) var pendingCookie: (authority: String, header: String, expiresAt: Date)?

    private let preferences: Preferences
    private var stdoutBuffer = Data()
    private let urlLine = DispatchSemaphore(value: 0)

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    // MARK: - Probing

    /// A TCP connect tells us whether something is listening, but not what it is.
    /// Synchronous with a 300 ms budget: it runs once, before any window loads.
    static func portIsOpen(_ port: Int, host: String = "127.0.0.1") -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
        addr.sin_addr.s_addr = inet_addr(host)
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Does `GET /` on `port` answer like a DSH server: a 401 authentication
    /// challenge, a 303 token exchange, or a 200 that already carries a cookie?
    ///
    /// Callback-based on purpose — a wrong guess here (adopting an unrelated
    /// local service as the harness) is worse than a moment of startup latency,
    /// which is why the probe exists at all.
    static func probeIsDshServer(port: Int, timeout: TimeInterval = 1.5,
                                 _ done: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { done(false); return }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode
            let isDsh = status == 401 || status == 303 || status == 200
            DispatchQueue.main.async { done(isDsh) }
        }.resume()
    }

    // MARK: - Starting

    /// Decide between reusing a listening server and spawning a child, then
    /// resolve the URL the window should load. `completion` always runs on main.
    ///
    /// **Adoption is the default and the point.** DSH's browser-session secret is
    /// shared across processes, so a server the user started by hand in a
    /// terminal is one this app can authenticate against. Adopting it is what
    /// keeps the app window and the browser window on a *single* harness — and
    /// therefore a single in-memory session state. Starting a second server would
    /// split that state in two, which is the whole failure this avoids.
    ///
    /// A private server is still the fallback for the cases where adoption is
    /// genuinely impossible: the port is held by a non-DSH process, the
    /// credentials document is missing or malformed, or the user turned
    /// `adoptExistingServer` off.
    func start(cookieProbe: @escaping CookieProbe,
               completion: @escaping (Result<Outcome, Error>) -> Void) {
        let preferred = preferences.preferredPort

        guard Self.portIsOpen(preferred) else {
            spawn(preferredPort: preferred, completion: completion)
            return
        }

        Self.probeIsDshServer(port: preferred) { [weak self] isDsh in
            guard let self else { return }
            guard isDsh else {
                Log.write("port \(preferred) is held by something that is not a DSH "
                          + "server; starting a private server")
                self.spawn(preferredPort: preferred, completion: completion)
                return
            }
            guard self.preferences.adoptExistingServer else {
                Log.write("adoptExistingServer is off; starting a private server even "
                          + "though DSH answers on \(preferred)")
                self.spawn(preferredPort: preferred, completion: completion)
                return
            }

            // 1. A cookie already in this app's WebKit store may still be valid.
            cookieProbe(preferred) { storedCookieWorks in
                if storedCookieWorks {
                    Log.write("adopting the DSH server on \(preferred) with the stored cookie")
                    self.adopt(port: preferred, completion: completion)
                    return
                }

                // 2. Mint one from the shared activation secret. This is the
                //    normal path when adopting a server this app did not start:
                //    such a server mints its own process token, which we can
                //    never obtain, but the secret it verifies against is shared.
                do {
                    let authority = "127.0.0.1:\(preferred)"
                    let minted = try BrowserCookie.mint(authority: authority)
                    self.pendingCookie = (authority: authority,
                                          header: minted.header,
                                          expiresAt: minted.expiresAt)
                    Log.write("minted a browser-session cookie from the shared DSH "
                              + "activation secret for \(authority)")
                    self.adopt(port: preferred, completion: completion)
                } catch {
                    // Not fatal: a private server still works, it just cannot
                    // share state with whatever is on `preferred`.
                    let reason = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    Log.write("cannot authenticate the DSH server on \(preferred) "
                              + "(\(reason)); starting a private server instead — the app "
                              + "and any browser on \(preferred) will NOT share session state")
                    self.spawn(preferredPort: preferred, completion: completion)
                }
            }
        }
    }

    /// Record the adopted port and finish, loading `/` (the cookie is injected
    /// into WebKit's store before the window navigates).
    private func adopt(port: Int,
                       completion: @escaping (Result<Outcome, Error>) -> Void) {
        self.port = port
        self.url = URL(string: "http://127.0.0.1:\(port)/")
        completion(.success(.adopted(port: port)))
    }

    /// Launch `dsh web --no-open --port <free port>` and wait for its URL line.
    private func spawn(preferredPort: Int,
                       completion: @escaping (Result<Outcome, Error>) -> Void) {
        guard let port = choosePort(from: preferredPort) else {
            completion(.failure(LauncherError.noFreePort)); return
        }
        guard let executable = Self.resolveDshExecutable() else {
            completion(.failure(LauncherError.dshNotFound)); return
        }

        let child = Process()
        child.executableURL = executable
        child.arguments = ["web", "--no-open", "--port", String(port)]
        child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        // stdout carries the tokenized URL; stderr carries configuration errors
        // that DSH prints before it ever gets as far as printing one.
        let stdout = Pipe()
        let stderr = Pipe()
        child.standardOutput = stdout
        child.standardError = stderr
        child.standardInput = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consumeStdout(data)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") { Log.write("dsh web stderr: \(line)") }
        }
        child.terminationHandler = { [weak self] proc in
            Log.write("dsh web exited with status \(proc.terminationStatus)")
            self?.urlLine.signal()
        }

        do {
            try child.run()
        } catch {
            completion(.failure(error)); return
        }
        process = child
        self.port = port
        Log.write("started \(executable.path) web --no-open --port \(port) "
                  + "(pid \(child.processIdentifier))")

        // The URL line arrives within a couple of seconds; wait off the main
        // thread so the UI keeps drawing while the server boots.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let waited = self.urlLine.wait(timeout: .now() + 45)
            let resolvedURL = self.url
            DispatchQueue.main.async {
                if waited == .timedOut || resolvedURL == nil {
                    completion(.failure(LauncherError.noUrlLine(self.logTail())))
                } else if let resolvedURL {
                    completion(.success(.started(url: resolvedURL, port: port)))
                }
            }
        }
    }

    private func consumeStdout(_ data: Data) {
        stdoutBuffer.append(data)
        guard let text = String(data: stdoutBuffer, encoding: .utf8) else { return }
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            Log.write("dsh web: \(line)")
            if url == nil, let candidate = Self.parseUrlLine(line) {
                url = candidate.url
                token = candidate.token
                urlLine.signal()
            }
        }
        stdoutBuffer.removeAll(keepingCapacity: true)
    }

    /// Parse `dsh web: http://127.0.0.1:3080/?token=…`, tolerating the LAN suffix
    /// (` (LAN: …)`) that DSH appends when it is reachable off-box.
    static func parseUrlLine(_ line: String) -> (url: URL, token: String)? {
        guard line.contains("dsh web:") else { return nil }
        let afterMarker = line.components(separatedBy: "dsh web:").dropFirst()
            .joined(separator: "dsh web:")
        guard let start = afterMarker.range(of: "http://")?.lowerBound else { return nil }
        let rest = afterMarker[start...]
        let end = rest.firstIndex(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) ?? rest.endIndex
        let raw = String(rest[rest.startIndex..<end])
        guard let url = URL(string: raw),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let token = components.queryItems?.first(where: { $0.name == "token" })?.value ?? ""
        return (url, token)
    }

    /// Prefer the configured port; on collision walk upward, then fall back to a
    /// nearby range, and finally let the OS choose (`--port 0` is supported).
    private func choosePort(from preferredPort: Int) -> Int? {
        var candidates = Array(preferredPort...(preferredPort + 20))
        if !(3080...3099).contains(preferredPort) {
            candidates.append(contentsOf: 3080..<3100)
        }
        candidates.append(0)
        for candidate in candidates where candidate == 0 || !Self.portIsOpen(candidate) {
            return candidate
        }
        return nil
    }

    /// Locate the `dsh` executable the way an interactive shell would.
    ///
    /// A GUI app inherits no shell PATH, so this resolution is not optional: the
    /// symlink below is what the user's `dsh web` actually resolves to, and using
    /// it avoids spawning a login shell (slow, and it would drag the user's rc
    /// files into the app's process tree).
    static func resolveDshExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates: [URL] = []
        if let extra = ProcessInfo.processInfo.environment["DSH_LAUNCHER_DSH_PATH"],
           !extra.isEmpty {
            candidates.append(URL(fileURLWithPath: extra))
        }
        candidates.append(contentsOf: [
            home.appendingPathComponent(".local/bin/dsh"),
            URL(fileURLWithPath: "/opt/homebrew/bin/dsh"),
            URL(fileURLWithPath: "/usr/local/bin/dsh")
        ])
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Tail of the mirrored server log, for a startup error. A failed
    /// `dsh web --no-open --port N` prints its reason there.
    func logTail(_ lines: Int = 12) -> String {
        guard let data = try? Data(contentsOf: Preferences.logURL),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }

    // MARK: - Stopping

    /// Terminate the child, but only when this app started it AND the user asked
    /// for that (`stopServerOnQuit`). A server that outlives the app is a feature:
    /// an attached terminal session, or another client, keeps working.
    func stopOwnedServer() {
        guard preferences.stopServerOnQuit, let process, process.isRunning else { return }
        Log.write("stopping dsh web (pid \(process.processIdentifier)) because "
                  + "stopServerOnQuit is set")
        process.terminate()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(100_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}

enum LauncherError: LocalizedError {
    case dshNotFound
    case noFreePort
    case noUrlLine(String)

    var errorDescription: String? {
        switch self {
        case .dshNotFound:
            return "找不到 dsh 命令。"
        case .noFreePort:
            return "没有可用端口。"
        case .noUrlLine(let tail):
            return tail.isEmpty ? "dsh web 没有输出监听地址。"
                                : "dsh web 启动失败：\n\(tail)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .dshNotFound:
            return "请确认已安装 dsh（一般是 ~/.local/bin/dsh），或用环境变量 "
                 + "DSH_LAUNCHER_DSH_PATH 指定它的完整路径。"
        case .noFreePort:
            return "在设置文件里换一个 preferredPort，或关掉占用端口的程序。"
        case .noUrlLine:
            return "详见 ~/Library/Application Support/DSHLauncher/ 下的 "
                 + "launcher.log 与 dsh-web.log。"
        }
    }

    /// Chinese body text with the recovery hint appended.
    var localizedBody: String {
        (errorDescription ?? "未知错误") + (recoverySuggestion.map { "\n\n\($0)" } ?? "")
    }
}
