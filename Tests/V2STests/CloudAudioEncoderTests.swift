import AVFoundation
import XCTest
@testable import v2s

final class CloudAudioEncoderTests: XCTestCase {
    func testFloatSamplesScaleToTheInt16Range() {
        XCTAssertEqual(PCM16Encoding.int16Samples(from: [0, 1, -1, 0.5]), [0, 32767, -32767, 16384])
    }

    func testOutOfRangeAndNonFiniteSamplesAreClipped() {
        XCTAssertEqual(
            PCM16Encoding.int16Samples(from: [2.5, -3, .infinity, .nan]),
            [32767, -32767, 0, 0]
        )
    }

    func testSamplesAreEncodedLittleEndian() {
        XCTAssertEqual(
            Array(PCM16Encoding.littleEndianData(from: [1, -2, 0x1234])),
            [0x01, 0x00, 0xFE, 0xFF, 0x34, 0x12]
        )
    }

    func testPeakLevelIsRelativeToFullScale() {
        XCTAssertEqual(PCM16Encoding.peakLevel(of: [0, 0]), 0)
        XCTAssertEqual(PCM16Encoding.peakLevel(of: [100, -32767]), 1, accuracy: 0.0001)
    }

    func testChunkerEmitsFullChunksAndKeepsTheRemainder() {
        var chunker = PCM16Chunker(samplesPerChunk: 4)

        XCTAssertTrue(chunker.append([1, 2, 3]).isEmpty)
        XCTAssertEqual(chunker.append([4, 5, 6, 7, 8, 9]), [[1, 2, 3, 4], [5, 6, 7, 8]])
        XCTAssertEqual(chunker.pendingSampleCount, 1)
        XCTAssertEqual(chunker.append([10, 11, 12]), [[9, 10, 11, 12]])
    }

    func testDefaultChunkIs200MillisecondsOf24KilohertzAudio() {
        XCTAssertEqual(OpenAITranslateProtocol.samplesPerChunk, 4_800)
        XCTAssertEqual(PCM16Chunker.silentChunk(), [Int16](repeating: 0, count: 4_800))
        XCTAssertEqual(PCM16Encoding.littleEndianData(from: PCM16Chunker.silentChunk()).count, 9_600)
    }

    func testConverterResamples16KilohertzAudioTo24Kilohertz() throws {
        let inputFormat = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        )
        let converter = CloudAudioConverter()
        var produced = 0
        var peak: Float = 0

        // One second of a 440 Hz tone at half scale, in 100 ms buffers.
        for bufferIndex in 0..<10 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 1_600))
            buffer.frameLength = 1_600
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0..<1_600 {
                let time = Double(bufferIndex * 1_600 + frame) / 16_000
                samples[frame] = Float(0.5 * sin(2 * .pi * 440 * time))
            }

            let converted = converter.convert(buffer)
            produced += converted.count
            peak = max(peak, PCM16Encoding.peakLevel(of: converted))
        }

        // The resampler may hold a few samples back, never invent a different duration.
        XCTAssertEqual(Double(produced), 24_000, accuracy: 240)
        XCTAssertEqual(peak, 0.5, accuracy: 0.05)
    }

    func testConverterMixesStereoCaptureDownToOneChannel() throws {
        let inputFormat = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4_800))
        buffer.frameLength = 4_800

        let converter = CloudAudioConverter()
        let converted = converter.convert(buffer) + converter.convert(buffer)

        // Two channels in, one out, at half the rate. The resampler holds its first
        // few hundred samples back, so the total stays a little under 4,800.
        XCTAssertGreaterThan(converted.count, 4_000)
        XCTAssertLessThanOrEqual(converted.count, 4_800 + 64)
        XCTAssertEqual(PCM16Encoding.peakLevel(of: converted), 0)
    }
}
