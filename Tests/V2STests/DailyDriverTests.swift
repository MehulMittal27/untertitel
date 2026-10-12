import AppKit
import XCTest
@testable import v2s

@MainActor
final class DailyDriverTests: XCTestCase {
    private struct Secrets: SecretStore {
        var stored: Set<String> = []
        func hasSecret(for account: String) -> Bool { stored.contains(account) }
        func secret(for account: String) -> String? { nil }
        func setSecret(_ secret: String, for account: String) throws {}
        func removeSecret(for account: String) throws {}
    }

    private var directory: URL!
    private var pasteboard: [String] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-daily-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pasteboard = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel(secrets: Secrets = Secrets()) -> AppModel {
        let model = AppModel(
            settingsStore: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            sourceCatalogService: SourceCatalogService(snapshotOverride: {
                SourceCatalogSnapshot(applications: [], microphones: [])
            }),
            secretStore: secrets,
            cloudConnectionRegistry: CloudConnectionRegistry(),
            writeToPasteboard: { [weak self] text in self?.pasteboard.append(text) }
        )
        model.interfaceLanguageSelectionBinding.wrappedValue = "en"
        return model
    }

    // MARK: Launch at login

    private func openEvent(asLoginItem: Bool) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        if asLoginItem {
            event.setParam(
                NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)),
                forKeyword: AEKeyword(keyAEPropData)
            )
        }
        return event
    }

    func testALaunchAtLoginIsToldApartFromTheUserOpeningTheApp() {
        XCTAssertTrue(AppDelegate.wasLaunchedAsLoginItem(openEvent(asLoginItem: true)))
        XCTAssertFalse(AppDelegate.wasLaunchedAsLoginItem(openEvent(asLoginItem: false)))
        XCTAssertFalse(AppDelegate.wasLaunchedAsLoginItem(nil), "no launch event: treat it as opened by the user")
    }

    // MARK: Name

    func testTheAppCallsItselfUntertitelEverywhereTheUserReads() {
        let model = makeModel()

        XCTAssertEqual(model.appDisplayName, "Untertitel")
        XCTAssertEqual(model.appRepositoryURL?.absoluteString, "https://github.com/MehulMittal27/untertitel")
        for language in LanguageCatalog.interface {
            let title = AppLocalization.string(.advancedSettingsWindowTitle, languageID: language.id)
            XCTAssertTrue(title.contains("Untertitel"), "\(language.id): \(title)")
            XCTAssertFalse(title.contains("v2s"), "\(language.id): \(title)")
            XCTAssertFalse(AppLocalization.string(.openAtLogin, languageID: language.id).contains("v2s"), language.id)
        }
    }

    func testTheBundleKeepsItsIdentifierAndGainsADisplayName() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = try XCTUnwrap(
            NSDictionary(contentsOf: projectRoot.appendingPathComponent("Config/Info.plist")) as? [String: Any]
        )
        let project = try String(contentsOf: projectRoot.appendingPathComponent("v2s.xcodeproj/project.pbxproj"), encoding: .utf8)

        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "Untertitel")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "$(PRODUCT_BUNDLE_IDENTIFIER)")
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER = com.franklioxygen.v2s;"), "the bundle ID is unchanged")
        XCTAssertFalse(project.contains("PRODUCT_BUNDLE_IDENTIFIER = com.franklioxygen.v2s."), "and has no variant")
        for key in ["NSAudioCaptureUsageDescription", "NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"] {
            XCTAssertEqual((plist[key] as? String)?.hasPrefix("Untertitel "), true, key)
        }
    }

    // MARK: Disclosure

    func testTheDisclosureSaysWhereTheAudioGoesInTheLanguageOfTheCall() {
        let onDevice = makeModel()
        XCTAssertEqual(onDevice.inputLanguageID, "de")
        XCTAssertEqual(
            onDevice.disclosureText,
            "Ich nutze in diesem Gespräch Live-Untertitel (Englisch). Sie entstehen auf meinem Mac: Es wird nichts aufgezeichnet, und der Ton verlässt ihn nicht."
        )

        let cloud = makeModel(secrets: Secrets(stored: [SecretAccount.openAIAPIKey]))
        cloud.recognitionEngine = .openAITranslate
        XCTAssertEqual(
            cloud.disclosureText,
            "Ich nutze in diesem Gespräch Live-Untertitel (Englisch). Der Ton wird dafür an OpenAI gesendet. Ich speichere keine Aufnahme."
        )

        let soniox = makeModel(secrets: Secrets(stored: [SecretAccount.sonioxAPIKey]))
        soniox.recognitionEngine = .sonioxTranslate
        XCTAssertTrue(soniox.disclosureText.contains("an Soniox gesendet"))
    }

    func testACloudEngineWithoutAKeyRunsOnTheMacAndTheDisclosureSaysSo() {
        let model = makeModel()
        model.recognitionEngine = .openAITranslate

        XCTAssertTrue(model.disclosureText.contains("auf meinem Mac"), "without a key the session runs on-device")
    }

    func testCopyingTheDisclosurePutsItOnTheClipboard() {
        let model = makeModel()

        model.copyDisclosure()

        XCTAssertEqual(pasteboard, [model.disclosureText])
    }

    func testTheDisclosureExistsInEveryInterfaceLanguageAndNamesTheProvider() {
        for language in LanguageCatalog.interface {
            let onDevice = AppLocalization.string(.disclosureOnDeviceFormat, languageID: language.id, "LANG")
            let cloud = AppLocalization.string(.disclosureCloudFormat, languageID: language.id, "LANG", "PROVIDER")
            XCTAssertTrue(onDevice.contains("LANG"), language.id)
            XCTAssertTrue(cloud.contains("LANG") && cloud.contains("PROVIDER"), "\(language.id): \(cloud)")
            XCTAssertFalse(cloud.contains("\u{2014}") || onDevice.contains("\u{2014}"), language.id)
        }
    }
}
