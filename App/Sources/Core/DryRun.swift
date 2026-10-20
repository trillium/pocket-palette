import Foundation

/// What the app WOULD send for a tap or a Run while Dry run is on. Pure data: building one never touches the network.
struct DryRunPreview: Equatable, Identifiable, Sendable {
    let id = UUID()
    /// The tapped row; nil for free text from the Run field.
    let command: PaletteCommand?
    let phrase: String
    let method: String
    /// Scheme, host, path and query exactly as `PaletteAPI.injectRequest` builds them.
    let url: String
    let headers: [Header]
    let body: String

    struct Header: Equatable, Sendable {
        let name: String
        let value: String
    }

    init(command: PaletteCommand?, phrase: String, request: URLRequest) {
        self.command = command
        self.phrase = phrase
        method = request.httpMethod ?? "GET"
        url = request.url?.absoluteString ?? ""
        headers = (request.allHTTPHeaderFields ?? [:])
            .map { Header(name: $0.key, value: $0.value) }
            .sorted { $0.name < $1.name }
        body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// The request as plain text, one header per line. Safe to show and to screenshot.
    var requestText: String {
        let head = ["\(method) \(url)"] + headers.map { "\($0.name): \($0.value)" }
        return (head + ["", body]).joined(separator: "\n")
    }
}

/// Dry-run Confirm: the feed's answer to the same request with `dry_run=1`. The engine parsed it and ran nothing.
struct DryRunOutcome: Equatable, Sendable {
    let previewID: UUID
    /// Rules the engine would run, in order; empty when the feed refused.
    let wouldRun: [String]
    /// The refusal in screen words; nil when the feed accepted the phrase.
    let error: String?

    var text: String {
        if let error { return error }
        return wouldRun.isEmpty ? "Nothing would run" : wouldRun.joined(separator: "\n")
    }
}
