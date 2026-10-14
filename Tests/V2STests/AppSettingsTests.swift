import Foundation
import XCTest
@testable import v2s

final class AppSettingsTests: XCTestCase {
    func testLegacySingleSourceSettingsDecodeIntoMultiSourceFields() throws {
        let json = """
        {
          "selectedSourceID": "mic-1",
          "inputLanguageID": "en",
          "outputLanguageID": "ja",
          "overlayStyle": {
            "translatedFontSize": 20,
            "sourceFontSize": 16,
            "backgroundOpacity": 0.7,
            "subtitleColor": { "kind": "defaultSubtitle" },
            "textColor": { "kind": "defaultText" },
            "backgroundColor": { "kind": "defaultBackground" },
            "showsTextOutline": true,
            "textOutlineColor": { "kind": "defaultTextOutline" },
            "attachToSource": true,
            "translatedFirst": true
          },
          "subtitleMode": "balanced",
          "subtitleDisplayMode": "both",
          "glossary": {}
        }
        """

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.selectedSourceID, "mic-1")
        XCTAssertEqual(settings.selectedSourceIDs, ["mic-1"])
        XCTAssertTrue(settings.sourceLanguageOverrides.isEmpty)
        XCTAssertTrue(settings.sourceOutputLanguageOverrides.isEmpty)
    }

    func testMultiSourceSettingsRoundTripPreservesOverrides() throws {
        let settings = AppSettings(
            selectedSourceID: "mic-1",
            selectedSourceIDs: ["mic-1", "app-1"],
            sourceLanguageOverrides: ["app-1": "fr"],
            sourceOutputLanguageOverrides: ["mic-1": "zh-Hans", "app-1": "de"],
            inputLanguageID: "en",
            outputLanguageID: "ja",
            interfaceLanguageID: "en",
            overlayStyle: .default,
            subtitleMode: .balanced,
            subtitleDisplayMode: .both,
            glossary: ["CEO": "Chief Executive Officer"]
        )

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.selectedSourceID, "mic-1")
        XCTAssertEqual(decoded.selectedSourceIDs, ["mic-1", "app-1"])
        XCTAssertEqual(decoded.sourceLanguageOverrides, ["app-1": "fr"])
        XCTAssertEqual(
            decoded.sourceOutputLanguageOverrides,
            ["mic-1": "zh-Hans", "app-1": "de"]
        )
        XCTAssertEqual(decoded.inputLanguageID, "en")
        XCTAssertEqual(decoded.outputLanguageID, "ja")
        XCTAssertEqual(decoded.interfaceLanguageID, "en")
        XCTAssertEqual(decoded.glossary, ["CEO": "Chief Executive Officer"])
    }

    func testDefaultLanguagesAreAutoDetectToEnglish() {
        XCTAssertEqual(AppSettings.default.inputLanguageID, LanguageCatalog.autoDetectID)
        XCTAssertEqual(AppSettings.default.outputLanguageID, "en")
    }

    @MainActor
    func testMissingSettingsFileStartsAsAutoDetectToEnglish() {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-app-settings-\(UUID().uuidString).json")

        let settings = SettingsStore(fileURL: settingsURL).load()

        XCTAssertEqual(settings.inputLanguageID, "auto")
        XCTAssertEqual(settings.outputLanguageID, "en")
    }

    @MainActor
    func testExistingSettingsFileKeepsItsLanguagePair() throws {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-app-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        let json = """
        {
          "inputLanguageID": "en",
          "outputLanguageID": "zh-Hans"
        }
        """
        try Data(json.utf8).write(to: settingsURL)

        let settings = SettingsStore(fileURL: settingsURL).load()

        XCTAssertEqual(settings.inputLanguageID, "en")
        XCTAssertEqual(settings.outputLanguageID, "zh-Hans")
    }

    func testRecognitionEngineDefaultsToOnDeviceForSettingsSavedBeforeItExisted() throws {
        let json = """
        {
          "inputLanguageID": "de",
          "outputLanguageID": "en"
        }
        """

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.recognitionEngine, .onDevice)
        XCTAssertEqual(AppSettings.default.recognitionEngine, .onDevice)
    }

    func testRecognitionEngineSurvivesAnEncodeDecodeRoundTrip() throws {
        var settings = AppSettings.default
        settings.recognitionEngine = .openAITranslate

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.recognitionEngine, .openAITranslate)
    }

    func testUnknownRecognitionEngineFallsBackToOnDevice() throws {
        let json = """
        {
          "recognitionEngine": "someEngineFromTheFuture"
        }
        """

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.recognitionEngine, .onDevice)
    }

    func testInvisibleInRecordingDefaultsToOffForSettingsSavedBeforeTheToggleExisted() throws {
        let json = """
        {
          "selectedSourceID": "mic-1",
          "inputLanguageID": "en",
          "outputLanguageID": "ja",
          "overlayStyle": {
            "translatedFontSize": 20,
            "sourceFontSize": 16,
            "backgroundOpacity": 0.7,
            "topInset": 12,
            "widthRatio": 0.82,
            "minWidth": 720,
            "maxWidth": 1440,
            "clickThrough": true,
            "translatedFirst": true
          },
          "subtitleMode": "balanced",
          "subtitleDisplayMode": "both",
          "glossary": {}
        }
        """

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertFalse(settings.overlayStyle.invisibleInRecording)
    }

    func testInvisibleInRecordingSurvivesAnEncodeDecodeRoundTrip() throws {
        var style = OverlayStyle.default
        style.invisibleInRecording = true

        let data = try JSONEncoder().encode(style)
        let decoded = try JSONDecoder().decode(OverlayStyle.self, from: data)

        XCTAssertTrue(decoded.invisibleInRecording)
    }
}
