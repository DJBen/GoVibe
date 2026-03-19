import UIKit

enum LocalDevice {
    static var iosDeviceID: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "ios-demo-01"
    }
}
