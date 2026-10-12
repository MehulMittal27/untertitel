import Foundation

/// Which engine turns captured audio into subtitles.
enum RecognitionEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Apple speech recognition plus Apple Translation. Works offline.
    case onDevice
    /// OpenAI `gpt-realtime-translate` over the network. Text only: the translated
    /// speech it returns is discarded and never played.
    case openAITranslate

    var id: String { rawValue }

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
