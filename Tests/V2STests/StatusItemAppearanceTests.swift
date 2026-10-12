import AppKit
import XCTest
@testable import v2s

final class StatusItemAppearanceTests: XCTestCase {
    private func appearance(_ sessionState: SessionState, _ cloudState: CloudEngineState? = nil) -> StatusItemAppearance {
        StatusItemAppearance.resolve(sessionState: sessionState, cloudEngineState: cloudState)
    }

    func testIdleIsThePlainOutlineIcon() {
        XCTAssertEqual(
            appearance(.idle),
            StatusItemAppearance(symbolName: "captions.bubble", tint: .template, title: "")
        )
    }

    func testOnDeviceSessionIsFilledAndTinted() {
        XCTAssertEqual(
            appearance(.running),
            StatusItemAppearance(symbolName: "captions.bubble.fill", tint: .running, title: "")
        )
    }

    func testConnectedCloudSessionIsMarkedAsBilling() {
        let streaming = appearance(.running, .streaming)

        XCTAssertEqual(streaming, StatusItemAppearance(symbolName: "captions.bubble.fill", tint: .billing, title: "$"))
        XCTAssertEqual(appearance(.running, .reconnecting), streaming, "a connection being opened is about to bill")
    }

    func testPausedCloudSessionLooksRunningButNotBilling() {
        let paused = appearance(.running, .pausedNoAudio)

        XCTAssertEqual(paused, StatusItemAppearance(symbolName: "pause.circle.fill", tint: .running, title: ""))
        XCTAssertNotEqual(paused.tint, .billing)
    }

    func testEveryRunningStateDiffersFromIdleAndFromEachOther() {
        let states = [
            appearance(.idle),
            appearance(.running),
            appearance(.running, .streaming),
            appearance(.running, .pausedNoAudio),
            appearance(.error),
        ]

        for (index, state) in states.enumerated() {
            for other in states[(index + 1)...] {
                XCTAssertNotEqual(state, other)
            }
        }
    }

    func testBillingIsNotSignalledByColorAlone() {
        XCTAssertEqual(appearance(.running, .streaming).title, "$")
        XCTAssertEqual(appearance(.running).title, "")
    }

    func testStoppedOrFailedSessionsNeverLookLikeBilling() {
        XCTAssertEqual(appearance(.idle, .streaming).tint, .template, "a stale cloud state cannot outlive the session")
        XCTAssertEqual(appearance(.error, .streaming).tint, .template)
        XCTAssertEqual(appearance(.running, .stoppedAfterLongPause).tint, .template)
    }

    /// Average color of the icon's visible pixels, in sRGB.
    private func averageColor(of image: NSImage) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let size = 64
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()

        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, weight: CGFloat = 0
        for x in 0..<size {
            for y in 0..<size {
                guard let pixel = rep.colorAt(x: x, y: y), pixel.alphaComponent > 0.5 else { continue }
                red += pixel.redComponent
                green += pixel.greenComponent
                blue += pixel.blueComponent
                weight += 1
            }
        }
        XCTAssertGreaterThan(weight, 0, "the icon drew nothing")
        return (red / weight, green / weight, blue / weight)
    }

    func testRunningIconIsActuallyGreenAndBillingIconActuallyOrange() throws {
        let running = try averageColor(of: try XCTUnwrap(appearance(.running).makeImage()))
        XCTAssertGreaterThan(running.green, 0.5)
        XCTAssertGreaterThan(running.green, running.red + 0.2, "green, not black or gray")

        let billing = try averageColor(of: try XCTUnwrap(appearance(.running, .streaming).makeImage()))
        XCTAssertGreaterThan(billing.red, 0.7)
        XCTAssertGreaterThan(billing.red, billing.blue + 0.4, "orange, not black or gray")
        XCTAssertGreaterThan(billing.red, billing.green + 0.1)
    }

    func testTintedIconsAreNotTemplateImages() {
        XCTAssertEqual(appearance(.idle).makeImage()?.isTemplate, true)
        XCTAssertEqual(appearance(.running).makeImage()?.isTemplate, false)
        XCTAssertEqual(appearance(.running, .streaming).makeImage()?.isTemplate, false)
        XCTAssertNotNil(appearance(.running, .pausedNoAudio).makeImage())
    }
}
