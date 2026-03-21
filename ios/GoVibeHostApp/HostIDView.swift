import SwiftUI
import AppKit

struct HostIDView: View {
    let hostId: String
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Device ID", systemImage: "iphone")
                .font(.headline)

            Text("Internal machine identifier used for discovery, ownership, and relay routing.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(hostId)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 8) {
                Button("Copy Device ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hostId, forType: .string)
                    didCopy = true
                }
                .buttonStyle(.borderedProminent)

                if didCopy {
                    Text("Copied")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
