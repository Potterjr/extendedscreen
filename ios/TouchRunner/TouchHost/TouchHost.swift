import SwiftUI

/// The UI test's target app: Xcode wants one beside a UI-testing bundle.
/// The runner never uses it (it drives SpringBoard).
@main
struct TouchHost: App {
    var body: some Scene {
        WindowGroup { Text("TouchRunner host") }
    }
}
