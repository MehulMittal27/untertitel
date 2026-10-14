import Foundation

/// Which engine turns captured audio into subtitles.
enum RecognitionEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Apple speech recognition plus Apple Translation. Works offline.
    case onDevice
    /// OpenAI `gpt-realtime-translate` over the network. Text only: the translated
    /// speech it returns is discarded and never played.
    case openAITranslate
    /// Soniox real-time transcription with translation, over the network. Text only,
    /// much cheaper, and it takes the glossary.
    case sonioxTranslate

    var id: String { rawValue }

    /// True for the engines that stream audio to a provider and are billed for it.
    var isCloud: Bool {
        self != .onDevice
    }

    /// The provider's name as it appears in messages. Nil on the device.
    var providerName: String? {
        switch self {
        case .onDevice: return nil
        case .openAITranslate: return "OpenAI"
        case .sonioxTranslate: return "Soniox"
        }
    }

    /// Where the provider's API key is kept in the Keychain.
    var secretAccount: String? {
        switch self {
        case .onDevice: return nil
        case .openAITranslate: return SecretAccount.openAIAPIKey
        case .sonioxTranslate: return SecretAccount.sonioxAPIKey
        }
    }

    /// The code a cloud engine takes for a subtitle language, or nil when it cannot
    /// make subtitles in that language. Always nil on the device, where Apple
    /// Translation decides.
    func cloudSubtitleLanguageCode(for languageID: String) -> String? {
        switch self {
        case .onDevice: return nil
        case .openAITranslate: return LanguageCatalog.openAILanguageCode(for: languageID)
        case .sonioxTranslate: return LanguageCatalog.sonioxLanguageCode(for: languageID)
        }
    }

    /// Soniox's list price for real-time transcription with translation, about $0.12
    /// per hour. It bills for as long as the connection is open.
    static let sonioxUSDPerMinute = 0.002
    /// Soniox's list price for a recorded file, about $0.10 per hour of audio.
    static let sonioxFileUSDPerHour = 0.10

    /// List price of the translation model (`gpt-realtime-translate`), billed by audio
    /// duration, silence included.
    static let openAITranslateUSDPerMinute = 0.034
    /// List price of the model that transcribes the source language
    /// (`gpt-realtime-whisper`). It is billed on top, for the same audio, whenever the
    /// original-language line is switched on.
    static let openAISourceTranscriptionUSDPerMinute = 0.017

    /// What an hour of streamed audio costs with the cloud engine.
    static func openAIUSDPerHour(transcribesSource: Bool) -> Double {
        let perMinute = openAITranslateUSDPerMinute
            + (transcribesSource ? openAISourceTranscriptionUSDPerMinute : 0)
        return perMinute * 60
    }
}
