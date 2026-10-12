import Foundation

/// Which engine turns captured audio into subtitles.
enum RecognitionEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Apple speech recognition plus Apple Translation. Works offline.
    case onDevice
    /// OpenAI `gpt-realtime-translate` over the network. Text only: the translated
    /// speech it returns is discarded and never played.
    case openAITranslate

    var id: String { rawValue }

    /// List price of the cloud engine, billed by audio duration (silence included).
    static let openAITranslateUSDPerMinute = 0.034
}
