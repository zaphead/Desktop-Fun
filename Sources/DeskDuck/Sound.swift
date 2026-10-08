import AppKit

/// Synthesized robot quacks — no audio files needed.
final class Quacker {
    var muted = false
    var volumeScale: Float = 0.7
    private var sounds: [String: [NSSound]] = [:]

    init() {
        sounds["quack"] = (0..<4).map { i in Quacker.make(syllables: [(0.0, 0.13, 640 + Double(i) * 45), (0.15, 0.11, 560 + Double(i) * 40)]) }
        sounds["chirp"] = (0..<3).map { i in Quacker.make(syllables: [(0.0, 0.07, 900 + Double(i) * 120)], sweep: 1.5) }
        sounds["wee"] = [Quacker.make(syllables: [(0.0, 0.45, 520)], sweep: 1.9)]
        sounds["boing"] = [Quacker.make(syllables: [(0.0, 0.16, 300)], sweep: 1.8, buzz: 0.1)]
        sounds["bonk"] = [Quacker.make(syllables: [(0.0, 0.08, 180)], sweep: 0.6, buzz: 0.2)]
    }

    func play(_ name: String, volume: Float = 0.35) {
        guard !muted, let s = sounds[name]?.randomElement() else { return }
        let copy = (s.copy() as? NSSound) ?? s
        copy.volume = volume * volumeScale * 1.4
        copy.play()
    }

    /// Builds a WAV of buzzy, nasal "quack" syllables: a pitch-swept pulse wave run through a
    /// crude formant filter, with a robotic ring-mod on top.
    private static func make(syllables: [(start: Double, dur: Double, f0: Double)], sweep: Double = 0.7, buzz: Double = 0.35) -> NSSound {
        let rate = 44100.0
        let total = (syllables.map { $0.start + $0.dur }.max() ?? 0.2) + 0.02
        let n = Int(total * rate)
        var samples = [Float](repeating: 0, count: n)
        for syl in syllables {
            var phase = 0.0
            var lp1 = 0.0, lp2 = 0.0
            let s0 = Int(syl.start * rate), len = Int(syl.dur * rate)
            for k in 0..<len where s0 + k < n {
                let t = Double(k) / Double(len)
                let f = syl.f0 * (1 + (sweep - 1) * t) * (1 + 0.04 * sin(t * 40))
                phase += f / rate
                let frac = phase - floor(phase)
                var v = frac < 0.28 ? 1.0 : -0.4          // narrow pulse = nasal
                v += 0.5 * sin(2 * .pi * phase * 3)       // emphasize 3rd harmonic like a duck formant
                lp1 += 0.35 * (v - lp1)
                lp2 += 0.35 * (lp1 - lp2)
                let ring = 1 - buzz + buzz * sin(2 * .pi * 70 * Double(k) / rate)
                let env = min(1, t * 30) * pow(1 - t, 1.4)
                samples[s0 + k] += Float(lp2 * ring * env * 0.6)
            }
        }
        return NSSound(data: wav(samples, rate: Int(rate)))!
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
