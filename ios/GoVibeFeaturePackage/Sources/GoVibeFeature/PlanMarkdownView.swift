import MarkdownUI
import SwiftUI

struct PlanMarkdownSheet: View {
    let plan: TerminalPlanState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Markdown(plan.markdown)
                    .markdownTheme(.gitHub)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
            }
            .background(sheetBackgroundColor)
            .navigationTitle(plan.title ?? "Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(
                        item: plan.markdown,
                        subject: Text(plan.title ?? "Plan")
                    ) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var sheetBackgroundColor: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .textBackgroundColor)
        #else
        Color.clear
        #endif
    }
}
