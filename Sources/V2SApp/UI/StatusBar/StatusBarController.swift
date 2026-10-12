import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let openAdvancedSettings: () -> Void
    private let showTranscript: () -> Void
    private let quitApp: () -> Void
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let outsideClickMonitor = PopoverOutsideClickMonitor()
    private var cancellables = Set<AnyCancellable>()
    private var activeSpaceObserver: NSObjectProtocol?

    /// Lets the popover window appear on whichever desktop is in front, including
    /// over a full-screen app.
    ///
    /// By default the window stays on the desktop (Space) it was first shown on. With
    /// another app in front on a different desktop, `NSPopover` then reports the
    /// popover as shown while nothing is on screen, and the next click on the status
    /// item closes a popover the user never saw.
    static let popoverCollectionBehavior: NSWindow.CollectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

    init(
        model: AppModel,
        openAdvancedSettings: @escaping () -> Void,
        showTranscript: @escaping () -> Void,
        quitApp: @escaping () -> Void
    ) {
        self.model = model
        self.openAdvancedSettings = openAdvancedSettings
        self.showTranscript = showTranscript
        self.quitApp = quitApp
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureStatusItem()
        configurePopover()
        bindModel()
        observeActiveSpace()
        updateStatusItem(
            .resolve(sessionState: model.sessionState, cloudEngineState: model.cloudEngineState)
        )
    }

    deinit {
        if let activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.action = #selector(togglePopover(_:))
        button.target = self
        button.imagePosition = .imageOnly
        button.toolTip = "v2s"
    }

    private func configurePopover() {
        popover.delegate = self
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 500)
        applySystemAppearance()
    }

    /// Pins the popover to the system light/dark appearance.
    ///
    /// Left unset, the popover's glass backdrop derives its appearance from
    /// whatever sits behind it, so a bright wallpaper makes the content draw in
    /// light mode while the system is in dark mode.
    private func applySystemAppearance() {
        popover.appearance = NSApp.effectiveAppearance
    }

    private func bindModel() {
        Publishers.CombineLatest(model.$sessionState, model.$cloudEngineState)
            .map { StatusItemAppearance.resolve(sessionState: $0, cloudEngineState: $1) }
            .removeDuplicates()
            .sink { [weak self] appearance in
                self?.updateStatusItem(appearance)
            }
            .store(in: &cancellables)

        // The tooltip repeats the status line, so hovering answers "what is it doing".
        model.$statusMessage
            .sink { [weak self] message in
                self?.statusItem.button?.toolTip = message.isEmpty ? "v2s" : "v2s - \(message)"
            }
            .store(in: &cancellables)
    }

    private func updateStatusItem(_ appearance: StatusItemAppearance) {
        guard let button = statusItem.button else {
            return
        }

        button.image = appearance.makeImage()
        button.title = appearance.title
        button.imagePosition = appearance.title.isEmpty ? .imageOnly : .imageLeading
    }

    /// Screen rect of the status bar button, for animation targeting.
    var statusItemScreenRect: NSRect? {
        guard let button = statusItem.button,
              let window = button.window else { return nil }
        let rect = button.convert(button.bounds, to: nil)
        return window.convertToScreen(rect)
    }

    @objc
    private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            // Still open, but on a desktop the user has left: closing it would look
            // like the click did nothing. Bring it to this desktop instead.
            if let window = popoverWindow, window.isOnActiveSpace == false {
                movePopoverToActiveSpace()
                return
            }

            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    /// Opens the popover on the desktop in front, or brings it there if it is already
    /// open. Used by the status item and when the shortcut needs the user's attention.
    func showPopover() {
        guard let button = statusItem.button else {
            return
        }

        if popover.isShown {
            movePopoverToActiveSpace()
        } else {
            model.refreshSources()
            applySystemAppearance()
            popover.contentViewController = NSHostingController(
                rootView: StatusBarPopoverView(
                    model: model,
                    closePopover: { [weak self] in
                        self?.popover.performClose(nil)
                    },
                    openAdvancedSettings: { [weak self] in
                        self?.popover.performClose(nil)
                        self?.openAdvancedSettings()
                    },
                    showTranscript: { [weak self] in
                        self?.popover.performClose(nil)
                        self?.showTranscript()
                    },
                    quitApp: { [weak self] in
                        self?.popover.performClose(nil)
                        self?.quitApp()
                    }
                )
            )
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            movePopoverToActiveSpace()
        }
    }

    private var popoverWindow: NSWindow? {
        popover.contentViewController?.view.window
    }

    /// Makes sure the popover is on the desktop the user is looking at.
    private func movePopoverToActiveSpace() {
        guard let window = popoverWindow else {
            return
        }

        Self.placeOnActiveSpace(window)
    }

    static func placeOnActiveSpace(_ window: NSWindow) {
        window.collectionBehavior.insert(popoverCollectionBehavior)
        if window.isOnActiveSpace == false {
            window.orderFrontRegardless()
        }
    }

    /// A popover left open stays behind when the user switches desktops. Close it, as
    /// a click elsewhere would, so the next click on the status item opens it afresh.
    private func observeActiveSpace() {
        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown else {
                    return
                }

                self.popover.performClose(nil)
            }
        }
    }

    func popoverWillShow(_ notification: Notification) {
        // Set before the window is ordered in, so it appears on the right desktop
        // from its first frame once the window exists.
        popoverWindow?.collectionBehavior.insert(Self.popoverCollectionBehavior)

        outsideClickMonitor.start(
            shouldIgnoreClick: { [weak self] screenPoint in
                self?.clickShouldKeepPopoverOpen(at: screenPoint) ?? true
            },
            onOutsideClick: { [weak self] in
                guard let self, self.popover.isShown else {
                    return
                }

                self.popover.performClose(nil)
            }
        )
    }

    func popoverDidClose(_ notification: Notification) {
        outsideClickMonitor.stop()
        popover.contentViewController = nil
    }

    private func clickShouldKeepPopoverOpen(at screenPoint: NSPoint) -> Bool {
        statusItemScreenRect?.contains(screenPoint) == true
            || popover.contentViewController?.view.window?.frame.contains(screenPoint) == true
    }
}
