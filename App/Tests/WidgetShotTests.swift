import SwiftUI
import WidgetKit
import XCTest
@testable import PocketPalette

/// Renders the widget's real SwiftUI views (Widget/PaletteWidget.swift) at each family's size into one PNG.
/// This is NOT a WidgetKit host render; it only runs when WIDGET_SHOT_DIR is set (make widget-shot).
@MainActor
final class WidgetShotTests: XCTestCase {
    private func sized(_ family: WidgetFamily, _ size: CGSize, _ snapshot: WidgetSnapshot, dark: Bool) -> some View {
        PaletteWidgetContent(entry: PaletteEntry(date: Date(), snapshot: snapshot), family: family)
            .padding(family == .accessoryInline ? 0 : 14)  // the margin WidgetKit's container adds
            .frame(width: size.width, height: size.height)
            .background(dark ? Color(white: 0.12) : Color(white: 0.96))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .environment(\.colorScheme, dark ? .dark : .light)
    }

    func testRenderWidgetFamilies() throws {
        guard let dir = ProcessInfo.processInfo.environment["WIDGET_SHOT_DIR"] else {
            throw XCTSkip("set WIDGET_SHOT_DIR to render the widget screenshot")
        }
        let snapshot = WidgetSnapshot(
            items: [
                .init(id: "a", rule: "tab (open | new)", context: "browser.voice", scope: "app"),
                .init(id: "b", rule: "go back", context: "browser.voice", scope: "app"),
                .init(id: "c", rule: "page down", context: "scroll.voice", scope: "global")
            ],
            appName: "Safari", dryRun: true, updatedAt: Date()
        )
        let page = VStack(spacing: 16) {
            HStack(spacing: 16) {
                sized(.systemSmall, CGSize(width: 170, height: 170), snapshot, dark: false)
                sized(.systemMedium, CGSize(width: 364, height: 170), snapshot, dark: false)
            }
            HStack(spacing: 16) {
                sized(.accessoryRectangular, CGSize(width: 170, height: 76), snapshot, dark: true)
                sized(.accessoryInline, CGSize(width: 220, height: 28), snapshot, dark: true)
                sized(.systemSmall, CGSize(width: 170, height: 170), .empty, dark: true)
            }
        }
        .padding(20)
        .background(Color(white: 0.8))
        let renderer = ImageRenderer(content: page)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage)
        let data = try XCTUnwrap(image.pngData())
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("widget-families.png"))
    }
}
