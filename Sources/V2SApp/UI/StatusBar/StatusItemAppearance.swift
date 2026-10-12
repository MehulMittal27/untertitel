import AppKit

/// How the menu-bar icon looks in each state, so whether a session is running, and
/// whether it is costing money, can be read without opening the popover.
struct StatusItemAppearance: Equatable {
    enum Tint: Equatable {
        /// Follows the menu bar's own color: nothing is running.
        case template
        /// A session is running and nothing is being billed.
        case running
        /// A cloud session is connected, so audio time is being billed.
        case billing
        /// A session is running but hears nothing although its source is playing.
        case warning

        var color: NSColor? {
            switch self {
            case .template:
                return nil
            case .running:
                return .systemGreen
            case .billing:
                return .systemOrange
            case .warning:
                return .systemYellow
            }
        }
    }

    let symbolName: String
    let tint: Tint
    /// Text beside the icon. Marks billing without relying on color alone.
    let title: String

    static func resolve(
        sessionState: SessionState,
        cloudEngineState: CloudEngineState?,
        hasOpenCloudConnection: Bool = false,
        isCaptureSilent: Bool = false
    ) -> StatusItemAppearance {
        // An open connection may be billing, whatever the session believes. This wins
        // over every other state, so the icon cannot read "off" while one is open.
        if hasOpenCloudConnection {
            return StatusItemAppearance(symbolName: "captions.bubble.fill", tint: .billing, title: "$")
        }

        // Running, but the capture is broken: nothing will be transcribed until the
        // user does something about it, so it must not look like an ordinary session.
        if sessionState == .running, isCaptureSilent {
            return StatusItemAppearance(symbolName: "exclamationmark.triangle.fill", tint: .warning, title: "")
        }

        switch sessionState {
        case .idle:
            return StatusItemAppearance(symbolName: "captions.bubble", tint: .template, title: "")
        case .error:
            return StatusItemAppearance(symbolName: "exclamationmark.bubble", tint: .template, title: "")
        case .running:
            switch cloudEngineState {
            case nil:
                return StatusItemAppearance(symbolName: "captions.bubble.fill", tint: .running, title: "")
            case .streaming, .reconnecting:
                // Reconnecting counts as billing: the connection is being opened.
                return StatusItemAppearance(symbolName: "captions.bubble.fill", tint: .billing, title: "$")
            case .waitingForAudio:
                // The session is on, the source is silent, and no connection is open.
                return StatusItemAppearance(symbolName: "speaker.slash.fill", tint: .running, title: "")
            case .pausedNoAudio:
                // The session is alive but its connection is closed: nothing is billed.
                return StatusItemAppearance(symbolName: "pause.circle.fill", tint: .running, title: "")
            case .stoppedAfterLongPause:
                return StatusItemAppearance(symbolName: "captions.bubble", tint: .template, title: "")
            }
        }
    }

    func makeImage() -> NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Untertitel status icon")
        guard let color = tint.color else {
            image?.isTemplate = true
            return image
        }

        guard let image else {
            return nil
        }

        // Drawn into its own image so the color holds wherever the icon is shown: a
        // symbol's palette configuration is dropped as soon as anything reconfigures it.
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        tinted.accessibilityDescription = image.accessibilityDescription
        return tinted
    }
}
