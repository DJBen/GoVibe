import Foundation

final class Logger {
    private let queue = DispatchQueue(label: "govibe.cli.logger")

    func info(_ message: String) {
        log(level: "INFO", message: message)
    }

    func error(_ message: String) {
        log(level: "ERROR", message: message)
    }

    private func log(level: String, message: String) {
        queue.sync {
            let ts = ISO8601DateFormatter().string(from: Date())
            print("[\(ts)] [\(level)] \(message)")
            fflush(stdout)
        }
    }
}
