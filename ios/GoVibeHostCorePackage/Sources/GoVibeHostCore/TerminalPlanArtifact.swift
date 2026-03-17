import Foundation

struct TerminalPlanArtifact: Equatable, Sendable {
    let assistant: String
    let turnId: String
    let title: String?
    let markdown: String
    let blockCount: Int
}

enum TerminalPlanParser {
    private static let planPattern = #"<proposed_plan>\s*(.*?)\s*</proposed_plan>"#

    static func parseArtifact(assistant: String, turnId: String, text: String) -> TerminalPlanArtifact? {
        let blocks = extractProposedPlanBlocks(from: text)
        guard !blocks.isEmpty else { return nil }
        let markdown = concatenatePlanBlocks(blocks)
        return TerminalPlanArtifact(
            assistant: assistant,
            turnId: turnId,
            title: derivePlanTitle(from: markdown),
            markdown: markdown,
            blockCount: blocks.count
        )
    }

    static func extractProposedPlanBlocks(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: planPattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let blockRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            let block = text[blockRange].trimmingCharacters(in: .whitespacesAndNewlines)
            return block.isEmpty ? nil : block
        }
    }

    static func concatenatePlanBlocks(_ blocks: [String]) -> String {
        blocks.joined(separator: "\n\n---\n\n")
    }

    static func derivePlanTitle(from markdown: String) -> String? {
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("#") else { continue }
            let title = trimmed.drop { $0 == "#" || $0.isWhitespace }
            if !title.isEmpty {
                return String(title)
            }
        }
        return nil
    }
}
