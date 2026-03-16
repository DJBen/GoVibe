import Testing
@testable import GoVibeFeature

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
