import Foundation
import NaturalLanguage

struct LanguageOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let localeIdentifier: String?

    init(id: String, displayName: String, localeIdentifier: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.localeIdentifier = localeIdentifier
    }

    func localizedDisplayName(in interfaceLanguageID: String) -> String {
        LanguageCatalog.displayName(for: id, in: interfaceLanguageID)
    }
}

enum LanguageCatalog {
    // These are the languages for which v2s has an embedded interface
    // localization. Keep this list separate from the translation catalog so
    // adding a subtitle language does not expose an untranslated app UI.
    static let interface: [LanguageOption] = [
        LanguageOption(id: "en", displayName: "English"),
        LanguageOption(id: "zh-Hans", displayName: "Chinese (Simplified)"),
        LanguageOption(id: "es", displayName: "Spanish"),
        LanguageOption(id: "de", displayName: "German"),
        LanguageOption(id: "ja", displayName: "Japanese"),
        LanguageOption(id: "fr", displayName: "French"),
        LanguageOption(id: "ko", displayName: "Korean"),
        LanguageOption(id: "ar", displayName: "Arabic"),
        LanguageOption(id: "pt", displayName: "Portuguese"),
        LanguageOption(id: "ru", displayName: "Russian"),
    ]

    // Initial choices shown while runtime Translation availability loads.
    // AppModel replaces these with LanguageAvailability.supportedLanguages.
    static let common: [LanguageOption] = [
        LanguageOption(id: "en", displayName: "English"),
        LanguageOption(id: "zh-Hans", displayName: "Chinese (Simplified)"),
        LanguageOption(id: "zh-Hant", displayName: "Chinese (Traditional)"),
        LanguageOption(id: "es", displayName: "Spanish"),
        LanguageOption(id: "de", displayName: "German"),
        LanguageOption(id: "ja", displayName: "Japanese"),
        LanguageOption(id: "fr", displayName: "French"),
        LanguageOption(id: "ko", displayName: "Korean"),
        LanguageOption(id: "ar", displayName: "Arabic"),
        LanguageOption(id: "pt", displayName: "Portuguese"),
        LanguageOption(id: "ru", displayName: "Russian"),
        LanguageOption(id: "it", displayName: "Italian"),
        LanguageOption(id: "nl", displayName: "Dutch"),
        LanguageOption(id: "id", displayName: "Indonesian"),
        LanguageOption(id: "th", displayName: "Thai"),
        LanguageOption(id: "tr", displayName: "Turkish"),
        LanguageOption(id: "pl", displayName: "Polish"),
        LanguageOption(id: "uk", displayName: "Ukrainian"),
        LanguageOption(id: "vi", displayName: "Vietnamese"),
        LanguageOption(id: "hi", displayName: "Hindi"),
        LanguageOption(id: "da", displayName: "Danish"),
        LanguageOption(id: "nb", displayName: "Norwegian Bokmål"),
        LanguageOption(id: "sv", displayName: "Swedish"),
    ]

    // This is the candidate catalog. On macOS 26 and later AppModel narrows
    // it to the SpeechTranscriber locales actually available on the device.
    // Keeping the broader catalog here also lets older systems use their
    // legacy speech-recognition fallback where available.
    static let speechInput: [LanguageOption] = [
        LanguageOption(id: "en", displayName: "English"),
        LanguageOption(id: "zh-Hans", displayName: "Chinese (Simplified)"),
        LanguageOption(id: "zh-Hant", displayName: "Chinese (Traditional)"),
        LanguageOption(id: "yue", displayName: "Cantonese"),
        LanguageOption(id: "es", displayName: "Spanish"),
        LanguageOption(id: "de", displayName: "German"),
        LanguageOption(id: "ja", displayName: "Japanese"),
        LanguageOption(id: "fr", displayName: "French"),
        LanguageOption(id: "it", displayName: "Italian"),
        LanguageOption(id: "ko", displayName: "Korean"),
        LanguageOption(id: "pt", displayName: "Portuguese"),
        LanguageOption(id: "ar", displayName: "Arabic"),
        LanguageOption(id: "ca", displayName: "Catalan"),
        LanguageOption(id: "cs", displayName: "Czech"),
        LanguageOption(id: "da", displayName: "Danish"),
        LanguageOption(id: "fi", displayName: "Finnish"),
        LanguageOption(id: "el", displayName: "Greek"),
        LanguageOption(id: "he", displayName: "Hebrew"),
        LanguageOption(id: "hi", displayName: "Hindi"),
        LanguageOption(id: "hr", displayName: "Croatian"),
        LanguageOption(id: "hu", displayName: "Hungarian"),
        LanguageOption(id: "id", displayName: "Indonesian"),
        LanguageOption(id: "ms", displayName: "Malay"),
        LanguageOption(id: "nb", displayName: "Norwegian Bokmål"),
        LanguageOption(id: "nl", displayName: "Dutch"),
        LanguageOption(id: "pl", displayName: "Polish"),
        LanguageOption(id: "ro", displayName: "Romanian"),
        LanguageOption(id: "ru", displayName: "Russian"),
        LanguageOption(id: "sk", displayName: "Slovak"),
        LanguageOption(id: "sv", displayName: "Swedish"),
        LanguageOption(id: "th", displayName: "Thai"),
        LanguageOption(id: "tr", displayName: "Turkish"),
        LanguageOption(id: "uk", displayName: "Ukrainian"),
        LanguageOption(id: "vi", displayName: "Vietnamese"),
    ]

