import Foundation

public final class HostLogger: @unchecked Sendable {
    private let sessionId: String
    private let printToStdout: Bool
    private let sink: (HostLogEntry) -> Void
    private let queue = DispatchQueue(label: "govibe.host.logger")

    public init(
        sessionId: String,
        printToStdout: Bool = false,
        sink: @escaping (HostLogEntry) -> Void
    ) {
        self.sessionId = sessionId
        self.printToStdout = printToStdout
        self.sink = sink
    }

    public func info(_ message: String) {
        log(level: .info, message: message)
    }

    public func error(_ message: String) {
        log(level: .error, message: message)
    }

    private func log(level: HostLogEntry.Level, message: String) {
        let entry = HostLogEntry(sessionId: sessionId, level: level, message: message)
        queue.async {
            self.sink(entry)
            guard self.printToStdout else { return }
            let ts = ISO8601DateFormatter().string(from: entry.timestamp)
            print("[\(ts)] [\(level.rawValue.uppercased())] \(message)")
            fflush(stdout)
        }
    }
}
