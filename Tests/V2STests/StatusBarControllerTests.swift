import AppKit
import XCTest
@testable import v2s

final class StatusBarControllerTests: XCTestCase {
    /// A popover window that keeps the default behavior stays on the desktop it was
    /// first shown on, so clicking the status item from another desktop shows nothing.
    @MainActor
    func testPopoverWindowIsAllowedOntoTheActiveDesktopAndOverFullScreenApps() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.ignoresCycle]

        StatusBarController.placeOnActiveSpace(window)

        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(window.collectionBehavior.contains(.ignoresCycle), "existing behavior is kept")
        window.orderOut(nil)
    }
}
