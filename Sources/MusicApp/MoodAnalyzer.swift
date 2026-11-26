import AVFoundation
import Accelerate
import Foundation

/// Offline mood analysis: decode a few windows of a file, take an FFT of each,
/// and reduce them to `tempo` (onset autocorrelation), `valence` (major/minor
/// tonality plus spectral brightness) and `energy` (short-term RMS).
///
/// Everything runs at 22.05 kHz mono — enough for chroma below 2 kHz and a
/// spectral centroid, and 2× cheaper than the file's own rate. The whole library
/// is analysed once and stored in the snapshot; a rescan only touches files whose
/// mtime/size changed.
enum MoodAnalyzer {
    /// Windows per track and their length. Three 20 s slices land inside the
    /// arrangement without spending a minute decoding a 5 minute track.
    static let windowSeconds = 20.0
    static let windowCount = 3
    static let analysisRate = 22_050.0

    /// Track count the caller uses to report progress; the analyser itself is
    /// stateless so it can run on any number of tasks.
    nonisolated static func analyze(url: URL,
                                    windows: Int = windowCount,
                                    seconds: Double = windowSeconds) -> MoodFeatures? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let frameLength = format.channelCount
        guard sampleRate > 0, file.length > 0 else { return nil }

        let totalFrames = AVAudioFramePosition(file.length)

        // Simple anti-aliasing for the stride decimation below: a two tap average
        // at the source rate halves the band before we drop every other sample.
        let step = max(1, Int((sampleRate / analysisRate).rounded()))
        let effectiveRate = sampleRate / Double(step)

        var collected: [(tempo: Double, valence: Double, energy: Double, key: String)] = []
        collected.reserveCapacity(windows)

