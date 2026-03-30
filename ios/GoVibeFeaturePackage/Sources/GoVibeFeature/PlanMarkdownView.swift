import MarkdownUI
import SwiftUI

struct PlanMarkdownContentView: View {
    let plan: TerminalPlanState

    var body: some View {
        ScrollView {
            Markdown(plan.markdown)
                .markdownTheme(.gitHub)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(plan.title ?? "Plan")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PlanMarkdownSheet: View {
    let plan: TerminalPlanState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PlanMarkdownContentView(plan: plan)
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
}
