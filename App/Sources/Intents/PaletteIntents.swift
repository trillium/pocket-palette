import AppIntents

/// A palette command as Siri/Spotlight sees it. Built from the cached list; never fetched over the network.
struct CommandEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Voice command"
    static let defaultQuery = CommandEntityQuery()

    let id: String
    let rule: String
    let context: String

    init(_ command: PaletteCommand) {
        id = command.id
        rule = command.rule
        context = command.contextName
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(rule)", subtitle: "\(context)")
    }
}

struct CommandEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [CommandEntity] {
        IntentRunner().commands(ids: identifiers).map(CommandEntity.init)
    }

    func entities(matching string: String) async throws -> [CommandEntity] {
        IntentRunner().search(string).map(CommandEntity.init)
    }

    func suggestedEntities() async throws -> [CommandEntity] {
        IntentRunner().commands().prefix(10).map(CommandEntity.init)
    }
}

struct RunCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Run voice command"
    static let description = IntentDescription("Runs a command from the palette on your Mac. Honours the Dry run switch.")
    static let openAppWhenRun = false

    @Parameter(title: "Command")
    var command: CommandEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$command)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await IntentRunner().run(id: command.id)
        return .result(dialog: IntentDialog(stringLiteral: outcome.message))
    }
}

struct PaletteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunCommandIntent(),
            phrases: ["Run a command in \(.applicationName)", "Run \(\.$command) in \(.applicationName)"],
            shortTitle: "Run command",
            systemImageName: "waveform"
        )
    }
}
