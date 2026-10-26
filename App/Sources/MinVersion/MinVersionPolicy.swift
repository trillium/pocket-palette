// Vendored from parrot-kit main 7675044 (docs/min-version.md there); access made internal. Keep in sync by hand.
// MIT License, Copyright (c) 2026 Trillium Smith (parrot-kit); same terms as this repo's LICENSE. See THIRD_PARTY_NOTICES.md.
import Foundation

// swiftlint:disable cyclomatic_complexity

/// The oldest-good-build rule: a small JSON file served over the tailnet names, per app, the lowest build that is still good and any
/// single builds known to be broken. An app below the minimum or on the broken list shows a "broken build" screen instead of looking fine.
///
/// The check fails open. A missing entry, a bad status, a parse error, a timeout, no network or no URL at all are all ``Verdict/unknown``
/// (or ``Verdict/ok``), never ``Verdict/broken``: a file that cannot be reached must never lock anybody out.
///
/// ```json
/// {"schema":1,"updated":"2026-10-25","apps":{"com.example.app":{"min_build":12,"broken_builds":[9,10]}}}
/// ```
///
/// The beta id `<id>.beta` looks up the stable id's entry. Builds compare as integers (`CFBundleVersion`).
struct MinVersionPolicy: Sendable {
    enum Verdict: Equatable, Sendable {
        /// The file was read and this build is good (or the file says nothing about this app).
        case ok
        /// This build is below the minimum or on the broken list; the text says which.
        case broken(String)
        /// The file could not be read or understood: no restriction.
        case unknown
    }

    /// How an HTTP GET is made, so a test can answer without a network. Returns the body and the status code.
    typealias Loader = @Sendable (URL, TimeInterval) async throws -> (Data, Int)

    /// The Info.plist key (filled from the xcconfig setting `MIN_VERSION_URL`) that holds the file's URL.
    static let infoKey = "MinVersionURL"
    static let betaSuffix = ".beta"
    static let timeout: TimeInterval = 3

    let bundleID: String
    let build: Int?
    private let load: Loader

    /// - Parameters:
    ///   - bundleID: `CFBundleIdentifier`; the `.beta` suffix is dropped for the lookup.
    ///   - build: `CFBundleVersion` as an integer; nil when it is not one, and then nothing can be judged.
    ///   - loader: replaces the network, for tests.
    init(bundleID: String, build: Int?, loader: Loader? = nil) {
        self.bundleID = bundleID
        self.build = build
        self.load = loader ?? Self.networkLoader
    }

    /// The policy for the running app: its bundle id and `CFBundleVersion`.
    init(bundle: Bundle = .main, loader: Loader? = nil) {
        let info = bundle.infoDictionary
        self.init(bundleID: info?["CFBundleIdentifier"] as? String ?? "",
                  build: Self.integer(info?["CFBundleVersion"]), loader: loader)
    }

    /// The URL to check, read from an Info.plist dictionary. nil when the key is absent (the app has not adopted the check) or empty
    /// (the check is switched off), and also when the text is not a URL.
    static func url(from info: [String: Any]?) -> URL? {
        guard let text = (info?[infoKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return URL(string: text)
    }

    /// Reads the file at `url` and judges this build. Never throws and never takes much longer than ``timeout``.
    func fetch(url: URL) async -> Verdict {
        do {
            let (data, status) = try await load(url, Self.timeout)
            guard status == 200 else { return .unknown }
            return Self.judge(data: data, bundleID: bundleID, build: build)
        } catch {
            return .unknown
        }
    }

    /// The same check for the URL in an Info.plist dictionary; `.ok` when there is none to read.
    func fetch(info: [String: Any]?) async -> Verdict {
        guard let url = Self.url(from: info) else { return .ok }
        return await fetch(url: url)
    }

    /// The pure rule. Anything that is not schema 1, not an object, or has an entry of the wrong shape is `.unknown`.
    static func judge(data: Data, bundleID: String, build: Int?) -> Verdict {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              integer(root["schema"]) == 1, let apps = root["apps"] as? [String: Any] else { return .unknown }
        guard let build else { return .unknown }
        let stable = bundleID.hasSuffix(betaSuffix) ? String(bundleID.dropLast(betaSuffix.count)) : bundleID
        guard let raw = apps[stable] else { return .ok }
        guard let entry = raw as? [String: Any] else { return .unknown }

        var minimum: Int?
        if let value = entry["min_build"] {
            guard let number = integer(value) else { return .unknown }
            minimum = number
        }
        var broken: [Int] = []
        if let value = entry["broken_builds"] {
            guard let list = value as? [Any] else { return .unknown }
            for item in list {
                guard let number = integer(item) else { return .unknown }
                broken.append(number)
            }
        }
        if let minimum, build < minimum { return .broken("Build \(build) is older than the minimum good build \(minimum).") }
        if broken.contains(build) { return .broken("Build \(build) is on the list of broken builds.") }
        return .ok
    }

    /// An integer from a plist or JSON value: a number with no fraction, or a string of digits. Booleans are not numbers here.
    static func integer(_ value: Any?) -> Int? {
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double == double.rounded() && abs(double) < 1e15 ? number.intValue : nil
    }

    private static let networkLoader: Loader = { url, timeout in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
// swiftlint:enable cyclomatic_complexity
