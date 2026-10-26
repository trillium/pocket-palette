import SwiftUI

/// Checks the minimum-good-version file once at launch and each time the app comes to the front.
/// `.broken` swaps in the broken-build screen; `.ok` and `.unknown` (file unreachable) show the normal UI.
/// `-FMForceBroken` forces the broken screen, so the ship gate can prove it renders.
struct RootView: View {
    static let forceBrokenArgument = "-FMForceBroken"
    static let shownPrefix = "FMBrokenScreen: shown"

    @Bindable var model: PaletteModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var verdict: MinVersionPolicy.Verdict = .ok

    var body: some View {
        Group {
            if case .broken = verdict {
                BrokenBuildScreen().onAppear(perform: Self.reportShown)
            } else {
                ContentView(model: model)
            }
        }
        .task { await check() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await check() } }
        }
    }

    /// Under `-FMForceBroken` only: tells `scripts/smoke.sh` (via stdout) that the screen really rendered.
    private static func reportShown() {
        guard ProcessInfo.processInfo.arguments.contains(forceBrokenArgument) else { return }
        let line = "\(shownPrefix) \(Bundle.main.bundleIdentifier ?? "?") \(BuildInfo().display)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    private func check() async {
        let arguments = ProcessInfo.processInfo.arguments
        let url = MinVersionPolicy.url(from: Bundle.main.infoDictionary)
        verdict = await Self.verdict(arguments: arguments, url: url) { await MinVersionPolicy().fetch(url: $0) }
    }

    /// The forced argument wins and skips the network; no URL (key absent or empty) means no check; otherwise the policy decides.
    static func verdict(arguments: [String], url: URL?, fetch: (URL) async -> MinVersionPolicy.Verdict) async -> MinVersionPolicy.Verdict {
        if arguments.contains(forceBrokenArgument) { return .broken("forced by \(forceBrokenArgument)") }
        guard let url else { return .ok }
        return await fetch(url)
    }
}
