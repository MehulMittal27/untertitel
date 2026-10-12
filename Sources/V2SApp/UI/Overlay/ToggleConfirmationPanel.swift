import AppKit
import SwiftUI

enum ToggleConfirmationLayout {
    static let gap: CGFloat = 10
    static let fadeInDuration: TimeInterval = 0.15
    static let holdDuration: TimeInterval = 1.0
    static let fadeOutDuration: TimeInterval = 0.3

    /// Centered just under the caption area, or just above it when there is no room
    /// below, and always fully on screen. Beside the captions rather than on top of
    /// them: when subtitles switch on, the first caption appears at the same moment.
    static func frame(size: CGSize, captionArea: NSRect, visibleFrame: NSRect) -> NSRect {
        var originY = captionArea.minY - gap - size.height
        if originY < visibleFrame.minY {
            originY = captionArea.maxY + gap
        }
        originY = min(max(originY, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - size.height))

        let centeredX = captionArea.midX - (size.width / 2)
        let originX = min(max(centeredX, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - size.width))

        return NSRect(x: originX, y: originY, width: size.width, height: size.height)
    }
}

/// "Subtitles on" / "Subtitles off", styled like the caption block.
struct ToggleConfirmationView: View {
    let feedback: SessionToggleFeedback
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: feedback == .on ? "captions.bubble.fill" : "captions.bubble")
                .opacity(feedback == .on ? 1 : 0.7)
                .accessibilityHidden(true)
            Text(text)
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(
            Color.black.opacity(0.78),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .fixedSize()
    }
}

/// Shows the confirmation in its own small window, because "Subtitles off" appears
/// when the overlay itself has just been hidden.
@MainActor
final class ToggleConfirmationController {
    private let panel: NSPanel
    private var dismissTask: Task<Void, Never>?

    init(level: NSWindow.Level, collectionBehavior: NSWindow.CollectionBehavior) {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.level = level
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = collectionBehavior
        panel.alphaValue = 0
    }

    func show(
        _ feedback: SessionToggleFeedback,
        text: String,
        captionArea: NSRect,
        visibleFrame: NSRect,
        sharingType: NSWindow.SharingType
    ) {
        dismissTask?.cancel()

        let hostingView = NSHostingView(rootView: ToggleConfirmationView(feedback: feedback, text: text))
        panel.contentView = hostingView
        panel.sharingType = sharingType
        panel.setFrame(
            ToggleConfirmationLayout.frame(
                size: hostingView.fittingSize,
                captionArea: captionArea,
                visibleFrame: visibleFrame
            ),
            display: true
        )
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = ToggleConfirmationLayout.fadeInDuration
            panel.animator().alphaValue = 1
        }

        dismissTask = Task { [weak self] in
            let visibleTime = ToggleConfirmationLayout.fadeInDuration + ToggleConfirmationLayout.holdDuration
            try? await Task.sleep(nanoseconds: UInt64(visibleTime * 1_000_000_000))
            guard Task.isCancelled == false, let self else { return }

            await NSAnimationContext.runAnimationGroup { context in
                context.duration = ToggleConfirmationLayout.fadeOutDuration
                self.panel.animator().alphaValue = 0
            }
            // A newer confirmation took over while this one was fading.
            guard Task.isCancelled == false else { return }
            self.panel.orderOut(nil)
        }
    }

#if DEBUG
    var frameForTesting: NSRect { panel.frame }
    var isVisibleForTesting: Bool { panel.isVisible }
    var sharingTypeForTesting: NSWindow.SharingType { panel.sharingType }
#endif
}
