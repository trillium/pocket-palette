import SwiftUI

@main
struct PocketPaletteApp: App {
    @State private var model = PaletteModel(
        settings: UserDefaultsSettingsStore(),
        cache: DiskCommandCache.standard,
        widget: AppGroupWidgetPublisher()
    )

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onOpenURL { url in
                    guard let id = WidgetLink.commandID(in: url) else { return }
                    Task { await model.openFromWidget(commandID: id) }
                }
        }
    }
}
