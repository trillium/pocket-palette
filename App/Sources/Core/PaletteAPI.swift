import Foundation

/// The only thing the client needs from the network, so tests can script responses.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    init(session: URLSession = URLSessionTransport.makeSession()) {
        self.session = session
    }

    /// No URL cache: the feed sends `no-store`, and ETag handling is ours so a 304 is visible.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PaletteError.invalidResponse }
        return (data, http)
    }
}

enum CommandsFetch: Equatable, Sendable {
    case notModified
    case updated(CommandList)
}

/// Error body the feed sends with every non-2xx answer: `{"ok":false,"error":"code","would_run":{"rule":...}}`.
private struct FailureBody: Decodable {
    struct WouldRun: Decodable { let rule: String? }
    let error: String?
    let wouldRun: WouldRun?
}

/// Client for the command service on the Mac. Contract: `docs/mac-contract.md`.
struct PaletteAPI: Sendable {
    static let maxBodyBytes = 4096

    let baseURL: URL
    private let transport: HTTPTransport

    init(baseURL: URL, transport: HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.transport = transport
    }

    func state() async throws -> PaletteState {
        let (data, _) = try await perform(request("state", timeout: 5))
        return try decode(PaletteState.self, from: data)
    }

    /// `knownRev` is the `commands_rev` of the list already held; the feed answers 304 when it is current.
    func commands(knownRev: String?) async throws -> CommandsFetch {
        var query = [URLQueryItem]()
        var extra = [String: String]()
        if let knownRev {
            query.append(URLQueryItem(name: "rev", value: knownRev))
            extra["If-None-Match"] = "\"\(knownRev)\""
        }
        let (data, response) = try await perform(request("commands", query: query, headers: extra, timeout: 15))
        if response.statusCode == 304 { return .notModified }
        return .updated(try decode(CommandList.self, from: data))
    }

    /// Runs `phrase` like speech. `id` lets the feed refuse if a different rule would win. `dryRun` only checks.
    func execute(phrase: String, id: String?, dryRun: Bool = false, force: Bool = false) async throws -> ExecuteResult {
        let req = try executeRequest(phrase: phrase, id: id, dryRun: dryRun, force: force)
        let (data, _) = try await perform(req)
        return try decode(ExecuteResult.self, from: data)
    }

    /// The exact `POST /execute` that `execute` sends.
    func executeRequest(phrase: String, id: String?, dryRun: Bool = false, force: Bool = false) throws -> URLRequest {
        var body: [String: String] = ["phrase": phrase]
        if let id { body["id"] = id }
        return try phraseRequest("execute", body: body, dryRun: dryRun, force: force)
    }

    /// Runs free text through the engine as if spoken. `dryRun` only reports what would run.
    func inject(phrase: String, dryRun: Bool = false) async throws -> InjectResult {
        let (data, _) = try await perform(injectRequest(phrase: phrase, dryRun: dryRun))
        return try decode(InjectResult.self, from: data)
    }

    /// The exact `POST /inject` that `inject` sends. Built here so the in-app dry-run preview shows the real request.
    func injectRequest(phrase: String, dryRun: Bool = false) throws -> URLRequest {
        try phraseRequest("inject", body: ["phrase": phrase], dryRun: dryRun, force: false)
    }

    private func phraseRequest(_ path: String, body: [String: String], dryRun: Bool, force: Bool) throws -> URLRequest {
        // Sorted keys: the same call always yields the same bytes, so the dry-run preview matches the real request exactly.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let payload = try encoder.encode(body)
        guard payload.count <= Self.maxBodyBytes else { throw PaletteError.bodyTooLarge }
        var query = [URLQueryItem]()
        if dryRun { query.append(URLQueryItem(name: "dry_run", value: "1")) }
        if force { query.append(URLQueryItem(name: "force", value: "1")) }
        var req = try request(path, query: query, headers: ["Content-Type": "application/json"], timeout: 10)
        req.httpMethod = "POST"
        req.httpBody = payload
        return req
    }

    // MARK: - Plumbing

    private func request(
        _ path: String, query: [URLQueryItem] = [], headers: [String: String] = [:], timeout: TimeInterval
    ) throws -> URLRequest {
        guard var parts = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw PaletteError.notConfigured
        }
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { throw PaletteError.notConfigured }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { req.setValue(value, forHTTPHeaderField: name) }
        return req
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as PaletteError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .badURL, .unsupportedURL: throw PaletteError.notConfigured
            default: throw PaletteError.offline
            }
        }
        if (200...299).contains(response.statusCode) || response.statusCode == 304 { return (data, response) }
        throw Self.error(for: response, body: data)
    }

    static func error(for response: HTTPURLResponse, body: Data) -> PaletteError {
        let failure = try? JSONDecoder.palette.decode(FailureBody.self, from: body)
        let status = response.statusCode
        switch status {
        case 401: return .unauthorized
        case 413: return .bodyTooLarge
        case 429: return .rateLimited(retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        // tailscale serve answers 502/503/504 itself when nothing is listening: that is the engine being down.
        case 502, 503: return .offline
        default:
            if let code = failure?.error {
                return .rejected(status: status, code: code, wouldRun: failure?.wouldRun?.rule)
            }
            return status == 504 ? .offline : .server(status: status)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder.palette.decode(type, from: data)
        } catch {
            throw PaletteError.invalidResponse
        }
    }
}
