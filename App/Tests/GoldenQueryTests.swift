import XCTest
@testable import PocketPalette

/// Top-3 accuracy of `CommandIndex` over spoken-style queries against a fixed ~100-rule fixture.
/// Data: `App/Tests/Golden/{commands,queries}.json` (read via #filePath; the simulator shares the host disk).
/// Method and history: docs/golden-queries.md.
final class GoldenQueryTests: XCTestCase {
    static let threshold = 0.90

    private struct CommandsFile: Decodable { let commands: [PaletteCommand] }
    private struct Golden: Decodable { let query: String; let expect: [String] }
    private struct QueriesFile: Decodable { let queries: [Golden] }

    private func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Golden")
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: dir.appendingPathComponent(name)))
    }

    func testTop3AccuracyMeetsThreshold() throws {
        let commands = try load("commands.json", as: CommandsFile.self).commands
        let queries = try load("queries.json", as: QueriesFile.self).queries
        XCTAssertGreaterThanOrEqual(commands.count, 100)
        XCTAssertEqual(queries.count, 30)
        let index = CommandIndex(commands)
        var failures = [String]()
        for golden in queries {
            let top = index.search(golden.query, limit: 3).map(\.command)
            if !top.contains(where: { golden.expect.contains($0.id) }) {
                let got = top.map { "\($0.id) \"\($0.rule)\"" }.joined(separator: ", ")
                let want = golden.expect.compactMap { id in commands.first { $0.id == id }?.rule }.joined(separator: " | ")
                failures.append("  \"\(golden.query)\" wanted [\(want)] got [\(got)]")
            }
        }
        let accuracy = Double(queries.count - failures.count) / Double(queries.count)
        print("GOLDEN top-3 accuracy: \(queries.count - failures.count)/\(queries.count) = \(Int((accuracy * 100).rounded()))%")
        if !failures.isEmpty { print("GOLDEN failing queries:\n" + failures.joined(separator: "\n")) }
        XCTAssertGreaterThanOrEqual(
            accuracy, Self.threshold,
            "top-3 accuracy \(accuracy) < \(Self.threshold); failing queries:\n" + failures.joined(separator: "\n")
        )
    }
}
