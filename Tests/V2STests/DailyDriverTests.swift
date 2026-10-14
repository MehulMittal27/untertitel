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
        XCTAssertEqual(project.components(separatedBy: "PRODUCT_NAME = Untertitel;").count - 1, 2, "app file and process")
        XCTAssertTrue(project.contains("path = Untertitel.app;"))
        XCTAssertFalse(project.contains("v2s.app"))
        XCTAssertEqual(plist["CFBundleName"] as? String, "$(PRODUCT_NAME)")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "$(EXECUTABLE_NAME)")
        XCTAssertFalse(project.contains("PRODUCT_BUNDLE_IDENTIFIER = com.franklioxygen.v2s."), "and has no variant")
        for key in ["NSAudioCaptureUsageDescription", "NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"] {
            XCTAssertEqual((plist[key] as? String)?.hasPrefix("Untertitel "), true, key)
        }
    }

    // MARK: Data folder

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    func testTheOldDataFolderMovesToUntertitelWithEveryFile() throws {
        let legacy = directory.appendingPathComponent("v2s", isDirectory: true)
        for name in ["settings.json", "cloud-usage.json", "cloud-connections.log"] {
            try write("old \(name)", to: legacy.appendingPathComponent(name))
        }

        let resolved = AppDataDirectory.resolve(inApplicationSupport: directory)

        XCTAssertEqual(resolved.lastPathComponent, "Untertitel")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        for name in ["settings.json", "cloud-usage.json", "cloud-connections.log"] {
            XCTAssertEqual(read(resolved.appendingPathComponent(name)), "old \(name)")
        }
        XCTAssertEqual(AppDataDirectory.resolve(inApplicationSupport: directory), resolved, "a second launch changes nothing")
    }

    func testSettingsApprovedAppsAndUsageSurviveTheMove() throws {
        let legacy = directory.appendingPathComponent("v2s", isDirectory: true)
        let oldStore = SettingsStore(fileURL: legacy.appendingPathComponent("settings.json"))
        var settings = AppSettings.default
        settings.approvedSourceIDs = ["com.apple.Safari"]
        settings.subtitleDisplayMode = .translatedOnly
        oldStore.save(settings)
        let oldUsage = CloudUsageStore(fileURL: legacy.appendingPathComponent("cloud-usage.json"))
        var ledger = CloudUsageLedger()
        ledger.add(seconds: 409.2, transcribedSeconds: 0, on: Date())
        oldUsage.save(ledger)

        let resolved = AppDataDirectory.resolve(inApplicationSupport: directory)
        let moved = SettingsStore(fileURL: resolved.appendingPathComponent("settings.json")).load()
        let movedUsage = CloudUsageStore(fileURL: resolved.appendingPathComponent("cloud-usage.json")).load()

        XCTAssertEqual(moved.approvedSourceIDs, ["com.apple.Safari"])
        XCTAssertEqual(moved.subtitleDisplayMode, .translatedOnly)
        XCTAssertEqual(movedUsage.seconds(on: Date()), 409.2, accuracy: 0.001)
    }

    func testWhenBothFoldersExistNothingIsOverwritten() throws {
        let legacy = directory.appendingPathComponent("v2s", isDirectory: true)
        let current = directory.appendingPathComponent("Untertitel", isDirectory: true)
        try write("old settings", to: legacy.appendingPathComponent("settings.json"))
        try write("old log", to: legacy.appendingPathComponent("cloud-connections.log"))
        try write("new settings", to: current.appendingPathComponent("settings.json"))

        let resolved = AppDataDirectory.resolve(inApplicationSupport: directory)

        XCTAssertEqual(resolved, current)
        XCTAssertEqual(read(current.appendingPathComponent("settings.json")), "new settings")
        XCTAssertEqual(read(current.appendingPathComponent("cloud-connections.log")), "old log")
        XCTAssertEqual(read(legacy.appendingPathComponent("settings.json")), "old settings", "kept, not deleted")
    }

    func testAFreshInstallUsesUntertitelAndCreatesNothingElse() {
        let resolved = AppDataDirectory.resolve(inApplicationSupport: directory)

        XCTAssertEqual(resolved, directory.appendingPathComponent("Untertitel", isDirectory: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("v2s").path))
    }

    func testTheLoginItemRegistersAgainOnlyWhenWantedAndMoved() {
        let app = "/Users/me/untertitel-build/Build/Products/Debug/Untertitel.app"
        let old = "/Users/me/untertitel-build/Build/Products/Debug/v2s.app"

        XCTAssertTrue(LaunchAtLoginService.needsRegistrationAgain(wanted: true, registeredPath: old, appPath: app))
        XCTAssertTrue(LaunchAtLoginService.needsRegistrationAgain(wanted: true, registeredPath: nil, appPath: app))
        XCTAssertFalse(LaunchAtLoginService.needsRegistrationAgain(wanted: true, registeredPath: app, appPath: app))
        XCTAssertFalse(LaunchAtLoginService.needsRegistrationAgain(wanted: false, registeredPath: old, appPath: app))
    }

    // MARK: Updates

    func testTheBuildHasNoUpdateFeedAndChecksAreOffByDefault() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plistURL = projectRoot.appendingPathComponent("Config/Info.plist")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: plistURL) as? [String: Any])

        XCTAssertNil(plist["SUFeedURL"], "an update feed would offer builds this fork did not make")
        XCTAssertNil(plist["SUPublicEDKey"], "and no key says whose updates to trust")
        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, false)
        XCTAssertFalse(UpdateFeed.isConfigured(in: plist))
        XCTAssertFalse(try String(contentsOf: plistURL, encoding: .utf8).contains("franklioxygen"))
    }

    func testAnUpdateFeedIsOnlyOneThatNamesAnAddress() {
        XCTAssertFalse(UpdateFeed.isConfigured(in: nil))
        XCTAssertFalse(UpdateFeed.isConfigured(in: [:]))
        XCTAssertFalse(UpdateFeed.isConfigured(in: ["SUFeedURL": "  \n"]))
        XCTAssertFalse(UpdateFeed.isConfigured(in: ["SUFeedURL": 1]))
        XCTAssertTrue(UpdateFeed.isConfigured(in: ["SUFeedURL": "https://example.com/appcast.xml"]))
    }

    func testWithoutAFeedTheUpdaterNeverStarts() {
        let updater = UpdaterService(isAvailable: false)

        XCTAssertFalse(updater.isAvailable)
        XCTAssertFalse(updater.isStarted)
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
        updater.checkForUpdates()
        XCTAssertFalse(updater.isStarted)
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
