import CryptoKit
import FirebaseAuth
import UIKit

enum LocalDevice {
    static var iosDeviceID: String {
        let baseID = UIDevice.current.identifierForVendor?.uuidString ?? "ios-demo-01"
        guard let userID = Auth.auth().currentUser?.uid, !userID.isEmpty else {
            return baseID
        }

        let digest = SHA256.hash(data: Data("\(userID)|\(baseID)".utf8))
        let scopedSuffix = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "ios-\(scopedSuffix)"
    }
}
