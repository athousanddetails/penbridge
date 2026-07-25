import Foundation
import CZlib

/// Encoders for the binary blobs Engine stores in the `Track` performance columns.
/// Layouts follow libdjinterop, which derives them from real Engine databases.
/// The v2 and v3 blob layouts are byte-identical, so one implementation covers
/// schema 2.21.0 and 3.0.1.
enum EngineBlobs {

    // MARK: - byte assembly

    private static func appendBE<T: FixedWidthInteger>(_ v: T, to out: inout [UInt8]) {
        withUnsafeBytes(of: v.bigEndian) { out.append(contentsOf: $0) }
    }
    private static func appendLE<T: FixedWidthInteger>(_ v: T, to out: inout [UInt8]) {
        withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) }
    }
    private static func appendDoubleBE(_ v: Double, to out: inout [UInt8]) {
        appendBE(v.bitPattern, to: &out)
    }
    private static func appendDoubleLE(_ v: Double, to out: inout [UInt8]) {
        appendLE(v.bitPattern, to: &out)
    }

    /// Qt's `qCompress` framing: 4-byte big-endian uncompressed length, then a
    /// zlib stream. Engine will not accept a bare deflate stream here.
    static func zlibCompress(_ input: [UInt8]) -> Data {
        var out = [UInt8]()
        appendBE(UInt32(input.count), to: &out)

        var bound = compressBound(uLong(input.count))
        var dest = [UInt8](repeating: 0, count: Int(bound))
        let rc: Int32 = input.withUnsafeBufferPointer { src in
            compress2(&dest, &bound, src.baseAddress, uLong(input.count), Z_DEFAULT_COMPRESSION)
        }
        precondition(rc == Z_OK, "zlib compression failed with code \(rc)")
        out.append(contentsOf: dest[0..<Int(bound)])
        return Data(out)
    }

    // MARK: - trackData

    static func trackData(sampleRate: Double, samples: Int64, key: Int32,
                          loudness: Double = 0.5) -> Data {
        var u = [UInt8]()
        appendDoubleBE(sampleRate, to: &u)
        appendBE(samples, to: &u)
        appendBE(key, to: &u)
        appendDoubleBE(loudness, to: &u)   // low
        appendDoubleBE(loudness, to: &u)   // mid
        appendDoubleBE(loudness, to: &u)   // high
        return zlibCompress(u)             // 44 bytes uncompressed
    }

    // MARK: - beatData

    struct BeatMarker {
        var sampleOffset: Double
        var beatNumber: Int64
        var numberOfBeats: Int32
    }

    static func beatData(sampleRate: Double, samples: Double, markers: [BeatMarker]) -> Data {
        var u = [UInt8]()
        appendDoubleBE(sampleRate, to: &u)
        appendDoubleBE(samples, to: &u)
        u.append(markers.isEmpty ? 0 : 1)             // isBeatgridSet
        for _ in 0..<2 {                              // default grid, then adjusted grid
            appendBE(Int64(markers.count), to: &u)
            for m in markers {
                appendDoubleLE(m.sampleOffset, to: &u)
                appendLE(m.beatNumber, to: &u)
                appendLE(m.numberOfBeats, to: &u)
                appendLE(Int32(0), to: &u)            // unknown, always zero
            }
        }
        return zlibCompress(u)
    }

    // MARK: - quickCues

    struct QuickCue {
        var label: String
        var sampleOffset: Double                      // -1 marks an empty slot
        var color: (a: UInt8, r: UInt8, g: UInt8, b: UInt8)
        static let empty = QuickCue(label: "", sampleOffset: -1, color: (0, 0, 0, 0))
    }

    static let maxQuickCues = 8
    static let maxLoops = 8

    static func quickCues(_ cues: [QuickCue], mainCue: Double) -> Data {
        var padded = cues
        while padded.count < maxQuickCues { padded.append(.empty) }
        padded = Array(padded.prefix(maxQuickCues))

        var u = [UInt8]()
        appendBE(Int64(padded.count), to: &u)
        for c in padded {
            let label = Array(c.label.utf8.prefix(255))
            u.append(UInt8(label.count))
            u.append(contentsOf: label)
            appendDoubleBE(c.sampleOffset, to: &u)
            u.append(c.color.a); u.append(c.color.r); u.append(c.color.g); u.append(c.color.b)
        }
        appendDoubleBE(mainCue, to: &u)               // adjustedMainCue
        u.append(mainCue != 0 ? 1 : 0)                // isMainCueAdjusted
        appendDoubleBE(mainCue, to: &u)               // defaultMainCue
        return zlibCompress(u)
    }

    // MARK: - loops  (stored uncompressed, little-endian)

    struct Loop {
        var label: String
        var startSampleOffset: Double
        var endSampleOffset: Double
        var color: (a: UInt8, r: UInt8, g: UInt8, b: UInt8)
        static let empty = Loop(label: "", startSampleOffset: -1,
                                endSampleOffset: -1, color: (0, 0, 0, 0))
        var isSet: Bool { startSampleOffset >= 0 }
    }

    static func loops(_ loops: [Loop]) -> Data {
        var padded = loops
        while padded.count < maxLoops { padded.append(.empty) }
        padded = Array(padded.prefix(maxLoops))

        var u = [UInt8]()
        appendLE(Int64(padded.count), to: &u)
        for l in padded {
            let label = Array(l.label.utf8.prefix(255))
            u.append(UInt8(label.count))
            u.append(contentsOf: label)
            appendDoubleLE(l.startSampleOffset, to: &u)
            appendDoubleLE(l.endSampleOffset, to: &u)
            u.append(l.isSet ? 1 : 0)
            u.append(l.isSet ? 1 : 0)
            u.append(l.color.a); u.append(l.color.r); u.append(l.color.g); u.append(l.color.b)
        }
        return Data(u)                                // deliberately not compressed
    }

    // MARK: - overviewWaveFormData

    /// Builds the overview strip from rekordbox's `PWAV` preview (one byte per
    /// column, low 5 bits = height 0...31). Engine renders its own detailed
    /// waveform on load, so only this overview needs to be supplied.
    static func overviewWaveform(preview: [UInt8], samples: Int64) -> Data? {
        guard !preview.isEmpty, samples > 0 else { return nil }
        let points: [UInt8] = preview.map { UInt8(min(255, Int($0 & 0x1F) * 8)) }
        let samplesPerPoint = Double(samples) / Double(points.count)
        let maxValue = points.max() ?? 0

        var u = [UInt8]()
        appendBE(Int64(points.count), to: &u)
        appendBE(Int64(points.count), to: &u)
        appendDoubleBE(samplesPerPoint, to: &u)
        for p in points {
            u.append(p)          // low
            u.append(p)          // mid
            u.append(p)          // high
        }
        u.append(maxValue); u.append(maxValue); u.append(maxValue)
        return zlibCompress(u)
    }

    // MARK: - musical key mapping

    /// Engine's key numbering (libdjinterop `musical_key`): 0 = C major,
    /// 1 = A minor, then ascending the circle of fifths in major/minor pairs.
    private static let engineKeyIndex: [String: Int32] = {
        let order = ["C", "Am", "G", "Em", "D", "Bm", "A", "F#m", "E", "Dbm",
                     "B", "Abm", "F#", "Ebm", "Db", "Bbm", "Ab", "Fm",
                     "Eb", "Cm", "Bb", "Gm", "F", "Dm"]
        var m: [String: Int32] = [:]
        for (i, k) in order.enumerated() { m[k] = Int32(i) }
        return m
    }()

    /// Camelot / Open Key wheel positions, so rekordbox keys written in any of
    /// the common notations resolve to the same Engine index.
    private static let camelotToEngine: [String: Int32] = {
        let majors = ["8B": "C", "9B": "G", "10B": "D", "11B": "A", "12B": "E",
                      "1B": "B", "2B": "F#", "3B": "Db", "4B": "Ab", "5B": "Eb",
                      "6B": "Bb", "7B": "F"]
        let minors = ["8A": "Am", "9A": "Em", "10A": "Bm", "11A": "F#m", "12A": "Dbm",
                      "1A": "Abm", "2A": "Ebm", "3A": "Bbm", "4A": "Fm", "5A": "Cm",
                      "6A": "Gm", "7A": "Dm"]
        var m: [String: Int32] = [:]
        for (c, k) in majors.merging(minors, uniquingKeysWith: { a, _ in a }) {
            if let idx = engineKeyIndex[k] { m[c] = idx }
        }
        return m
    }()

    /// Best-effort conversion of a rekordbox key label to an Engine key index.
    /// Returns nil when the label is absent or unrecognised, in which case the
    /// key column is left NULL rather than guessed.
    static func engineKey(from rekordboxKey: String) -> Int32? {
        var s = rekordboxKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        let upper = s.uppercased()
        if let c = camelotToEngine[upper] { return c }

        s = s.replacingOccurrences(of: "♯", with: "#")
             .replacingOccurrences(of: "♭", with: "b")
        // Normalise "Am", "A min", "A minor", "Amin" to "Am"; majors drop the suffix.
        let lowered = s.lowercased()
        let isMinor = lowered.hasSuffix("m") || lowered.contains("min")
        var root = s
        for suffix in ["minor", "major", "min", "maj", "m", "M"] {
            if root.count > 1, root.lowercased().hasSuffix(suffix.lowercased()) {
                root = String(root.dropLast(suffix.count))
                break
            }
        }
        root = root.trimmingCharacters(in: .whitespaces)
        guard !root.isEmpty else { return nil }
        let normalisedRoot = root.prefix(1).uppercased() + root.dropFirst()

        // Fold enharmonic spellings onto the ones Engine indexes.
        let enharmonic = ["A#": "Bb", "C#": "Db", "D#": "Eb", "G#": "Ab", "Gb": "F#"]
        let finalRoot = enharmonic[normalisedRoot] ?? normalisedRoot
        return engineKeyIndex[isMinor ? finalRoot + "m" : finalRoot]
    }
}
