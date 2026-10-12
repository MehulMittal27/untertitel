import AVFoundation
import Foundation

/// Sample conversion for the cloud engine: 24 kHz mono 16-bit little-endian PCM.
enum PCM16Encoding {
    /// Converts normalized Float32 samples to Int16, clipping anything out of range.
    static func int16Samples(from samples: UnsafeBufferPointer<Float>) -> [Int16] {
        samples.map { sample in
            let clipped = max(-1, min(1, sample.isFinite ? sample : 0))
            return Int16((clipped * Float(Int16.max)).rounded())
        }
    }

    static func int16Samples(from samples: [Float]) -> [Int16] {
        samples.withUnsafeBufferPointer { int16Samples(from: $0) }
    }

    static func littleEndianData(from samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func peakLevel(of samples: [Int16]) -> Float {
        var peak: Int32 = 0
        for sample in samples {
            peak = max(peak, abs(Int32(sample)))
        }
        return Float(peak) / Float(Int16.max)
    }
}

/// Collects samples into the fixed-size chunks the engine consumes.
struct PCM16Chunker {
    let samplesPerChunk: Int
    private var pending: [Int16] = []

    init(samplesPerChunk: Int = OpenAITranslateProtocol.samplesPerChunk) {
        self.samplesPerChunk = max(1, samplesPerChunk)
        pending.reserveCapacity(self.samplesPerChunk * 2)
    }

    var pendingSampleCount: Int { pending.count }

    /// Returns every complete chunk; a remainder waits for the next call.
    mutating func append(_ samples: [Int16]) -> [[Int16]] {
        pending.append(contentsOf: samples)

        var chunks: [[Int16]] = []
        while pending.count >= samplesPerChunk {
            chunks.append(Array(pending.prefix(samplesPerChunk)))
            pending.removeFirst(samplesPerChunk)
        }
        return chunks
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
    }

    static func silentChunk(samplesPerChunk: Int = OpenAITranslateProtocol.samplesPerChunk) -> [Int16] {
        [Int16](repeating: 0, count: samplesPerChunk)
    }
}

/// Resamples captured audio to the engine's input format. The converter is kept
/// between buffers so the resampler stays continuous. Not thread-safe: use it from the
/// capture queue only.
final class CloudAudioConverter {
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(OpenAITranslateProtocol.sampleRate),
        channels: 1,
        interleaved: false
    )!
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        guard buffer.frameLength > 0 else {
            return []
        }

        if inputFormat != buffer.format || converter == nil {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            inputFormat = buffer.format
        }

        guard let converter else {
            return []
        }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        // Headroom for samples the resampler held back from the previous buffer.
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return []
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard conversionError == nil,
              status != .error,
              output.frameLength > 0,
              let channel = output.floatChannelData?[0] else {
            return []
        }

        return PCM16Encoding.int16Samples(
            from: UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
        )
    }

    func reset() {
        converter = nil
        inputFormat = nil
    }
}
