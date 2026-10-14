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
    /// The sources the last session listened to: what a new session falls back to when
    /// nothing is selected. Nil only in a settings file written before this existed,
    /// whose stored selection may be one the app picked by itself.
    var lastSessionSourceIDs: [String]?
    /// Whether speech reopens the cloud connection after an idle pause. Off unless the
    /// user opts in: a paused session otherwise stays paused, and unbilled.
    var cloudResumesAutomatically: Bool
    /// Apps the user has chosen or run a session on. Automatic selection picks only
    /// among these. Nil in a settings file from before the list existed.
    var approvedSourceIDs: [String]?
    /// Whether the source is picked among the approved apps at each start.
    var selectsSourceAutomatically: Bool
    /// Global shortcut that shows the recent captions in the overlay.
    var catchUpHotkey: HotkeySetting
    /// Global shortcut that copies the last two minutes to the clipboard.
    var copyRecentHotkey: HotkeySetting

    static let `default` = AppSettings(
        selectedSourceID: nil,
        selectedSourceIDs: [],
        sourceLanguageOverrides: [:],
        sourceOutputLanguageOverrides: [:],
        inputLanguageID: LanguageCatalog.autoDetectID,
        outputLanguageID: "en",
        interfaceLanguageID: nil,
        overlayStyle: .default,
        subtitleMode: .balanced,
        subtitleDisplayMode: .both,
        glossary: [:],
        recognitionEngine: .onDevice,
        toggleHotkey: .defaultToggle,
        playsToggleSound: false,
        showsToggleLabel: true,
        lastSessionSourceIDs: [],
        cloudResumesAutomatically: false,
        approvedSourceIDs: [],
        selectsSourceAutomatically: true,
        catchUpHotkey: .defaultCatchUp,
        copyRecentHotkey: .defaultCopyRecent
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
        lastSessionSourceIDs = try? c.decodeIfPresent([String].self, forKey: .lastSessionSourceIDs)
        cloudResumesAutomatically = (try? c.decodeIfPresent(Bool.self, forKey: .cloudResumesAutomatically))
            ?? AppSettings.default.cloudResumesAutomatically
        approvedSourceIDs = try? c.decodeIfPresent([String].self, forKey: .approvedSourceIDs)
        selectsSourceAutomatically = (try? c.decodeIfPresent(Bool.self, forKey: .selectsSourceAutomatically))
            ?? AppSettings.default.selectsSourceAutomatically
        catchUpHotkey = (try? c.decodeIfPresent(HotkeySetting.self, forKey: .catchUpHotkey))
            ?? AppSettings.default.catchUpHotkey
        copyRecentHotkey = (try? c.decodeIfPresent(HotkeySetting.self, forKey: .copyRecentHotkey))
            ?? AppSettings.default.copyRecentHotkey
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
        showsToggleLabel: Bool = true,
        lastSessionSourceIDs: [String]? = [],
        cloudResumesAutomatically: Bool = false,
        approvedSourceIDs: [String]? = [],
        selectsSourceAutomatically: Bool = true,
        catchUpHotkey: HotkeySetting = .defaultCatchUp,
        copyRecentHotkey: HotkeySetting = .defaultCopyRecent
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
        self.lastSessionSourceIDs = lastSessionSourceIDs
        self.cloudResumesAutomatically = cloudResumesAutomatically
        self.approvedSourceIDs = approvedSourceIDs
        self.selectsSourceAutomatically = selectsSourceAutomatically
        self.catchUpHotkey = catchUpHotkey
        self.copyRecentHotkey = copyRecentHotkey
    }
}
