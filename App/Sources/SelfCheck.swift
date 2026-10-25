import Foundation

/// Launch with `-FMSelfCheck 1` and the app prints one `FMSelfCheck: ok ...` line to stdout.
/// `scripts/smoke.sh` (the ship-gate smoke step) requires that line from the built app. Extend `report` with
/// whatever must be true of a working build (a reachable backend, a migrated store); return nil to fail the check.
enum SelfCheck {
    static let argument = "FMSelfCheck"
    static let prefix = "FMSelfCheck: ok"

    static func report(bundleID: String?, build: BuildInfo) -> String? {
        guard let bundleID, build.build != "?" else { return nil }
        return "\(prefix) \(bundleID) \(build.display)"
    }

    static func runIfRequested(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        guard defaults.bool(forKey: argument) else { return }
        let line = report(bundleID: bundle.bundleIdentifier, build: BuildInfo(bundle: bundle)) ?? "FMSelfCheck: FAIL"
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}
