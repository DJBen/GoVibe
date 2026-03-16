import XCTest
@testable import GoVibeHostCore

final class GoVibeHostCoreTests: XCTestCase {
    func testHostedSessionConfigurationRoundTrip() throws {
        let original = HostedSessionConfiguration.terminal(
            TerminalSessionConfig(sessionId: "dev-shell", shellPath: "/bin/zsh", tmuxSessionName: "dev-shell")
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HostedSessionConfiguration.self, from: data)

        XCTAssertEqual(original, decoded)
    }

    @MainActor
    func testManagerPersistsCreatedTerminalSession() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let manager = HostSessionManager(defaults: defaults)
        manager.completeOnboarding(relayBase: "ws://localhost:8080/relay", defaultShellPath: "/bin/zsh", preferredSimulatorUDID: nil)

        manager.createTerminalSession(
            config: TerminalSessionConfig(sessionId: "session-1", shellPath: "/bin/zsh", tmuxSessionName: "session-1")
        )

        XCTAssertEqual(manager.listSessions().map(\.sessionId), ["session-1"])
        XCTAssertNotEqual(manager.listSessions().first?.state, .stopped)

        manager.stopSession(id: "session-1")
    }
}
