import AppKit
import SwiftUI

struct LogPage: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(14)
                }
                .overlay {
                    if model.logLines.isEmpty {
                        ContentUnavailableView("No Log Entries", systemImage: "text.alignleft")
                    }
                }
                .onChange(of: model.logLines.count) {
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }
            Divider()
            Text("The log never contains passwords.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logLines.joined(separator: "\n"), forType: .string)
                } label: {
                    Label("Copy Log", systemImage: "doc.on.doc")
                }
                .disabled(model.logLines.isEmpty)

                Button {
                    model.clearLog()
                } label: {
                    Label("Clear Log", systemImage: "trash")
                }
                .disabled(model.logLines.isEmpty)
            }
        }
    }
}
