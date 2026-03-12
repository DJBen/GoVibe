import FirebaseCore
import Foundation

public enum GoVibeBootstrap {
    public static func configureFirebaseIfNeeded() {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
    }
}
