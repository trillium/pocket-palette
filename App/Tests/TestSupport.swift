import Foundation
@testable import PocketPalette

/// Scripted network: answers are consumed in order; every request is recorded.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    enum Reply {
        case http(Int, String, [String: String])
        case failure(Error)
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply] = []) {
        self.replies = replies
    }

    func enqueue(_ reply: Reply) {
        lock.lock()
        defer { lock.unlock() }
        replies.append(reply)
    }

    private func next(for request: URLRequest) -> Reply {
        lock.withLock {
            requests.append(request)
            return replies.isEmpty ? Reply.failure(URLError(.cannotConnectToHost)) : replies.removeFirst()
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = next(for: request)
        switch reply {
        case .failure(let error):
            throw error
        case .http(let status, let body, let headers):
            let url = request.url ?? URL(fileURLWithPath: "/")
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.0", headerFields: headers)
            return (Data(body.utf8), response ?? HTTPURLResponse())
        }
    }
}

/// Holds the first request until `release()`, so a test can change state while a request is in flight.
final class GatedTransport: HTTPTransport, @unchecked Sendable {
    private let inner: FakeTransport
    private let arrived = AsyncStream<Void>.makeStream()
    private let gate = AsyncStream<Void>.makeStream()
    private let lock = NSLock()
    private var gated = false

    init(_ inner: FakeTransport) {
        self.inner = inner
    }

    /// Returns once a request is waiting at the gate.
    func waitForRequest() async {
        for await _ in arrived.stream { return }
    }

    func release() {
        gate.continuation.yield()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let first = lock.withLock { () -> Bool in
            defer { gated = true }
            return !gated
        }
        if first {
            arrived.continuation.yield()
            for await _ in gate.stream { break }
        }
        return try await inner.send(request)
    }
}

final class FakeSettingsStore: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: ServerSettings

    init(_ text: String = Fixture.server) {
        settings = ServerSettings(baseURLText: text)
    }

    func load() -> ServerSettings {
        lock.lock()
        defer { lock.unlock() }
        return settings
    }

    func save(_ settings: ServerSettings) {
        lock.lock()
        defer { lock.unlock() }
        self.settings = settings
    }
}

final class FakeCache: CommandCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CachedCommands?

    init(_ stored: CachedCommands? = nil) {
        self.stored = stored
    }

    var saved: CachedCommands? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func load(server: String) -> CachedCommands? {
        saved.flatMap { $0.server == server ? $0 : nil }
    }

    func save(_ cached: CachedCommands) {
        lock.lock()
        defer { lock.unlock() }
        stored = cached
    }
}

/// Bodies in the exact shape the engine module serves (docs/mac-contract.md).
enum Fixture {
    /// A tailnet-shaped feed URL; tests never read the build-time prefill (it is machine-local).
    static let server = "http://mac.tail0.ts.net:7399"

    static let commandsJSON = """
    {"commands_rev":"9a2e","count":3,"commands":[
     {"id":"b41c9e07","rule":"playback now","kind":"literal","slots":[],
      "context":"user/most_recent_command_playback/most_recent_command_playback.voice","lineno":4,"shadowed":0},
     {"id":"5d0a77c2","rule":"tab (open|new)","kind":"literal","slots":[],"context":"user/tabs.voice","lineno":7,"shadowed":1},
     {"id":"e19b3f10","rule":"say <text>","kind":"capture",
      "slots":[{"name":"text","type":"capture","open":true}],"context":"user/say.voice","lineno":2,"shadowed":0}]}
    """

    static let stateJSON = """
    {"host":"macbookpro","ts":"2026-10-17T02:50:11Z","rev":"c7f1",
     "app":{"name":"WezTerm","bundle":"com.github.wez.wezterm"},
     "window":{"title":"macbookpro: notes","filename":"","file_ext":""},
     "modes":["all","command"],"tags":["tabs"],"language":"","commands_rev":"9a2e"}
    """

    static let executeOK = #"{"ok":true,"matched_rule":"playback now","path":"user/x.voice"}"#
    static let injectOK = #"{"ok":true,"phrase":"playback now","ran":[{"rule":"playback now","path":"user/x.voice"}]}"#
    static let injectDryRun = """
    {"ok":true,"dry_run":true,"phrase":"tab open","would_run":[{"rule":"tab (open | new)","path":"user/tabs.voice"}]}
    """

    static func error(_ code: String, extra: String = "") -> String {
        #"{"ok":false,"error":"\#(code)"\#(extra)}"#
    }

    static func command(_ rule: String, id: String? = nil) -> PaletteCommand {
        PaletteCommand(id: id ?? rule, rule: rule, context: "user/\(rule).voice")
    }
}
