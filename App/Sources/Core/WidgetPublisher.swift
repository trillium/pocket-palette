import Foundation
import WidgetKit

/// Where the model sends the widget's rows. A protocol so tests can record snapshots without WidgetKit.
protocol WidgetPublishing: Sendable {
    func publish(_ snapshot: WidgetSnapshot)
}

/// Writes the App Group snapshot and asks WidgetKit to reload, only when the rows actually changed.
struct AppGroupWidgetPublisher: WidgetPublishing {
    var store: WidgetSnapshotStore = .shared

    func publish(_ snapshot: WidgetSnapshot) {
        if store.save(snapshot) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

/// Default for tests and previews: publishes nothing.
struct NoWidgetPublisher: WidgetPublishing {
    func publish(_ snapshot: WidgetSnapshot) {}
}
