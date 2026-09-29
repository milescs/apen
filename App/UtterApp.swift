import MenuBarExtraAccess
import SwiftUI


struct UtterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var isMenuPresented = false

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: appDelegate.model, isPresented: $isMenuPresented)
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
        .menuBarExtraAccess(isPresented: $isMenuPresented)
        .menuBarExtraStyle(.window)
    }
}
