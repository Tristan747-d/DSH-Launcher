import Foundation
import CryptoKit

/// Mints a DSH browser-session cookie from the shared activation secret.
///
/// **Why this is legitimate rather than a bypass.** DSH keeps its browser-auth
/// secret in `$DSH_HOME/.credentials.yaml` under the record
/// `client-connection/browser-session`. That file is *shared by every DSH
/// process on the machine*, while the cookie itself is bound only to the request
/// authority (`127.0.0.1:3080`). So a cookie this app signs is accepted by a
/// server the user started by hand in a terminal — DSH itself draws no
/// distinction between "the process that minted the cookie" and "any process
/// holding the same activation secret".
///
/// This matters because it removes a split brain: without it, the app could not
/// authenticate an existing server and started a *second* one, so the app window
/// and the browser window showed two different in-memory harness states.
///
/// The secret is read-only here. The launcher never writes the credentials
/// document — that stays DSH's own file, and a lock-holding DSH writer is never
/// raced.
enum BrowserCookie {

    /// Credential record key DSH uses for the browser session secret.
    static let recordKey = "client-connection/browser-session"

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Build the `Cookie:` header value for `authority` (e.g. `127.0.0.1:3080`).
    ///
    /// Mirrors DSH's own encoding exactly: base64url of the payload JSON, signed
    /// with HMAC-SHA256, serialized as `v1.<body>.<signature>` under the cookie
    /// name `dsh-auth-<sha256(authority) base64url>`.
    static func cookieHeader(authority: String, lifetimeDays: Int = 30) throws -> String {
        let secret = try activationSecret()
        let name = cookieName(authority: authority)
        let value = try signedCookieValue(authority: authority, secret: secret, lifetimeDays: lifetimeDays)
        return "\(name)=\(value)"
    }

    /// The cookie's name for one authority; also the name WebKit will store it under.
    static func cookieName(authority: String) -> String {
        let digest = SHA256.hash(data: Data(authority.utf8))
        return "dsh-auth-" + base64URL(Data(digest))
    }

    /// Locate and decode the shared activation secret.
    ///
    /// Returns the 32 raw bytes. A YAML parser is deliberately not used: the
    /// document is a fixed, DSH-owned shape, and pulling in a YAML dependency to
    /// read one nested scalar would be far more surface area than this needs.
    /// The parse is therefore narrow and fails loudly rather than guessing.
    static func activationSecret() throws -> Data {
        let home = ProcessInfo.processInfo.environment["DSH_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh")
        let url = home.appendingPathComponent(".credentials.yaml")

        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw Failure(message: "read \(url.path) failed — no DSH activation secret available")
        }
        guard let encoded = secretString(in: text) else {
            throw Failure(message: "\(url.path) has no \(recordKey) secret")
        }
        guard let raw = base64URLDecode(encoded), raw.count == 32 else {
            throw Failure(message: "\(url.path) has a malformed \(recordKey) secret")
        }
        return raw
    }

    /// Pull `secret: <base64url>` out of the `client-connection/browser-session`
    /// record, staying inside that record's block so an unrelated `secret:` key
    /// elsewhere in the document can never be picked up.
    static func secretString(in yaml: String) -> String? {
        var insideRecord = false
        var recordIndent = 0
        var pendingSecret: String?

        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let indent = line.prefix { $0 == " " }.count

            if !insideRecord {
                // Find the record key, with or without quotes.
                let key = trimmed.split(separator: ":").first.map(String.init) ?? ""
                let normalized = key.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if normalized == recordKey {
                    insideRecord = true
                    recordIndent = indent
                }
                continue
            }

            // The record ends when indentation returns to its own level or less.
            if indent <= recordIndent { break }

            if trimmed.hasPrefix("secret:") {
                let value = trimmed.dropFirst("secret:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                // A `secret:` key must be the scalar leaf, not a nested map.
                if !value.isEmpty { pendingSecret = value }
            }
        }
        return pendingSecret
    }

    // MARK: - Cookie construction

    private static func signedCookieValue(authority: String, secret: Data,
                                          lifetimeDays: Int) throws -> String {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let lifetime = lifetimeDays * 24 * 60 * 60 * 1000
        // Key order and separators must match DSH's own JSON.stringify output,
        // because the signature is computed over the exact body bytes and the
        // server re-serializes nothing.
        let payload = "{\"version\":1,\"authority\":\"\(authority)\","
            + "\"issuedAt\":\(now),\"expiresAt\":\(now + lifetime)}"
        let body = base64URL(Data(payload.utf8))
        let key = SymmetricKey(data: secret)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: key)
        return "v1.\(body).\(base64URL(Data(mac)))"
    }

    // MARK: - base64url

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ value: String) -> Data? {
        var s = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // DSH emits unpadded base64url; restore the padding to decode it.
        let remainder = s.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }
}
