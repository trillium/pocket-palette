import SwiftUI

@main
struct PocketPaletteApp: App {
    @State private var model = PaletteModel(
        settings: UserDefaultsSettingsStore(),
        cache: DiskCommandCache.standard,
        widget: AppGroupWidgetPublisher()
    )

    init() { SelfCheck.runIfRequested() }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .onOpenURL { url in
                    guard let id = WidgetLink.commandID(in: url) else { return }
                    Task { await model.openFromWidget(commandID: id) }
                }
        }
    }
}
