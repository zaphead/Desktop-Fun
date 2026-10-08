import AVFoundation

/// Synthesized robot quacks, laughs and whistles (no audio files), panned left/right to follow the duck
/// across your screens.
final class Quacker {
    var muted = false
    var volumeScale: Float = 0.7
    /// -1 (far left of your desk) ... 1 (far right). Updated by the duck every frame.
    var pan: Float = 0
    private var sounds: [String: [Data]] = [:]
    private var playing: [AVAudioPlayer] = []

    init() {
        sounds["quack"] = (0..<4).map { i in Quacker.voice([(0.0, 0.13, 640 + Double(i) * 45, 0.7), (0.15, 0.11, 560 + Double(i) * 40, 0.7)]) }
        sounds["chirp"] = (0..<3).map { i in Quacker.voice([(0.0, 0.07, 900 + Double(i) * 120, 1.5)]) }
        sounds["wee"] = [Quacker.voice([(0.0, 0.45, 520, 1.9)])]
        sounds["boing"] = [Quacker.voice([(0.0, 0.16, 300, 1.8)], buzz: 0.1)]
        sounds["bonk"] = [Quacker.voice([(0.0, 0.08, 180, 0.6)], buzz: 0.2)]
        sounds["beepbeep"] = [Quacker.voice([(0.0, 0.07, 1250, 1.05), (0.11, 0.07, 1250, 1.05)], buzz: 0.15)]
        // Mischief: a quick "heh-heh" snicker and a longer cackle that runs down the scale.
        sounds["snicker"] = (0..<3).map { i in
            let f = 820 + Double(i) * 70
            return Quacker.voice([(0.0, 0.05, f, 1.15), (0.08, 0.05, f * 1.04, 1.15), (0.16, 0.06, f * 1.08, 1.1)], buzz: 0.45)
        }
        sounds["laugh"] = (0..<3).map { i in
            let f = 760 + Double(i) * 60
            return Quacker.voice((0..<6).map { k in
                (Double(k) * 0.085, 0.06, f * (1.12 - Double(k) * 0.045), 1.12)
            }, buzz: 0.5)
        }
        sounds["whistle"] = [Quacker.whistle()]
    }

    func play(_ name: String, volume: Float = 0.35) {
        guard !muted, let data = sounds[name]?.randomElement(),
              let p = try? AVAudioPlayer(data: data) else { return }
        playing.removeAll { !$0.isPlaying }
        p.volume = volume * volumeScale * 1.4
        p.pan = max(-1, min(1, pan))
        p.play()
        playing.append(p)
    }

    // MARK: Synthesis

    /// Buzzy, nasal syllables: a pitch-swept pulse wave through a crude formant filter, plus a robotic ring-mod.
    /// Each syllable is (start, duration, start pitch, pitch sweep multiplier).
    private static func voice(_ syllables: [(Double, Double, Double, Double)], buzz: Double = 0.35) -> Data {
        let rate = 44100.0
        let total = (syllables.map { $0.0 + $0.1 }.max() ?? 0.2) + 0.02
        var samples = [Float](repeating: 0, count: Int(total * rate))
        for (start, dur, f0, sweep) in syllables {
            var phase = 0.0, lp1 = 0.0, lp2 = 0.0
            let s0 = Int(start * rate), len = Int(dur * rate)
            for k in 0..<len where s0 + k < samples.count {
                let t = Double(k) / Double(len)
                let f = f0 * (1 + (sweep - 1) * t) * (1 + 0.04 * sin(t * 40))
                phase += f / rate
                let frac = phase - floor(phase)
                var v = frac < 0.28 ? 1.0 : -0.4
                v += 0.5 * sin(2 * .pi * phase * 3)
                lp1 += 0.35 * (v - lp1)
                lp2 += 0.35 * (lp1 - lp2)
                let ring = 1 - buzz + buzz * sin(2 * .pi * 70 * Double(k) / rate)
                let env = min(1, t * 30) * pow(1 - t, 1.4)
                samples[s0 + k] += Float(lp2 * ring * env * 0.6)
            }
        }
        return wav(samples, rate: Int(rate))
    }

    /// An innocent two-note "who, me?" whistle: pure tones gliding up, then down.
    private static func whistle() -> Data {
        let rate = 44100.0
        let notes: [(Double, Double, Double, Double)] = [(0.0, 0.28, 1300, 1750), (0.34, 0.42, 1750, 1150)]
        var samples = [Float](repeating: 0, count: Int(0.8 * rate))
        for (start, dur, fa, fb) in notes {
            var phase = 0.0
            let s0 = Int(start * rate), len = Int(dur * rate)
            for k in 0..<len where s0 + k < samples.count {
                let t = Double(k) / Double(len)
                let f = fa + (fb - fa) * t * t + 25 * sin(t * 50)   // slight vibrato
                phase += f / rate
                let env = min(1, t * 12) * min(1, (1 - t) * 6)
                samples[s0 + k] += Float(sin(2 * .pi * phase) * env * 0.5)
            }
        }
        return wav(samples, rate: Int(rate))
    }

    private static func wav(_ s: [Float], rate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + s.count * 2))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(s.count * 2))
        for v in s { u16(UInt16(bitPattern: Int16(max(-1, min(1, v)) * 32000))) }
        return d
    }
}
