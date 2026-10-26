import XCTest
@testable import PocketPalette

final class MinVersionTests: XCTestCase {
    private static let url = URL(string: "http://example.invalid/min-version.json")
    private func judge(_ json: String, id: String = "com.x.app", build: Int? = 5) -> MinVersionPolicy.Verdict {
        MinVersionPolicy.judge(data: Data(json.utf8), bundleID: id, build: build)
    }

    func testBelowMinimumIsBroken() {
        let json = #"{"schema":1,"apps":{"com.x.app":{"min_build":6}}}"#
        guard case .broken = judge(json) else { return XCTFail("expected broken") }
    }

    func testListedBuildIsBrokenAndBetaIdUsesStableEntry() {
        let json = #"{"schema":1,"apps":{"com.x.app":{"broken_builds":[5]}}}"#
        guard case .broken = judge(json, id: "com.x.app.beta") else { return XCTFail("expected broken") }
        XCTAssertEqual(judge(json, build: 6), .ok)
    }

    func testBadInputFailsOpen() {
        XCTAssertEqual(judge("not json"), .unknown)
        XCTAssertEqual(judge(#"{"schema":2,"apps":{}}"#), .unknown)
        XCTAssertEqual(judge(#"{"schema":1,"apps":{}}"#), .ok)
    }

    func testUnreachableFileIsUnknown() async {
        let policy = MinVersionPolicy(bundleID: "com.x.app", build: 1) { _, _ in throw URLError(.notConnectedToInternet) }
        let verdict = await policy.fetch(url: URL(string: "http://example.invalid/min-version.json")!)
        XCTAssertEqual(verdict, .unknown)
    }

    func testEmptyOrMissingURLDisablesTheCheck() {
        XCTAssertNil(MinVersionPolicy.url(from: ["MinVersionURL": ""]))
        XCTAssertNil(MinVersionPolicy.url(from: [:]))
    }

    func testForceBrokenArgumentWinsWithoutFetching() async {
        let verdict = await RootView.verdict(arguments: ["-FMForceBroken"], url: Self.url) { _ in XCTFail("fetched"); return .ok }
        guard case .broken = verdict else { return XCTFail("expected broken") }
    }

    func testWithoutArgumentThePolicyDecides() async {
        let unknown = await RootView.verdict(arguments: [], url: Self.url) { _ in .unknown }
        XCTAssertEqual(unknown, .unknown)
        let off = await RootView.verdict(arguments: [], url: nil) { _ in XCTFail("fetched"); return .unknown }
        XCTAssertEqual(off, .ok)
    }

    func testBuiltAppCarriesTheURLAndTheSingleHostException() {
        let info = Bundle.main.infoDictionary
        XCTAssertNotNil(MinVersionPolicy.url(from: info), "MinVersionURL missing or empty in the built Info.plist")
        let ats = info?["NSAppTransportSecurity"] as? [String: Any]
        XCTAssertNil(ats?["NSAllowsArbitraryLoads"])
        let domains = ats?["NSExceptionDomains"] as? [String: Any]
        XCTAssertNotNil(domains?[MinVersionPolicy.url(from: info)?.host ?? ""], "no ATS exception for the min-version host")
    }
}
