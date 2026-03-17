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

    func testPlanParserExtractsSingleBlock() {
        let text = """
        before
        <proposed_plan>
        # Ship It

        Do the thing.
        </proposed_plan>
        after
        """

        let artifact = TerminalPlanParser.parseArtifact(assistant: "Claude", turnId: "turn-1", text: text)

        XCTAssertEqual(artifact?.title, "Ship It")
        XCTAssertEqual(artifact?.blockCount, 1)
        XCTAssertEqual(artifact?.markdown, "# Ship It\n\nDo the thing.")
    }

    func testPlanParserConcatenatesMultipleBlocksInOrder() {
        let text = """
        <proposed_plan>
        # First
        Alpha
        </proposed_plan>
        noise
        <proposed_plan>
        ## Second
        Beta
        </proposed_plan>
        """

        let artifact = TerminalPlanParser.parseArtifact(assistant: "Codex", turnId: "turn-2", text: text)

        XCTAssertEqual(artifact?.blockCount, 2)
        XCTAssertEqual(artifact?.title, "First")
        XCTAssertEqual(artifact?.markdown, "# First\nAlpha\n\n---\n\n## Second\nBeta")
    }

    func testPlanParserReturnsNilWhenNoTaggedBlockExists() {
        let artifact = TerminalPlanParser.parseArtifact(
            assistant: "Claude",
            turnId: "turn-3",
            text: "plain response without plan tags"
        )

        XCTAssertNil(artifact)
    }
}
