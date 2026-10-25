import XCTest
@testable import PocketPalette

final class SelfCheckTests: XCTestCase {
    func testReportNamesBundleAndBuild() {
        let build = BuildInfo(info: ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "45"])
        XCTAssertEqual(SelfCheck.report(bundleID: "com.example.app", build: build), "FMSelfCheck: ok com.example.app v1.2.3 (45)")
    }

    func testReportFailsWithoutABuildNumberOrBundleID() {
        XCTAssertNil(SelfCheck.report(bundleID: "com.example.app", build: BuildInfo(info: [:])))
        XCTAssertNil(SelfCheck.report(bundleID: nil, build: BuildInfo(info: ["CFBundleVersion": "1"])))
    }
}
