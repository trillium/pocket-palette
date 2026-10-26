// Vendored from parrot-kit main 7675044 (docs/min-version.md there); access made internal. Keep in sync by hand.
// MIT License, Copyright (c) 2026 Trillium Smith (parrot-kit); same terms as this repo's LICENSE. See THIRD_PARTY_NOTICES.md.
import SwiftUI

/// What an app shows instead of its normal screen when `MinVersionPolicy` calls its build broken: one plain message, the facts that
/// identify the build, and nothing to tap.
///
/// ```swift
/// if case .broken = verdict {
///     BrokenBuildScreen(appName: "My App", version: "1.4", build: "17", commit: "a1b2c3d", selfCheck: selfCheckLine)
/// }
/// ```
struct BrokenBuildScreen: View {
    let message: String
    let appName: String
    let version: String
    let commit: String
    let selfCheck: String

    /// - Parameters:
    ///   - message: replace to match an app's language; the default is the sentence every app shows.
    ///   - version: the version and build as one line (`1.4 (17)`), or whatever the app calls it.
    ///   - commit: the short commit the build was cut from; "unknown" when the build did not record one.
    ///   - selfCheck: the build's self-check line (what the self-test last said), or empty.
    init(appName: String, version: String, commit: String, selfCheck: String = "",
         message: String = BrokenBuildScreen.standardMessage) {
        self.appName = appName
        self.version = version
        self.commit = commit
        self.selfCheck = selfCheck
        self.message = message
    }

    static let standardMessage = "This build is broken. Install the stable app."

    /// The app's own details, from its Info.plist: `CFBundleDisplayName` or `CFBundleName`, `CFBundleShortVersionString (CFBundleVersion)`.
    /// The commit is the key `BuildCommit` when the build stamps one.
    init(bundle: Bundle = .main, selfCheck: String = "", message: String = BrokenBuildScreen.standardMessage) {
        let info = bundle.infoDictionary ?? [:]
        let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? ""
        let short = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        let version = build.isEmpty ? short : "\(short) (\(build))"
        let commit = info["BuildCommit"] as? String ?? "unknown"
        self.init(appName: name, version: version, commit: commit, selfCheck: selfCheck, message: message)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 0)
            Text(message)
                .font(.largeTitle.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 6) {
                Text(appName).font(.title3.weight(.semibold))
                Text("Version \(version)")
                Text("Commit \(commit)").font(.body.monospaced())
                if !selfCheck.isEmpty { Text(selfCheck).font(.footnote.monospaced()).foregroundStyle(.secondary) }
            }
            .font(.body)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(24)
        .background(Color.red.opacity(0.12).ignoresSafeArea())
        .accessibilityIdentifier("broken-build-screen")
    }
}
