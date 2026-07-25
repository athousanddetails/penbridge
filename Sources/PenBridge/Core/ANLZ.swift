import Foundation

/// Read-only parser for rekordbox ANLZ analysis files (`ANLZ0000.DAT` / `.EXT`).
/// Implemented from the crate-digger Kaitai spec (rekordbox_anlz.ksy). All
/// multi-byte values in these files are big-endian.
struct ANLZBeat {
    var beatNumber: Int     // position in the bar, 1...4
    var bpm: Double
    var timeMS: Int
}

struct ANLZCue {
    var hotCue: Int         // 0 = memory cue, 1...8 = hot cue A...H
    var isLoop: Bool
    var timeMS: Int
    var loopTimeMS: Int
    var comment: String
    var color: (a: UInt8, r: UInt8, g: UInt8, b: UInt8)?
}

struct ANLZData {
    var beats: [ANLZBeat] = []
    var cues: [ANLZCue] = []
    /// One byte per column; low 5 bits are height 0...31.
    var previewWaveform: [UInt8] = []
}

enum ANLZReader {
    /// rekordbox's default hot cue palette, indexed by `color_id` in PCO2 entries.
    /// Used when a cue carries an index rather than explicit RGB.
    private static let palette: [Int: (UInt8, UInt8, UInt8)] = [
        1: (0xE0, 0x64, 0x58), 2: (0xE0, 0x8B, 0x49), 3: (0xE0, 0xB0, 0x49),
        4: (0xC3, 0xE0, 0x49), 5: (0x71, 0xE0, 0x49), 6: (0x49, 0xE0, 0x7A),
        7: (0x49, 0xE0, 0xC3), 8: (0x49, 0xC3, 0xE0), 9: (0x49, 0x8B, 0xE0),
        10: (0x58, 0x64, 0xE0), 11: (0x8B, 0x49, 0xE0), 12: (0xC3, 0x49, 0xE0),
        13: (0xE0, 0x49, 0xC3), 14: (0xE0, 0x49, 0x8B), 15: (0xE0, 0x49, 0x64),
    ]

    private static func u16(_ b: [UInt8], _ o: Int) -> Int {
        guard o + 1 < b.count else { return 0 }
        return Int(b[o]) << 8 | Int(b[o + 1])
    }
    private static func u32(_ b: [UInt8], _ o: Int) -> Int {
        guard o + 3 < b.count else { return 0 }
        return Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
    }

    /// Reads a `.DAT` and, if present, its sibling `.EXT`. The `.EXT` carries
    /// the extended cue list (colours and comments) and supersedes the basic one.
    static func read(datURL: URL) -> ANLZData {
        var out = ANLZData()
        var extendedCues: [ANLZCue] = []
        var basicCues: [ANLZCue] = []

        for (url, isExt) in [(datURL, false),
                             (datURL.deletingPathExtension().appendingPathExtension("EXT"), true)] {
            guard let d = FileManager.default.contents(atPath: url.path) else { continue }
            let b = [UInt8](d)
            guard b.count > 12, b[0] == 0x50, b[1] == 0x4D, b[2] == 0x41, b[3] == 0x49 else { continue } // "PMAI"

            var off = u32(b, 4)      // len_header
            while off + 12 <= b.count {
                let fourcc = String(decoding: b[off..<(off + 4)], as: UTF8.self)
                let lenTag = u32(b, off + 8)
                if lenTag <= 0 { break }

                switch fourcc {
                case "PQTZ":
                    let numBeats = u32(b, off + 20)
                    var beats: [ANLZBeat] = []
                    beats.reserveCapacity(numBeats)
                    for i in 0..<numBeats {
                        let p = off + 24 + i * 8
                        guard p + 8 <= b.count else { break }
                        beats.append(ANLZBeat(beatNumber: u16(b, p),
                                              bpm: Double(u16(b, p + 2)) / 100.0,
                                              timeMS: u32(b, p + 4)))
                    }
                    if !beats.isEmpty { out.beats = beats }

                case "PCOB":
                    let numCues = u16(b, off + 18)
                    var p = off + 24
                    for _ in 0..<numCues {
                        guard p + 56 <= b.count else { break }
                        let lenEntry = u32(b, p + 8)
                        basicCues.append(ANLZCue(hotCue: u32(b, p + 12),
                                                 isLoop: b[p + 28] == 2,
                                                 timeMS: u32(b, p + 32),
                                                 loopTimeMS: u32(b, p + 36),
                                                 comment: "", color: nil))
                        p += lenEntry > 0 ? lenEntry : 56
                    }

                case "PCO2":
                    let numCues = u16(b, off + 16)
                    var p = off + 20
                    for _ in 0..<numCues {
                        guard p + 40 <= b.count else { break }
                        let lenEntry = u32(b, p + 8)
                        guard lenEntry >= 40, p + lenEntry <= b.count else { break }

                        var comment = ""
                        var lenComment = 0
                        if lenEntry > 43 {
                            lenComment = u32(b, p + 40)
                            if lenComment > 0, p + 44 + lenComment <= b.count {
                                let raw = Array(b[(p + 44)..<(p + 44 + lenComment)])
                                var units: [UInt16] = []
                                var i = 0
                                while i + 1 < raw.count {           // UTF-16BE
                                    units.append(UInt16(raw[i]) << 8 | UInt16(raw[i + 1]))
                                    i += 2
                                }
                                comment = String(decoding: units, as: UTF16.self)
                                    .replacingOccurrences(of: "\0", with: "")
                            }
                        }

                        var color: (UInt8, UInt8, UInt8, UInt8)?
                        let colorBase = p + 44 + lenComment
                        if lenEntry - lenComment > 47, colorBase + 3 < b.count {
                            color = (0xFF, b[colorBase + 1], b[colorBase + 2], b[colorBase + 3])
                        } else if let rgb = palette[Int(b[p + 24])] {
                            color = (0xFF, rgb.0, rgb.1, rgb.2)
                        }

                        extendedCues.append(ANLZCue(hotCue: u32(b, p + 12),
                                                    isLoop: b[p + 16] == 2,
                                                    timeMS: u32(b, p + 20),
                                                    loopTimeMS: u32(b, p + 24),
                                                    comment: comment,
                                                    color: color))
                        p += lenEntry
                    }

                case "PWAV":
                    let lenData = u32(b, off + 12)
                    let start = off + 20
                    if lenData > 0, start + lenData <= b.count {
                        out.previewWaveform = Array(b[start..<(start + lenData)])
                    }

                default:
                    break
                }
                off += lenTag
                _ = isExt
            }
        }

        out.cues = extendedCues.isEmpty ? basicCues : extendedCues
        return out
    }
}
