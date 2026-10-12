import SwiftUI

struct SessionActionButtonLabel: View {
    let title: String
    let symbolName: String
    let showsActivity: Bool
    /// The global shortcut for the same action, shown after the title: "⌃⌥T".
    var shortcutHint: String?

    var body: some View {
        HStack(spacing: 6) {
            if showsActivity {
                SessionWaitIndicator()
                    .transition(.identity)
            } else {
                Image(systemName: symbolName)
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
                    .transition(.identity)
            }
            if let shortcutHint {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                    Text(shortcutHint)
                        .font(.caption.weight(.medium))
                        .opacity(0.75)
                        .accessibilityHidden(true)
                }
            } else {
                Text(title)
            }
        }
    }
}

private struct SessionWaitIndicator: View {
    @State private var rotation: Double = 0

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 11, weight: .semibold))
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
            .accessibilityHidden(true)
    }
}
