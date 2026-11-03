import AppKit
import CryptoKit
import Foundation
import Network

/// OAuth for Moxie's MCP server: dynamic client registration, PKCE (S256), public client, loopback redirect.
/// The browser does the sign-in (you're usually already logged in to Moxie there); tokens live in the Keychain.
@MainActor
final class MCPAuth {
    struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
    }

    enum AuthError: LocalizedError {
        case server(String)
        case cancelled
        case notSignedIn

        var errorDescription: String? {
            switch self {
            case let .server(detail): return "Moxie sign-in failed: \(detail)"
            case .cancelled: return "Sign-in was cancelled or timed out."
            case .notSignedIn: return "Connect Moxie MCP in Settings first."
            }
        }
    }

    static let resource = URL(string: "https://pod01.withmoxie.com/mcp")!
    /// Fallbacks match Moxie's published metadata; discovery runs first and wins.
    private static let defaultIssuer = URL(string: "https://auth.withmoxie.com")!
    /// Only what the widget uses. The consent screen can narrow it further.
    static let scopes = "clients:read projects:read tasks:read tasks:write time:read time:write tickets:read tickets:write search:read"
    /// Fixed so the registered redirect URI stays valid between launches.
    private static let port: UInt16 = 47_823
    private static var redirectURI: String { "http://127.0.0.1:\(port)/callback" }

    private let tokensAccount = "mcpTokens"
    private let clientIdKey = "mcpClientId"
    private var tokens: Tokens?
    private var refreshing: Task<Tokens, Error>?
    /// Test seam: when true, never touches the Keychain (same reasoning as `AppSettings.skipKeychain`).
    private let skipKeychain: Bool

    /// `skipKeychainForTesting` is the seam above: pass `true` from tests only.
    init(skipKeychainForTesting: Bool = false) {
        skipKeychain = skipKeychainForTesting
        tokens = skipKeychainForTesting ? nil : Keychain.get(tokensAccount).flatMap { try? JSONDecoder().decode(Tokens.self, from: Data($0.utf8)) }
    }

    var isSignedIn: Bool { tokens != nil }

    func signOut() {
        if let token = tokens?.refreshToken ?? tokens?.accessToken {
            Task { try? await self.revoke(token) }
        }
        tokens = nil
        guard !skipKeychain else { return }
        Keychain.set(nil, for: tokensAccount)
    }

    // MARK: Access tokens

    /// A valid access token, refreshed when it's about to expire.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = tokens else { throw AuthError.notSignedIn }
        if !forceRefresh, current.expiresAt > Date.now.addingTimeInterval(60) { return current.accessToken }
        guard let refresh = current.refreshToken else { throw AuthError.notSignedIn }
        if let refreshing { return try await refreshing.value.accessToken }
        let task = Task { () throws -> Tokens in
            let metadata = try await self.metadata()
            return try await self.exchange(metadata, [
                "grant_type": "refresh_token",
                "refresh_token": refresh,
                "client_id": try await self.clientId(metadata),
                "resource": Self.resource.absoluteString,
            ], keepRefresh: refresh)
        }
        refreshing = task
        defer { refreshing = nil }
        do {
            return try await task.value.accessToken
        } catch {
            // A refresh token Moxie no longer accepts means a fresh sign-in is needed.
            if case AuthError.server = error { signOut() }
            throw error
        }
    }

    // MARK: Sign-in

    func signIn() async throws {
        let metadata = try await metadata()
        let clientId = try await clientId(metadata)
        let verifier = Self.randomString(48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomString(24)

        var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "scope", value: Self.scopes),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "resource", value: Self.resource.absoluteString),
        ]

        let callback = LoopbackCallback(port: Self.port)
        try callback.start()
        defer { callback.stop() }
        NSWorkspace.shared.open(components.url!)
        let query = try await callback.wait(timeout: 300)

        if let error = query["error"] {
            throw AuthError.server(query["error_description"] ?? error)
        }
        guard query["state"] == state, let code = query["code"] else { throw AuthError.server("the reply didn't match this sign-in.") }
        if let iss = query["iss"], iss.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != metadata.issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            throw AuthError.server("unexpected issuer \(iss).")
        }
        _ = try await exchange(metadata, [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientId,
            "code_verifier": verifier,
            "resource": Self.resource.absoluteString,
        ], keepRefresh: nil)
    }

    // MARK: OAuth plumbing

    private struct Metadata: Decodable {
        let issuer: String
        let authorizationEndpoint: URL
        let tokenEndpoint: URL
        let registrationEndpoint: URL?
        let revocationEndpoint: URL?
    }

    private var cachedMetadata: Metadata?

    private func metadata() async throws -> Metadata {
        if let cachedMetadata { return cachedMetadata }
        struct Resource: Decodable { let authorizationServers: [URL]? }
        var issuer = Self.defaultIssuer
        let resourceURL = URL(string: "https://pod01.withmoxie.com/.well-known/oauth-protected-resource/mcp")!
        if let data = try? await URLSession.shared.data(from: resourceURL).0,
           let first = (try? Self.decoder.decode(Resource.self, from: data))?.authorizationServers?.first {
            issuer = first
        }
        let (data, _) = try await URLSession.shared.data(from: issuer.appending(path: ".well-known/oauth-authorization-server"))
        do {
            let metadata = try Self.decoder.decode(Metadata.self, from: data)
            cachedMetadata = metadata
            return metadata
        } catch {
            throw AuthError.server("couldn't read Moxie's sign-in settings.")
        }
    }

    /// Registers this app once (RFC 7591) and remembers the client id.
    private func clientId(_ metadata: Metadata) async throws -> String {
        if let saved = UserDefaults.standard.string(forKey: clientIdKey) { return saved }
        guard let endpoint = metadata.registrationEndpoint else { throw AuthError.server("Moxie doesn't allow app registration.") }
        let body: [String: Any] = [
            "client_name": "Moxie Timer (macOS widget)",
            "redirect_uris": [Self.redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "scope": Self.scopes,
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        struct Registered: Decodable { let clientId: String }
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let registered = try? Self.decoder.decode(Registered.self, from: data) else {
            throw AuthError.server("app registration was refused (\(String(decoding: data, as: UTF8.self).prefix(200))).")
        }
        UserDefaults.standard.set(registered.clientId, forKey: clientIdKey)
        return registered.clientId
    }

    private func exchange(_ metadata: Metadata, _ form: [String: String], keepRefresh: String?) async throws -> Tokens {
        var request = URLRequest(url: metadata.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formEncode(form).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        struct TokenResponse: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: Double?
        }
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let reply = try? Self.decoder.decode(TokenResponse.self, from: data) else {
            if (response as? HTTPURLResponse)?.statusCode == 400 || (response as? HTTPURLResponse)?.statusCode == 401,
               String(decoding: data, as: UTF8.self).contains("invalid_client") {
                // The registration was dropped on Moxie's side: register again next time.
                UserDefaults.standard.removeObject(forKey: clientIdKey)
            }
            throw AuthError.server(String(decoding: data, as: UTF8.self).prefix(200).description)
        }
        let fresh = Tokens(accessToken: reply.accessToken, refreshToken: reply.refreshToken ?? keepRefresh,
                           expiresAt: Date.now.addingTimeInterval(reply.expiresIn ?? 900))
        tokens = fresh
        if let json = try? JSONEncoder().encode(fresh) { Keychain.set(String(decoding: json, as: UTF8.self), for: tokensAccount) }
        return fresh
    }

    private func revoke(_ token: String) async throws {
        let metadata = try await metadata()
        guard let endpoint = metadata.revocationEndpoint, let clientId = UserDefaults.standard.string(forKey: clientIdKey) else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(["token": token, "client_id": clientId]).utf8)
        _ = try await URLSession.shared.data(for: request)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
    }

    private static func randomString(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URL
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Listens once on 127.0.0.1 for the browser's redirect and hands back its query parameters.
@MainActor
private final class LoopbackCallback {
    private let port: UInt16
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?

    init(port: UInt16) { self.port = port }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw MCPAuth.AuthError.server("port \(port) is busy — quit other sign-ins and try again.")
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                MainActor.assumeIsolated { self?.handle(connection, data) }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func wait(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.finish(.failure(MCPAuth.AuthError.cancelled))
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        finish(.failure(MCPAuth.AuthError.cancelled))
    }

    private func handle(_ connection: NWConnection, _ data: Data?) {
        let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        // "GET /callback?code=…&state=… HTTP/1.1"
        let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        guard target.hasPrefix("/callback"), let components = URLComponents(string: "http://127.0.0.1\(target)") else {
            respond(connection, status: "404 Not Found", body: "Not found")
            return
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let ok = query["code"] != nil
        respond(connection, status: "200 OK", body: """
            <html><body style="font-family:-apple-system;text-align:center;padding-top:80px;color:#1a1c29">
            <h2>\(ok ? "Moxie Timer is connected ✓" : "Sign-in didn't finish")</h2>
            <p>You can close this tab and go back to the widget.</p></body></html>
            """)
        finish(.success(query))
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let payload = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(payload.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
