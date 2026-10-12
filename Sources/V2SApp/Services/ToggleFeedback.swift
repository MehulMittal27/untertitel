import AppKit

/// Confirmation that the global shortcut switched subtitles on or off. The popover is
/// usually closed when the shortcut is pressed, so the change has to announce itself.
enum SessionToggleFeedback: Equatable, Sendable {
    case on
    case off
}

/// What a press of the global shortcut does.
enum HotkeyToggleAction: Equatable, Sendable {
    case stop
    case start
    /// Nothing is selected and the last session's source is not running. The app never
    /// picks a source by itself, so the user is asked instead.
    case askForSource
    /// A start is already under way.
    case ignore

    static func resolve(isRunning: Bool, isStartPending: Bool, hasSelectedSource: Bool) -> HotkeyToggleAction {
        if isRunning {
            return .stop
        }

        if isStartPending {
            return .ignore
        }

        return hasSelectedSource ? .start : .askForSource
    }
}

@MainActor
protocol ToggleSoundPlaying {
    func play(_ feedback: SessionToggleFeedback)
}

/// Short built-in macOS sounds: a higher one for on, a lower one for off. They play on
/// the default output; the app only taps the call app's audio, so they are not
/// transcribed.
@MainActor
final class SystemToggleSoundPlayer: ToggleSoundPlaying {
    static let volume: Float = 0.5

    private var current: NSSound?

    static func soundName(for feedback: SessionToggleFeedback) -> NSSound.Name {
        switch feedback {
        case .on:
            return "Tink"
        case .off:
            return "Pop"
        }
    }

    func play(_ feedback: SessionToggleFeedback) {
        current?.stop()

        // A copy, so a quick second toggle does not cut into the shared instance.
        guard let sound = NSSound(named: Self.soundName(for: feedback))?.copy() as? NSSound else {
            return
        }

        sound.volume = Self.volume
        sound.play()
        current = sound
    }
}