    static func displayName(for identifier: String) -> String {
        (speechInput + common).first(where: { $0.id == identifier })?.displayName ?? identifier
    }

    static func displayName(for identifier: String, in interfaceLanguageID: String) -> String {
        if isAutoDetect(identifier) {
            return AppLocalization.string(.autoDetect, languageID: interfaceLanguageID)
        }

        let locale = Locale(identifier: interfaceLanguageID)
        return locale.localizedString(forIdentifier: identifier)
            ?? displayName(for: identifier)
    }

    static func preferredInterfaceLanguageID(storedIdentifier: String?) -> String {
        AppLocalization.resolvedInterfaceLanguageID(storedIdentifier: storedIdentifier)
    }

    static func supportedSpeechInputLanguageID(for identifier: String) -> String {
        isAutoDetect(identifier) || speechInput.contains(where: { $0.id == identifier }) ? identifier : "en"
    }

    // MARK: Auto-detect and the cloud engines' languages

    /// The spoken language "Auto-detect": the cloud engines find the language
    /// themselves. On-device recognition needs a real language.
    static let autoDetectID = "auto"

    static func isAutoDetect(_ identifier: String) -> Bool {
        identifier == autoDetectID
    }

    static let autoDetect = LanguageOption(id: autoDetectID, displayName: "Auto-detect")

    /// The 13 subtitle languages OpenAI's gpt-realtime-translate can produce, from
    /// OpenAI's realtime translation guide (checked 14 Oct 2026). It takes 70+ spoken
    /// languages and detects them itself.
    static let openAISubtitleLanguageIDs = [
        "en", "es", "pt", "fr", "ja", "ru", "zh-Hans", "de", "ko", "hi", "id", "vi", "it",
    ]

    /// Soniox's languages, in this catalog's identifiers. Soniox recognizes each and
    /// translates between any two (soniox.com/docs/stt/concepts/supported-languages,
    /// checked 14 Oct 2026).
    static let sonioxLanguageIDs = [
        "af", "sq", "ar", "az", "eu", "be", "bn", "bs", "bg", "ca", "zh-Hans", "hr", "cs", "da", "nl", "en",
        "et", "fi", "fr", "gl", "de", "el", "gu", "he", "hi", "hu", "id", "it", "ja", "kn", "kk", "ko",
        "lv", "lt", "mk", "ms", "ml", "mr", "nb", "fa", "pl", "pt", "pa", "ro", "ru", "sr", "sk", "sl",
        "es", "sw", "sv", "tl", "ta", "te", "th", "tr", "uk", "ur", "vi", "cy",
    ]

    /// The code OpenAI takes for a subtitle language, or nil when it has none.
    static func openAILanguageCode(for identifier: String) -> String? {
        guard openAISubtitleLanguageIDs.contains(identifier) else { return nil }
        return baseLanguageCode(for: identifier)
    }

    /// The code Soniox takes for a language, or nil when it does not support it.
    static func sonioxLanguageCode(for identifier: String) -> String? {
        switch identifier {
        case "nb": return "no"
        default:
            guard sonioxLanguageIDs.contains(identifier) else { return nil }
            return baseLanguageCode(for: identifier)
        }
    }

