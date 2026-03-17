import SwiftUI
import Observation

public struct ContentView: View {
    private var config = AppConfig.shared

    public var body: some View {
        Group {
            if config.isValid {
                SessionListView()
            } else {
                AppConfigSetupView()
            }
        }
    }

    public init() {}
}
