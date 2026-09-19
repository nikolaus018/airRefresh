import SwiftUI

/// Monospaced, colour-coded console output that follows the build — until you
/// tell it not to.
struct LogView: View {
    let lines: [LogLine]

    /// Whether new output pulls the view down with it.
    ///
    /// Driven only by the button below. An earlier version inferred it from
    /// `onAppear`/`onDisappear` on the bottom anchor, which reads like the
    /// obvious thing to do and is a trap: the anchor lives inside a `LazyVStack`,
    /// so layout materialises it, the handler writes `@State`, that write forces
    /// another layout, and the main thread never comes back. A real build sat
    /// there looking hung at its eighth line.
    @State private var followsTail = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if lines.isEmpty {
                        Text("Nothing yet. Hit Refresh.")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(6)
                    }
                    ForEach(lines) { line in
                        Text(line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(for: line.kind))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(8)
            }
            // Keeps the view pinned to the end as wrapped lines are measured.
            // `scrollTo` alone lands short: rows the `LazyVStack` has not drawn
            // yet only have estimated heights, and xcodebuild's lines wrap.
            .defaultScrollAnchor(followsTail ? .bottom : .top)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )
            .overlay(alignment: .bottomTrailing) {
                if !lines.isEmpty { followButton(proxy) }
            }
            .onChange(of: lines.count) {
                guard followsTail else { return }
                // Deliberately not animated: output arrives in batches several
                // times a second, and animating each one queues overlapping
                // scrolls that never settle.
                scrollToTail(proxy)
            }
            // Opening the log after a run should show how it ended, not how it
            // began. This touches no state, so it cannot start the layout loop
            // described above.
            .onAppear {
                if followsTail { scrollToTail(proxy) }
            }
        }
        .accessibilityLabel("Build log")
    }

    private func followButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            followsTail.toggle()
            if followsTail { scrollToTail(proxy) }
        } label: {
            Image(systemName: followsTail ? "arrow.down.to.line.circle.fill"
                                          : "arrow.down.to.line.circle")
                .font(.system(size: 15))
                .foregroundStyle(followsTail ? Color.accentColor : Color.secondary)
                .padding(6)
        }
        .buttonStyle(.borderless)
        .background(.regularMaterial, in: Circle())
        .padding(8)
        .accessibilityLabel(followsTail ? "Stop following new output" : "Follow new output")
        .help(followsTail ? "Following new output — click to stay where you are."
                          : "Jump to the latest output and keep following it.")
    }

    private let bottomAnchor = "log-bottom"

    private func scrollToTail(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(bottomAnchor, anchor: .bottom)
    }

    private func color(for kind: LogLine.Kind) -> Color {
        switch kind {
        case .info: return .primary
        case .command: return .accentColor
        case .output: return .secondary
        case .success: return .green
        case .failure: return .red
        }
    }
}