    static func options(for identifiers: [String]) -> [LanguageOption] {
        let english = Locale(identifier: "en")
        return identifiers
            .map { id in
                common.first(where: { $0.id == id })
                    ?? speechInput.first(where: { $0.id == id })
                    ?? LanguageOption(id: id, displayName: english.localizedString(forIdentifier: id) ?? id)
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// The catalog language most of `text` is written in, found on this Mac, or nil
    /// when the text is too short or too mixed to tell.
    static func dominantLanguageID(in text: String) -> String? {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumDetectionCharacters else {
            return nil
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= minimumDetectionConfidence else {
            return nil
        }
        // NaturalLanguage names languages the way this catalog does: "de", "zh-Hans", "nb".
        return language.rawValue
    }

    static let minimumDetectionCharacters = 20
    static let minimumDetectionConfidence = 0.6

    private static func baseLanguageCode(for identifier: String) -> String {
        String(identifier.split(separator: "-").first ?? Substring(identifier)).lowercased()
    }

    /// Builds the catalog options for `locales`, keeping one locale per language.
    ///
    /// Identifiers in `preferredIdentifiers` win their language outright. Callers use
    /// that to keep a capable locale — one that can be recognized on device — from
    /// losing to a variant that merely sorts earlier.
    static func options(
        for locales: [Locale],
        preferring preferredIdentifiers: Set<String> = []
    ) -> [LanguageOption] {
        options(
            for: locales.map { locale in
                (
                    language: locale.language,
                    localeIdentifier: locale.identifier,
                    isPreferred: preferredIdentifiers.contains(locale.identifier)
                )
            }
        )
    }

    static func options(for languages: [Locale.Language]) -> [LanguageOption] {
        options(
            for: languages.map { language in
                (
                    language: language,
                    localeIdentifier: language.minimalIdentifier,
                    isPreferred: false
                )
            }
        )
    }

    private static func options(
        for candidates: [(language: Locale.Language, localeIdentifier: String, isPreferred: Bool)]
    ) -> [LanguageOption] {
        var optionsByID: [String: LanguageOption] = [:]

        let preferredLanguages = Locale.preferredLanguages.map { Locale(identifier: $0).language }
        let sortedCandidates = candidates.sorted { lhs, rhs in
            // Each language keeps the first identifier it sees, so preferred
            // identifiers have to sort ahead of everything else.
            if lhs.isPreferred != rhs.isPreferred {
                return lhs.isPreferred
            }

            let lhsRank = preferenceRank(for: lhs.language, in: preferredLanguages)
            let rhsRank = preferenceRank(for: rhs.language, in: preferredLanguages)
            if lhsRank == rhsRank {
                return lhs.localeIdentifier < rhs.localeIdentifier
            }
            return lhsRank < rhsRank
        }

        for candidate in sortedCandidates {
            guard let id = catalogIdentifier(for: candidate.language) else {
                continue
            }

            let englishLocale = Locale(identifier: "en")
            let displayName = englishLocale.localizedString(forIdentifier: id) ?? id
            optionsByID[id] = optionsByID[id] ?? LanguageOption(
                id: id,
                displayName: displayName,
                localeIdentifier: candidate.localeIdentifier
            )
        }

        return optionsByID.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private static func catalogIdentifier(for language: Locale.Language) -> String? {
        guard let languageCode = language.languageCode?.identifier else {
            return nil
        }

        // Preserve explicitly identified scripts, plus Chinese where Foundation
        // commonly minimizes the script into a region such as zh-TW.
        let minimalIdentifierParts = language.minimalIdentifier.split(separator: "-")
        if let script = Locale.Language(identifier: language.maximalIdentifier).script?.identifier,
           languageCode == "zh" || minimalIdentifierParts.contains(Substring(script)) {
            return "\(languageCode)-\(script)"
        }

        return languageCode
    }

    private static func preferenceRank(
        for language: Locale.Language,
        in preferredLanguages: [Locale.Language]
    ) -> Int {
        guard let id = catalogIdentifier(for: language) else {
            return preferredLanguages.count
        }

        return preferredLanguages.firstIndex(where: { preferredLanguage in
            catalogIdentifier(for: preferredLanguage) == id
                && preferredLanguage.region == language.region
        }) ?? preferredLanguages.count
    }

    static func translationLocaleIdentifier(for identifier: String) -> String {
        switch identifier {
        case "en": return "en-US"
        case "zh-Hans": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        case "pt": return "pt-BR"
        case "nb": return "nb-NO"
        default: return identifier
        }
    }

    static func speechLocaleIdentifier(for identifier: String) -> String {
        switch identifier {
        case "en": return "en-US"
        case "zh-Hans": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        case "yue": return "yue-CN"
        case "es": return "es-ES"
        case "de": return "de-DE"
        case "ja": return "ja-JP"
        case "fr": return "fr-FR"
        case "it": return "it-IT"
        case "ko": return "ko-KR"
        case "ar": return "ar-SA"
        case "pt": return "pt-BR"
        case "ca": return "ca-ES"
        case "cs": return "cs-CZ"
        case "da": return "da-DK"
        case "fi": return "fi-FI"
        case "el": return "el-GR"
        case "he": return "he-IL"
        case "hi": return "hi-IN"
        case "hr": return "hr-HR"
        case "hu": return "hu-HU"
        case "id": return "id-ID"
        case "ms": return "ms-MY"
        case "nb": return "nb-NO"
        case "nl": return "nl-NL"
        case "pl": return "pl-PL"
        case "ro": return "ro-RO"
        case "ru": return "ru-RU"
        case "sk": return "sk-SK"
        case "sv": return "sv-SE"
        case "th": return "th-TH"
        case "tr": return "tr-TR"
        case "uk": return "uk-UA"
        case "vi": return "vi-VN"
        default: return identifier
        }
    }
}
