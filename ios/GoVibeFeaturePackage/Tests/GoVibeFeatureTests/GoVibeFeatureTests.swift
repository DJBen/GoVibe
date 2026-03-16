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
