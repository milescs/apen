import MenuBarExtraAccess
import SwiftUI


struct ApenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        @Bindable var model = appDelegate.model
        MenuBarExtra {
            MenuBarView(model: model, isPresented: $model.isMenuPresented)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraAccess(isPresented: $model.isMenuPresented)
        .menuBarExtraStyle(.window)
    }
}
