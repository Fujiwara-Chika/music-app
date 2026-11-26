import Foundation
import AVFoundation
import Accelerate

/// Real spectrum analyser.
///
/// Reads the PCM the transport is currently sitting on (same file, same offset),
/// applies a Hann window, runs a vDSP real FFT over 2048 samples and folds the
/// bins into 56 logarithmically spaced bands, in dB. No synthetic envelopes: if
/// there is no audio (the bundled demo library is silent), the meter is flat.
final class SpectrumAnalyzer {
    static let bandCount = 56
    static let fftSize = 2048

    private let queue = DispatchQueue(label: "local.aria.music.spectrum", qos: .userInitiated)

    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var sampleRate: Double = 44_100
    private var setup: FFTSetup?
    private var log2n: vDSP_Length = 11
    private var window: [Float] = []
    private var magnitudes: [Float] = []
    // Scratch for the FFT: allocated once in `makeSetup`. A 20 Hz meter used to
    // allocate a PCM buffer plus four arrays per tick; nothing here grows.
    /// A larger decoded window, reused across requests. The meter asks ~12×/s but
    /// the playhead advances only ~46 ms per FFT frame, so re-seeking and
    /// re-decoding the file for every request was the whole cost of the analyser.
    /// Decoding half a second at a time lets one read serve ~6 requests; a seek
    /// (scratch, next track) simply refills the window from the new position.
    private var blockBuffer: AVAudioPCMBuffer?
    private var blockStartFrame: AVAudioFramePosition = -1
    private var blockLength: AVAudioFrameCount = 0
    private var blockFrames: AVAudioFrameCount = 0
    private var samples = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize)
    private var windowed = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize)
    private var realPart = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize / 2)
    private var imagPart = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize / 2)
    private var bandTargetsScratch = [CGFloat](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var smoothed = [CGFloat](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var bandRanges: [(lower: Int, upper: Int)] = []

    // MARK: - Lifecycle

    func prepare(url: URL) {
        queue.async { [weak self] in
            guard let self else { return }
            self.file = try? AVAudioFile(forReading: url)
            guard let file = self.file else {
                self.smoothed = Array(repeating: 0, count: Self.bandCount)
                self.blockStartFrame = -1
                self.blockLength = 0
                return
            }
            self.format = file.processingFormat
            self.sampleRate = file.processingFormat.sampleRate
            self.makeSetup()
        }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.file = nil
            self.format = nil
            self.smoothed = Array(repeating: 0, count: Self.bandCount)
            self.blockStartFrame = -1
            self.blockLength = 0
        }
    }

    /// Bands at one instant, delivered on the main queue.
    func bands(at time: Double, completion: @escaping ([CGFloat]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let values = self.sampleBands(at: time)
            DispatchQueue.main.async { completion(values) }
        }
    }

    /// Synchronous variant for offscreen rendering, where there is no run loop.
    func bandsSync(at time: Double) -> [CGFloat] {
        queue.sync { sampleBands(at: time) }
    }

    // MARK: - Sampling

    /// Must run on `queue` (it mutates the smoothing and block-cache state).
    private func sampleBands(at time: Double) -> [CGFloat] {
        let zeros: [CGFloat] = Array(repeating: 0, count: Self.bandCount)
        guard let file, let block = blockBuffer else { return zeros }
        let n = Self.fftSize
        let wanted = AVAudioFramePosition((max(0, time) * file.processingFormat.sampleRate).rounded())

        // Serve from the decoded window when the whole FFT frame fits inside it;
        // only refill (one seek + decode) when it has run out or the playhead
        // jumped backwards/forwards past the window.
        let blockEnd = blockStartFrame + AVAudioFramePosition(blockLength)
        if blockStartFrame < 0 || wanted < blockStartFrame
            || wanted + AVAudioFramePosition(n) > blockEnd {
            do {
                file.framePosition = wanted
                try file.read(into: block, frameCount: blockFrames)
                blockStartFrame = wanted
                blockLength = block.frameLength
            } catch {
                blockStartFrame = -1
                blockLength = 0
                return zeros
            }
            guard blockLength > 0 else {
                blockStartFrame = -1
                return zeros
            }
        }

        let offset = Int(wanted - blockStartFrame)
        guard offset >= 0, offset < Int(blockLength),
              let channel = block.floatChannelData?[0] else {
            return zeros
        }

        // Copy into the scratch array: a short final frame is zero padded.
        let count = min(n, Int(blockLength) - offset)
        samples.withUnsafeMutableBufferPointer { destination in
            destination.baseAddress!.update(from: channel.advanced(by: offset), count: count)
            if count < n {
                destination.baseAddress!.advanced(by: count)
                    .update(repeating: 0, count: n - count)
            }
        }

        let targets = bandTargets()
        for index in 0..<Self.bandCount {
            let target = targets[index]
            // Fast attack, slow release — the way a hardware meter behaves.
            let rate: CGFloat = target > smoothed[index] ? 0.65 : 0.14
            smoothed[index] += (target - smoothed[index]) * rate
        }
        return smoothed
    }

    private func bandTargets() -> [CGFloat] {
        guard let setup, window.count == Self.fftSize, !bandRanges.isEmpty else {
            return Array(repeating: 0, count: Self.bandCount)
        }
        let n = Self.fftSize
        let half = n / 2

        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))

        realPart.withUnsafeMutableBufferPointer { realBuffer in
            imagPart.withUnsafeMutableBufferPointer { imagBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    let complex = raw.bindMemory(to: DSPComplex.self).baseAddress!
                    vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        // vDSP's real FFT returns twice the magnitude; normalise by N so a full
        // scale sine reads about 1.0.
        var scale = Float(1) / Float(n)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(half))

        for (index, range) in bandRanges.enumerated() {
            var peak: Float = 0
            for bin in range.lower...range.upper {
                peak = max(peak, magnitudes[bin])
            }
            let decibels = 20 * log10(max(peak, 1e-7))
            // A touch of tilt: music rolls off towards the treble, and without
            // this the right half of the meter never lifts off the floor.
            let tilt = Float(index) / Float(Self.bandCount - 1) * 8
            // -72 dB reads empty, -20 dB reads full. Measured on real tracks:
            // median band ≈ -52 dB, loudest ≈ -25 dB.
            let normalised = (decibels + tilt + 72) / 52
            bandTargetsScratch[index] = CGFloat(min(1, max(0, normalised)))
        }
        return bandTargetsScratch
    }

    // MARK: - Setup

    private func makeSetup() {
        let n = Self.fftSize
        log2n = vDSP_Length(log2(Float(n)).rounded())
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))

        magnitudes = [Float](repeating: 0, count: n / 2)
        var hann = [Float](repeating: 0, count: n)
        vDSP_hann_window(&hann, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        window = hann

        // One decoded window for every read: a block of half a second is served
        // to ~6 successive requests before it is refilled. The test hook has no
        // file, so there is nothing to allocate there.
        if let format {
            blockFrames = AVAudioFrameCount(max(Int(sampleRate / 2), n))
            blockBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames)
        }
        blockStartFrame = -1
        blockLength = 0

        // Logarithmic bands from 40 Hz to just under Nyquist.
        let lower = 40.0
        let upper = min(16_000.0, sampleRate / 2 - 100)
        let binWidth = sampleRate / Double(n)
        var ranges: [(Int, Int)] = []
        for band in 0..<Self.bandCount {
            let startFrequency = lower * pow(upper / lower, Double(band) / Double(Self.bandCount))
            let endFrequency = lower * pow(upper / lower, Double(band + 1) / Double(Self.bandCount))
            let lowBin = max(1, min(n / 2 - 1, Int(startFrequency / binWidth)))
            let highBin = max(lowBin, min(n / 2 - 1, Int(endFrequency / binWidth)))
            ranges.append((lowBin, highBin))
        }
        bandRanges = ranges
    }

    // MARK: - Test hooks

    /// One FFT of a buffer, no smoothing — used by the self test to prove the
    /// band mapping actually puts a tone in the band it belongs to.
    static func instants(of samples: [Float], sampleRate: Double) -> [CGFloat] {
        let analyzer = SpectrumAnalyzer()
        analyzer.sampleRate = sampleRate
        analyzer.makeSetup()
        analyzer.samples.withUnsafeMutableBufferPointer { destination in
            let count = min(samples.count, SpectrumAnalyzer.fftSize)
            destination.baseAddress!.update(from: samples, count: count)
            if count < SpectrumAnalyzer.fftSize {
                destination.baseAddress!.advanced(by: count)
                    .update(repeating: 0, count: SpectrumAnalyzer.fftSize - count)
            }
        }
        return analyzer.bandTargets()
    }

    /// Centre frequency of a band, for the self test's assertions.
    static func centreFrequency(of band: Int, sampleRate: Double) -> Double {
        let lower = 40.0
        let upper = min(16_000.0, sampleRate / 2 - 100)
        return lower * pow(upper / lower, (Double(band) + 0.5) / Double(bandCount))
    }
}
