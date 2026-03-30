import SwiftUI

struct ArtifactListView: View {
    let artifacts: [TerminalPlanState]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(artifacts) { artifact in
                NavigationLink {
                    PlanMarkdownContentView(plan: artifact)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(artifact.title ?? "Untitled Plan")
                            .font(.headline)
                        Text(artifact.assistant)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(artifact.blockCount) block\(artifact.blockCount == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Artifacts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
