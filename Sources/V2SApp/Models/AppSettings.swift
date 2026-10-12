import Foundation

struct AppSettings: Codable {
    var selectedSourceID: String?
    var selectedSourceIDs: [String]
    var sourceLanguageOverrides: [String: String]
    var sourceOutputLanguageOverrides: [String: String]
    var inputLanguageID: String
    var outputLanguageID: String
    var interfaceLanguageID: String?
    var overlayStyle: OverlayStyle
    var subtitleMode: SubtitleMode
    var subtitleDisplayMode: SubtitleDisplayMode
    var glossary: [String: String]
    var recognitionEngine: RecognitionEngine
    /// Global shortcut that switches subtitles on and off.
    var toggleHotkey: HotkeySetting
    var playsToggleSound: Bool
    var showsToggleLabel: Bool

    static let `default` = AppSettings(
        selectedSourceID: nil,
        selectedSourceIDs: [],
        sourceLanguageOverrides: [:],
        sourceOutputLanguageOverrides: [:],
        inputLanguageID: "de",
        outputLanguageID: "en",
        interfaceLanguageID: nil,
        overlayStyle: .default,
        subtitleMode: .balanced,
        subtitleDisplayMode: .both,
        glossary: [:],
        recognitionEngine: .onDevice,
        toggleHotkey: .defaultToggle,
        playsToggleSound: false,
        showsToggleLabel: true
    )

    // Custom decoder so existing settings files load cleanly as new fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedSourceID = try? c.decodeIfPresent(String.self, forKey: .selectedSourceID)
        selectedSourceIDs = (try? c.decodeIfPresent([String].self, forKey: .selectedSourceIDs))
            ?? selectedSourceID.map { [$0] }
            ?? AppSettings.default.selectedSourceIDs
        sourceLanguageOverrides = (try? c.decodeIfPresent([String: String].self, forKey: .sourceLanguageOverrides))
            ?? AppSettings.default.sourceLanguageOverrides
        sourceOutputLanguageOverrides = (try? c.decodeIfPresent([String: String].self, forKey: .sourceOutputLanguageOverrides))
            ?? AppSettings.default.sourceOutputLanguageOverrides
        inputLanguageID = (try? c.decodeIfPresent(String.self, forKey: .inputLanguageID))
            ?? AppSettings.default.inputLanguageID
        outputLanguageID = (try? c.decodeIfPresent(String.self, forKey: .outputLanguageID))
            ?? AppSettings.default.outputLanguageID
        interfaceLanguageID = try? c.decodeIfPresent(String.self, forKey: .interfaceLanguageID)
        overlayStyle = (try? c.decodeIfPresent(OverlayStyle.self, forKey: .overlayStyle))
            ?? AppSettings.default.overlayStyle
        subtitleMode = (try? c.decodeIfPresent(SubtitleMode.self, forKey: .subtitleMode))
            ?? AppSettings.default.subtitleMode
        subtitleDisplayMode = (try? c.decodeIfPresent(SubtitleDisplayMode.self, forKey: .subtitleDisplayMode))
            ?? AppSettings.default.subtitleDisplayMode
        glossary = (try? c.decodeIfPresent([String: String].self, forKey: .glossary))
            ?? AppSettings.default.glossary
        recognitionEngine = (try? c.decodeIfPresent(RecognitionEngine.self, forKey: .recognitionEngine))
            ?? AppSettings.default.recognitionEngine
        toggleHotkey = (try? c.decodeIfPresent(HotkeySetting.self, forKey: .toggleHotkey))
            ?? AppSettings.default.toggleHotkey
        playsToggleSound = (try? c.decodeIfPresent(Bool.self, forKey: .playsToggleSound))
            ?? AppSettings.default.playsToggleSound
        showsToggleLabel = (try? c.decodeIfPresent(Bool.self, forKey: .showsToggleLabel))
            ?? AppSettings.default.showsToggleLabel
    }

    init(
        selectedSourceID: String?,
        selectedSourceIDs: [String] = [],
        sourceLanguageOverrides: [String: String] = [:],
        sourceOutputLanguageOverrides: [String: String] = [:],
        inputLanguageID: String,
        outputLanguageID: String,
        interfaceLanguageID: String?,
        overlayStyle: OverlayStyle,
        subtitleMode: SubtitleMode,
        subtitleDisplayMode: SubtitleDisplayMode,
        glossary: [String: String],
        recognitionEngine: RecognitionEngine = .onDevice,
        toggleHotkey: HotkeySetting = .defaultToggle,
        playsToggleSound: Bool = false,
        showsToggleLabel: Bool = true
    ) {
        self.selectedSourceID = selectedSourceID
        self.selectedSourceIDs = selectedSourceIDs
        self.sourceLanguageOverrides = sourceLanguageOverrides
        self.sourceOutputLanguageOverrides = sourceOutputLanguageOverrides
        self.inputLanguageID  = inputLanguageID
        self.outputLanguageID = outputLanguageID
        self.interfaceLanguageID = interfaceLanguageID
        self.overlayStyle     = overlayStyle
        self.subtitleMode     = subtitleMode
        self.subtitleDisplayMode = subtitleDisplayMode
        self.glossary         = glossary
        self.recognitionEngine = recognitionEngine
        self.toggleHotkey = toggleHotkey
        self.playsToggleSound = playsToggleSound
        self.showsToggleLabel = showsToggleLabel
    }
}
