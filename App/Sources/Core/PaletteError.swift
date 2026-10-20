import Foundation

/// Everything the feed (or the network) can do wrong, mapped to one short sentence for the screen.
/// Never carries a request header.
enum PaletteError: Error, Equatable, Sendable {
    case notConfigured
    case offline
    case unauthorized
    case rateLimited(retryAfter: Int?)
    case bodyTooLarge
    case rejected(status: Int, code: String, wouldRun: String?)
    case server(status: Int)
    case invalidResponse

    var message: String {
        switch self {
        case .notConfigured: "Set the server URL in Settings"
        case .offline: "Mac offline"
        case .unauthorized: "Unauthorized: the feed asks for a token this app does not send"
        case .rateLimited(let retry): retry.map { "Rate limited (5/s): retry in \($0)s" } ?? "Rate limited (5/s)"
        case .bodyTooLarge: "Request too large (4096 B cap)"
        case .server(let status): "Server error (\(status))"
        case .invalidResponse: "Unexpected response from the Mac"
        case .rejected(_, let code, let wouldRun): Self.rejectionMessage(code: code, wouldRun: wouldRun)
        }
    }

    private static let rejectionMessages: [String: String] = [
        "no_match": "No matching command",
        "not_single_command": "Phrase matches more than one command",
        "denied": "Blocked: the phone may not run this command",
        "not_in_command_mode": "The engine is not in command mode",
        "execute_timeout": "The Mac did not run it in time",
        "unknown_command": "Command list is out of date",
        "invalid_phrase": "Invalid phrase",
        "tailnet_identity_required": "Refused: use the feed's tailscale serve address",
        "inject_needs_loopback_bind": "Refused: the feed must bind loopback behind tailscale serve"
    ]

    private static func rejectionMessage(code: String, wouldRun: String?) -> String {
        if code == "rule_mismatch" {
            return wouldRun.map { "The Mac would run \u{201C}\($0)\u{201D} instead" } ?? "A different command would run"
        }
        return rejectionMessages[code] ?? "Rejected (\(code))"
    }
}

extension PaletteError: CustomStringConvertible {
    var description: String { message }
}
