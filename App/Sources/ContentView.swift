import SwiftUI

struct ContentView: View {
    @Bindable var model: PaletteModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var pending: CommandMatch?
    @State private var runText = ""
    private let buildInfo = BuildInfo()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                StateBar(model: model)
                dryRunToggle
                contextControls
                searchField
                runField
                resultList
            }
            .navigationTitle("Palette")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                        .accessibilityIdentifier("settingsButton")
                }
            }
            .overlay(alignment: .bottom) { FeedbackBanner(model: model) }
        }
        .sheet(isPresented: $showSettings, onDismiss: model.reloadConfiguration) {
            SettingsView(
                model: SettingsModel(settings: UserDefaultsSettingsStore()),
                buildInfo: buildInfo,
                historyCount: model.history.count,
                onClearHistory: model.clearHistory
            )
        }
        .sheet(item: $pending) { match in
            PhraseSheet(match: match) { phrase in
                Task { await model.execute(match.command, phrase: phrase) }
            }
        }
        .sheet(
            item: Binding(get: { model.dryRunPreview }, set: { if $0 == nil { model.closeDryRun() } })
        ) { preview in
            DryRunSheet(model: model, preview: preview)
        }
        // The id restarts polling on every foreground/background change; the task is cancelled in the background.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.pollForever()
        }
    }

    private var dryRunToggle: some View {
        Toggle(isOn: $model.dryRun) {
            Label(model.dryRun ? "Dry run: the Mac runs nothing" : "Dry run", systemImage: "hand.raised")
                .font(.subheadline.weight(model.dryRun ? .semibold : .regular))
                .foregroundStyle(model.dryRun ? .orange : .secondary)
        }
        .tint(.orange)
        .padding(.horizontal)
        .padding(.bottom, 4)
        .accessibilityIdentifier("dryRunToggle")
    }

    /// "This app only" is the hard filter; the toggle is the soft rank boost (default on).
    private var contextControls: some View {
        HStack {
            Button {
                model.thisAppOnly.toggle()
            } label: {
                Label(appChipTitle, systemImage: model.thisAppOnly ? "checkmark.circle.fill" : "app.badge")
                    .font(.subheadline.weight(model.thisAppOnly ? .semibold : .regular))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(model.thisAppOnly ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("appOnlyChip")
            .accessibilityValue(model.thisAppOnly ? "on" : "off")
            Spacer()
            Toggle("Context boost", isOn: $model.contextBoost)
                .font(.subheadline)
                .foregroundStyle(model.contextBoost ? .primary : .secondary)
                .fixedSize()
                .accessibilityIdentifier("contextBoostToggle")
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    private var appChipTitle: String {
        model.appName.map { "Only \($0)" } ?? "This app only"
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search commands", text: $model.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier("searchField")
            if !model.query.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { model.query = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    /// Free text the engine runs as if spoken (`POST /inject`); rows use the same path. Dry run stages it instead.
    private var runField: some View {
        HStack {
            Image(systemName: "waveform").foregroundStyle(.secondary)
            TextField("Say it, e.g. focus finder", text: $runText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(submitRun)
                .accessibilityIdentifier("runField")
            Button(model.dryRun ? "Dry run" : "Run", action: submitRun)
                .buttonStyle(.borderedProminent)
                .tint(model.dryRun ? .orange : .accentColor)
                .disabled(runText.trimmingCharacters(in: .whitespaces).isEmpty || model.isExecuting)
                .accessibilityIdentifier("runButton")
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func submitRun() {
        let text = runText
        Task {
            if await model.run(text) { runText = "" }
        }
    }

    @ViewBuilder
    private var resultList: some View {
        let results = model.results
        if model.connection == .unconfigured {
            ContentUnavailableView(
                "Not set up", systemImage: "gearshape",
                description: Text("Open Settings and enter the server URL.")
            )
        } else if results.isEmpty {
            ContentUnavailableView(
                model.commandCount == 0 ? "No commands yet" : "No matches",
                systemImage: "magnifyingglass",
                description: Text(emptyMessage)
            )
        } else {
            List(results) { match in
                Button { tap(match) } label: { CommandRow(match: match, isStale: model.isStale) }
                    .buttonStyle(.plain)
                    .disabled(model.isExecuting)
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private var emptyMessage: String {
        if model.commandCount == 0 { return "Waiting for the Mac." }
        if model.thisAppOnly && model.query.isEmpty { return "No commands are specific to this app." }
        return "Nothing matches \u{201C}\(model.query)\u{201D}."
    }

    private func tap(_ match: CommandMatch) {
        if match.spoken == nil {
            pending = match
        } else {
            Task { await model.execute(match.command) }
        }
    }
}
