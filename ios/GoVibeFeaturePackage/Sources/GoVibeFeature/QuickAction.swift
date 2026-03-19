import Foundation

struct QuickAction: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let payloads: [Data]
    var isDestructive: Bool = false

    static func actions(for paneProgram: String) -> [QuickAction] {
        switch paneProgram {
        case "Claude":
            return claudeActions
        case "Codex":
            return codexActions
        case "Gemini":
            return geminiActions
        default:
            return []
        }
    }

    private static let codexActions: [QuickAction] = [
        QuickAction(
            title: "Cycle Mode",
            systemImage: "arrow.triangle.2.circlepath",
            payloads: [Data([0x1B, 0x5B, 0x5A])]  // Shift+Tab (ESC[Z) — rotates ask/auto/full-auto
        ),
        QuickAction(
            title: "Exit Codex",
            systemImage: "xmark.circle",
            payloads: [Data([0x03]), Data([0x03])],  // Ctrl+C × 2
            isDestructive: true
        ),
    ]

    private static let geminiActions: [QuickAction] = [
        QuickAction(
            title: "Cycle Mode",
            systemImage: "arrow.triangle.2.circlepath",
            payloads: [Data([0x1B, 0x5B, 0x5A])]  // Shift+Tab (ESC[Z)
        ),
        QuickAction(
            title: "Exit Gemini",
            systemImage: "xmark.circle",
            payloads: [Data([0x03]), Data([0x03])],  // Ctrl+C × 2
            isDestructive: true
        ),
    ]

    private static let claudeActions: [QuickAction] = [
        QuickAction(
            title: "Cycle Mode",
            systemImage: "arrow.triangle.2.circlepath",
            payloads: [Data([0x1B, 0x5B, 0x5A])]  // Shift+Tab (ESC[Z)
        ),
        QuickAction(
            title: "Exit Claude",
            systemImage: "xmark.circle",
            payloads: [Data([0x03]), Data([0x03])],  // Ctrl+C × 2 (separate writes)
            isDestructive: true
        ),
    ]
}