        for index in 0..<windows {
            // Spread the windows over the middle 90%: intros and fades tell us
            // least about the song's character.
            let fraction = windows == 1 ? 0.5 : 0.05 + 0.9 * Double(index) / Double(windows - 1)
            let start = AVAudioFramePosition(Double(totalFrames) * fraction)
            let wanted = AVAudioFrameCount(min(seconds * sampleRate, Double(totalFrames - start)))
            guard wanted > 4096 else { continue }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: wanted) else { continue }
            file.framePosition = start
            guard (try? file.read(into: buffer, frameCount: wanted)) != nil else { continue }
            guard let samples = mono(from: buffer, step: step, channels: frameLength) else { continue }
            guard let window = analyzeWindow(samples, rate: effectiveRate) else { continue }
            collected.append(window)
        }

        guard !collected.isEmpty else { return nil }

        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }

        let tempo = median(collected.map(\.tempo))
        let valence = median(collected.map(\.valence))
        let energy = median(collected.map(\.energy))
        let key = collected[collected.count / 2].key
        // tempo == 0 means "no usable beat" (pads, drones); the map centres those
        // instead of dropping them.
        guard tempo >= 0, tempo.isFinite, valence.isFinite else { return nil }
        return MoodFeatures(tempo: tempo,
                            valence: min(max(valence, -1), 1),
                            energy: min(max(energy, 0), 1),
                            key: key)
    }

    // MARK: - One window

    private static func analyzeWindow(_ samples: [Float], rate: Double) -> (tempo: Double, valence: Double, energy: Double, key: String)? {
        let bufferSize = 2048
        let hop = 512
        let bins = bufferSize / 2
        guard samples.count > bufferSize * 8 else { return nil }

        var window = [Float](repeating: 0, count: bufferSize)
        vDSP_hann_window(&window, vDSP_Length(bufferSize), Int32(vDSP_HANN_NORM))

        var real = [Float](repeating: 0, count: bins)
        var imaginary = [Float](repeating: 0, count: bins)
        var magnitudes = [Float](repeating: 0, count: bins)
        var windowed = [Float](repeating: 0, count: bufferSize)
        var previous = [Float](repeating: 0, count: bins)
        var flux: [Double] = []
        flux.reserveCapacity(samples.count / hop)

        var chroma = [Double](repeating: 0, count: 12)
        var centroidSum = 0.0
        var centroidWeight = 0.0
        var squareSum = 0.0
        var frames = 0

        let binWidth = rate / Double(bufferSize)
        let log2Size = vDSP_Length(round(log2(Double(bufferSize))))
        guard let fft = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(fft) }

        var start = 0
        while start + bufferSize <= samples.count {
            samples.withUnsafeBufferPointer { pointer in
                let base = pointer.baseAddress! + start
                vDSP_vmul(base, 1, window, 1, &windowed, 1, vDSP_Length(bufferSize))
            }

            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    magnitudes.withUnsafeMutableBufferPointer { magnitudePointer in
                        guard let realBase = realPointer.baseAddress,
                              let imaginaryBase = imaginaryPointer.baseAddress,
                              let magnitudeBase = magnitudePointer.baseAddress else { return }
                        var split = DSPSplitComplex(realp: realBase, imagp: imaginaryBase)
                        windowed.withUnsafeBufferPointer { pointer in
                            guard let base = pointer.baseAddress else { return }
                            base.withMemoryRebound(to: DSPComplex.self, capacity: bins) { complex in
                                vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(bins))
                            }
                        }
                        vDSP_fft_zrip(fft, &split, 1, log2Size, FFTDirection(FFT_FORWARD))
                        vDSP_zvabs(&split, 1, magnitudeBase, 1, vDSP_Length(bins))
                    }
                }
            }

            // Spectral flux drives tempo; only the low band matters for onsets
            // and it keeps the envelope from following cymbal noise.
            let fluxBins = min(bins, Int(4_000 / binWidth))
            var frameFlux = 0.0
            for bin in 0..<fluxBins {
                let value = magnitudes[bin]
                let difference = value - previous[bin]
                if difference > 0 { frameFlux += Double(difference) }
                previous[bin] = value
            }
            flux.append(frameFlux)

            // Chroma over 65 Hz…2 kHz, and the centroid over the full band.
            var frameCentroid = 0.0
            var frameMagnitude = 0.0
            for bin in 1..<bins {
                let frequency = Double(bin) * binWidth
                let magnitude = Double(magnitudes[bin])
                frameCentroid += frequency * magnitude
                frameMagnitude += magnitude
                guard frequency >= 65, frequency <= 2_000, magnitude > 0 else { continue }
                let midi = 69 + 12 * log2(frequency / 440.0)
                let pitchClass = ((Int(midi.rounded()) % 12) + 12) % 12
                chroma[pitchClass] += magnitude
            }
            if frameMagnitude > 0 {
                centroidSum += frameCentroid / frameMagnitude
                centroidWeight += 1
            }

            for sample in samples[start..<(start + bufferSize)] {
                squareSum += Double(sample) * Double(sample)
            }
            frames += 1
            start += hop
        }

        guard frames > 0 else { return nil }

        let tempo = estimateTempo(flux: flux, hopSeconds: Double(hop) / rate)
        let centroid = centroidWeight > 0 ? centroidSum / centroidWeight : 0
        let brightness = min(max(log(max(centroid, 50) / 200) / log(8_000 / 200), 0), 1)
        let rms = (squareSum / Double(frames * bufferSize)).squareRoot()
        let energy = min(max(rms / 0.3, 0), 1)
        let (key, tonality) = estimateKey(chroma)
        // Tonality dominates (it is what "major vs minor" means) and brightness
        // nudges: a bright minor track is less gloomy than a dull one.
        let valence = min(max(0.72 * tonality + 0.28 * (2 * brightness - 1), -1), 1)
        return (tempo, valence, energy, key)
    }

    // MARK: - Tempo

    /// Tempo from the onset envelope by combing it over tempo hypotheses.
    ///
    /// Plain integer-lag autocorrelation is fragile here: the hop is 23 ms, so a
    /// 120 BPM pulse lands at 21.53 frames and an integer lag smears by half a
    /// frame per beat. Instead each hypothesis is scored by sampling the envelope
    /// at fractional multiples of its period (with linear interpolation) and
    /// averaging, which tolerates that drift.
    private static func estimateTempo(flux: [Double], hopSeconds: Double) -> Double {
        guard flux.count > 32, hopSeconds > 0 else { return 0 }
        let mean = flux.reduce(0, +) / Double(flux.count)
        let centred = flux.map { $0 - mean }
        let variance = centred.reduce(0) { $0 + $1 * $1 } / Double(centred.count)
        // A drone or a sustained pad has no onsets to lock onto.
        guard variance > 1e-12 else { return 0 }

        func sample(_ position: Double) -> Double {
            let index = Int(position)
            guard index >= 0, index + 1 < centred.count else { return 0 }
            let fraction = position - Double(index)
            return centred[index] * (1 - fraction) + centred[index + 1] * fraction
        }

        func score(bpm: Double) -> Double {
            let period = 60.0 / bpm / hopSeconds
            guard period > 1 else { return 0 }
            var total = 0.0
            var count = 0
            var harmonic = 1.0
            while harmonic <= 3, Double(harmonic) * period < Double(centred.count) / 2 {
                let offset = Double(harmonic) * period
                var sum = 0.0
                var pairs = 0
                var index = 0
                while index + Int(offset) + 1 < centred.count {
                    sum += centred[index] * sample(Double(index) + offset)
                    pairs += 1
                    index += 1
                }
                if pairs > 0 {
                    // Higher harmonics are weaker evidence: weight them down.
                    total += (sum / Double(pairs)) * (1.0 / harmonic)
                    count += 1
                }
                harmonic += 1
            }
            return count > 0 ? total / Double(count) : 0
        }

        // Half/double ambiguity: a 120 BPM pulse scores just as well at 60, so
        // multiply by a broad preference curve centred on 120 BPM (σ ≈ 1.1
        // octaves). A real 60 BPM ballad still wins, because its 120 BPM score is
        // far weaker than the halved one.
        func preference(_ bpm: Double) -> Double {
            let octaves = log2(bpm / 120.0)
            return exp(-0.5 * (octaves / 1.1) * (octaves / 1.1))
        }

        var bestBPM = 0.0
        var bestScore = -Double.greatestFiniteMagnitude
        var scores: [(bpm: Double, score: Double)] = []
        var bpm = 60.0
        while bpm <= 200.0 {
            let value = score(bpm: bpm) * preference(bpm)
            scores.append((bpm, value))
            if value > bestScore {
                bestScore = value
                bestBPM = bpm
            }
            bpm += 0.5
        }
        guard bestScore > 0 else { return 0 }

        // A 120 BPM pulse also scores at 60 BPM (its 1st harmonic is two beats),
        // so the raw winner is often the half tempo. Real music sits mostly in
        // 85–170: double anything slow when the double is nearly as good, and
        // halve anything above 180.
        func score(at bpm: Double) -> Double {
            scores.min { abs($0.bpm - bpm) < abs($1.bpm - bpm) }?.score ?? 0
        }
        if bestBPM < 90 {
            let doubled = bestBPM * 2
            if doubled <= 200, score(at: doubled) >= bestScore * 0.95 { bestBPM = doubled }
        }
        if bestBPM > 180 {
            let halved = bestBPM / 2
            if halved >= 60, score(at: halved) >= bestScore * 0.95 { bestBPM = halved }
        }
        return min(max(bestBPM, 60), 200)
    }

    // MARK: - Key

    /// Krumhansl–Kessler profiles: correlate the chroma vector with all 24
    /// rotations and keep the best. Returns the key name and a -1…+1 tonality
    /// (major positive, minor negative).
    private static func estimateKey(_ chroma: [Double]) -> (String, Double) {
        let major = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minor = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

        let total = chroma.reduce(0, +)
        guard total > 0 else { return ("", 0) }
        let normalized = chroma.map { $0 / total }

        func correlation(_ profile: [Double], rotatedBy rotation: Int) -> Double {
            var dot = 0.0, a = 0.0, b = 0.0
            for index in 0..<12 {
                let value = normalized[(index + rotation) % 12]
                let weight = profile[index]
                dot += value * weight
                a += value * value
                b += weight * weight
            }
            guard a > 0, b > 0 else { return 0 }
            return dot / (a.squareRoot() * b.squareRoot())
        }

        var bestScore = -Double.greatestFiniteMagnitude
        var bestRotation = 0
        var bestIsMajor = true
        for rotation in 0..<12 {
            let majorScore = correlation(major, rotatedBy: rotation)
            if majorScore > bestScore { bestScore = majorScore; bestRotation = rotation; bestIsMajor = true }
            let minorScore = correlation(minor, rotatedBy: rotation)
            if minorScore > bestScore { bestScore = minorScore; bestRotation = rotation; bestIsMajor = false }
        }
        let name = names[bestRotation] + (bestIsMajor ? "" : "m")
        // How much better the winner is than the best of the opposite mode at the
        // same root: that difference is what "sounds major" actually means here.
        let majorAtRoot = correlation(major, rotatedBy: bestRotation)
        let minorAtRoot = correlation(minor, rotatedBy: bestRotation)
        let tonality = (majorAtRoot - minorAtRoot) * 4
        return (name, min(max(tonality, -1), 1))
    }

    // MARK: - Decoding

    /// Average the channels, cheaply low-pass, then decimate to the analysis rate.
    private static func mono(from buffer: AVAudioPCMBuffer,
                             step: Int,
                             channels: AVAudioChannelCount) -> [Float]? {
        guard let data = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0, channels > 0 else { return nil }
        let count = frames / step
        guard count > 0 else { return nil }
        var mono = [Float](repeating: 0, count: count)

        let gain = 1 / Float(channels)
        for index in 0..<count {
            let source = index * step
            var sum: Float = 0
            for channel in 0..<Int(channels) {
                let pointer = data[channel]
                if step == 1 {
                    sum += pointer[source]
                } else {
                    sum += (pointer[source] + pointer[min(source + 1, frames - 1)]) * 0.5
                }
            }
            mono[index] = sum * gain
        }
        return mono
    }
}
