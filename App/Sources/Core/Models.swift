import Foundation

/// JSON shapes served by the engine module on the Mac (`docs/mac-contract.md`).
/// Decoded with `JSONDecoder.palette` (snake_case keys).
struct PaletteCommand: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case literal, list, capture, unknown

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    /// Where the defining command file's context applies. Only active commands are served, so `.app` means the
    /// context names the frontmost app. Absent or unknown (older feed, new value) decodes as `.global`.
    enum Scope: String, Codable, Sendable {
        case app, tag, global

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Scope(rawValue: raw) ?? .global
        }
    }

    struct Slot: Codable, Equatable, Sendable {
        let name: String
        let type: String
        let n: Int?
        let open: Bool?
    }

    let id: String
    let rule: String
    let kind: Kind
    let slots: [Slot]
    let context: String
    let lineno: Int
    let shadowed: Int
    let scope: Scope
    /// App names the context requires (empty unless `scope == .app`).
    let apps: [String]
    /// Tags the context requires (may be set for `.app` commands too).
    let tags: [String]

    init(
        id: String, rule: String, kind: Kind = .literal, slots: [Slot] = [], context: String = "",
        lineno: Int = 0, shadowed: Int = 0, scope: Scope = .global, apps: [String] = [], tags: [String] = []
    ) {
        self.id = id
        self.rule = rule
        self.kind = kind
        self.slots = slots
        self.context = context
        self.lineno = lineno
        self.shadowed = shadowed
        self.scope = scope
        self.apps = apps
        self.tags = tags
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id)
        rule = try box.decode(String.self, forKey: .rule)
        kind = try box.decodeIfPresent(Kind.self, forKey: .kind) ?? .unknown
        slots = try box.decodeIfPresent([Slot].self, forKey: .slots) ?? []
        context = try box.decodeIfPresent(String.self, forKey: .context) ?? ""
        lineno = try box.decodeIfPresent(Int.self, forKey: .lineno) ?? 0
        shadowed = try box.decodeIfPresent(Int.self, forKey: .shadowed) ?? 0
        scope = try box.decodeIfPresent(Scope.self, forKey: .scope) ?? .global
        apps = try box.decodeIfPresent([String].self, forKey: .apps) ?? []
        tags = try box.decodeIfPresent([String].self, forKey: .tags) ?? []
    }

    /// Last path component of the command file that defines the rule, for the row subtitle.
    var contextName: String { (context as NSString).lastPathComponent }
}

struct CommandList: Codable, Equatable, Sendable {
    let commandsRev: String
    let count: Int
    let commands: [PaletteCommand]
}

struct PaletteState: Codable, Equatable, Sendable {
    struct App: Codable, Equatable, Sendable {
        let name: String
        let bundle: String
    }

    struct Window: Codable, Equatable, Sendable {
        let title: String
        let filename: String
        let fileExt: String
    }

    let host: String
    let ts: String
    let rev: String
    let app: App
    let window: Window
    let modes: [String]
    let tags: [String]
    let language: String
    let commandsRev: String

    /// The engine only runs voice commands in `command` mode; `/execute` answers 423 otherwise.
    var inCommandMode: Bool { modes.contains("command") }
}

struct ExecuteResult: Codable, Equatable, Sendable {
    let ok: Bool
    let matchedRule: String
    let path: String
    let dryRun: Bool?
}

/// `POST /inject` answer: the rules the phrase ran (`ran`) or, with `dry_run=1`, would run (`would_run`).
struct InjectResult: Codable, Equatable, Sendable {
    struct Rule: Codable, Equatable, Sendable {
        let rule: String
        let path: String
    }

    let ok: Bool
    var phrase: String?
    var dryRun: Bool?
    var wouldRun: [Rule]?
    var ran: [Rule]?

    var rules: [String] { (ran ?? wouldRun ?? []).map(\.rule) }
}

extension JSONDecoder {
    static var palette: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

extension JSONEncoder {
    static var palette: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}
