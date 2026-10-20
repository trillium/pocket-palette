import Foundation

/// Chooses the widget's rows with the app's own ranking: an empty query, context boost on, run history on.
/// Commands that need a spoken value (lists/captures with no literal phrase) are skipped, since a widget tap
/// has nowhere to ask for it.
enum WidgetPicker {
    static func snapshot(
        index: CommandIndex, appName: String?, dryRun: Bool, history: ExecuteHistory, now: Date,
        limit: Int = WidgetSnapshot.limit
    ) -> WidgetSnapshot {
        let options = SearchOptions(contextBoost: true, history: history, now: now)
        let picks = index.search("", options: options)
            .filter { $0.spoken != nil }
            .prefix(limit)
            .map { match in
                let command = match.command
                return WidgetSnapshot.Item(id: command.id, rule: command.rule, context: command.contextName, scope: command.scope.rawValue)
            }
        return WidgetSnapshot(items: Array(picks), appName: appName, dryRun: dryRun, updatedAt: now)
    }
}
