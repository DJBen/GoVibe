import Testing
@testable import GoVibeFeature

@MainActor
@Test func appConfigPersistsSavedRelayHost() async throws {
    let suiteName = "GoVibeFeatureTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)

    let config = AppConfig(defaults: defaults, bundle: .main)
    config.save(relay: " govibe-relay.run.app ")

    let reloadedConfig = AppConfig(defaults: defaults, bundle: .main)

    #expect(reloadedConfig.relayHost == "govibe-relay.run.app")
}

// Both axes normalized by min(width, height) so equal finger movements
// produce equal cursor deltas regardless of direction.
@Test func simulatorGestureMathNormalizesTranslationsByMinDimension() async throws {
    // bounds 180×120 → min = 120
    let delta = try #require(
        SimulatorGestureMath.normalizedTranslation(
            CGPoint(x: 45, y: -30),
            in: CGRect(x: 0, y: 0, width: 180, height: 120)
        )
    )

    #expect(delta.x == 45.0 / 120.0)   // 0.375
    #expect(delta.y == -30.0 / 120.0)  // -0.25
}

@Test func simulatorGestureMathIsotropic() async throws {
    // Equal displacement in x and y should produce equal normalized deltas.
    // bounds 200×400 → min = 200
    let delta = try #require(
        SimulatorGestureMath.normalizedTranslation(
            CGPoint(x: 50, y: 50),
            in: CGRect(x: 0, y: 0, width: 200, height: 400)
        )
    )

    #expect(delta.x == delta.y)
}

@Test func simulatorGestureMathBuildsDeltaFromTwoPoints() async throws {
    // bounds 120×60 → min = 60
    let delta = try #require(
        SimulatorGestureMath.normalizedDelta(
            from: CGPoint(x: 10, y: 50),
            to: CGPoint(x: 70, y: 20),
            in: CGRect(x: 0, y: 0, width: 120, height: 60)
        )
    )

    #expect(delta.x == 60.0 / 60.0)   // 1.0
    #expect(delta.y == -30.0 / 60.0)  // -0.5
}

@Test func swipeUpMapsToNegativeVisibleRows() async throws {
    let mapper = TerminalScrollGestureMapper()
    let lines = mapper.pageLines(for: .up, visibleRows: 24, previousDirection: nil)

    #expect(lines == -24)
}

@Test func swipeDownMapsToPositiveVisibleRows() async throws {
    let mapper = TerminalScrollGestureMapper()
    let lines = mapper.pageLines(for: .down, visibleRows: 32, previousDirection: nil)

    #expect(lines == 32)
}

@Test func reversedSwipeTrimsTwoLinesFromNewDirection() async throws {
    let mapper = TerminalScrollGestureMapper()

    let lines = mapper.pageLines(for: .down, visibleRows: 27, previousDirection: .up)

    #expect(lines == 25)
}

@Test func repeatedSwipeInSameDirectionKeepsFullPage() async throws {
    let mapper = TerminalScrollGestureMapper()

    let lines = mapper.pageLines(for: .up, visibleRows: 27, previousDirection: .up)

    #expect(lines == -27)
}

@Test func foregroundNotificationPayloadPrefersRoomIdFromUserInfo() async throws {
    let payload = ForegroundNotificationPayload(
        userInfo: [
            "event": "claude_turn_complete",
            "roomId": "ios-dev"
        ],
        title: "Claude finished",
        body: "Claude is waiting for your next prompt."
    )

    #expect(payload.roomId == "ios-dev")
    #expect(payload.title == "Claude finished")
    #expect(payload.body == "Claude is waiting for your next prompt.")
    #expect(payload.event == "claude_turn_complete")
}

@Test func foregroundNotificationPayloadFallsBackToEventCopy() async throws {
    let payload = ForegroundNotificationPayload(
        userInfo: [
            "event": "claude_approval_required",
            "room": "mac-mini"
        ],
        title: nil,
        body: ""
    )

    #expect(payload.roomId == "mac-mini")
    #expect(payload.title == "Unblock Claude now")
    #expect(payload.body == "Claude requires your decision before proceeding")
}

@Test func foregroundNotificationPayloadUsesCodexApprovalCopy() async throws {
    let payload = ForegroundNotificationPayload(
        userInfo: [
            "event": "codex_approval_required",
            "roomId": "server-prod"
        ],
        title: nil,
        body: nil
    )

    #expect(payload.roomId == "server-prod")
    #expect(payload.title == "Unblock Codex now")
    #expect(payload.body == "Codex requires your decision before proceeding")
}
