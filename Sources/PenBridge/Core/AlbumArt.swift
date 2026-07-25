import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Extracts cover art for a track and normalises it for storage in Engine's
/// `AlbumArt` table.
///
/// rekordbox's own `PIONEER/Artwork` cache holds only 80×80 thumbnails, which
/// look poor on a Prime's screen, so the embedded picture in the audio file is
/// preferred and the thumbnail is used only as a fallback.
enum AlbumArt {

    /// Longest edge of the stored image. Large enough for the hardware displays,
    /// small enough that a few thousand covers do not bloat the database.
    static let maxPixelSize = 480
    static let jpegQuality = 0.82

    struct Artwork {
        var data: Data
        var sha1: String
    }

    /// Reads cover art for one track, preferring the picture embedded in the
    /// audio file. Returns nil when neither source has usable art.
    static func artwork(audioFile: URL, fallbackThumbnail: URL?) -> Artwork? {
        var source: Data?
        if let embedded = embeddedPicture(in: audioFile), !embedded.isEmpty {
            source = embedded
        } else if let thumb = fallbackThumbnail,
                  let d = try? Data(contentsOf: thumb), !d.isEmpty {
            source = d
        }
        guard let source, let encoded = reencode(source) else { return nil }
        let digest = Insecure.SHA1.hash(data: encoded)
        return Artwork(data: encoded, sha1: digest.map { String(format: "%02x", $0) }.joined())
    }

    /// Decodes, optionally downscales, and re-encodes as JPEG so every stored
    /// cover is a predictable size and format.
    private static func reencode(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            return nil
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(
            dest, image,
            [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: - ID3 APIC extraction

    /// Pulls the front-cover picture out of an ID3v2 tag. Only the tag itself is
    /// read, never the audio, so this stays cheap across thousands of files.
    static func embeddedPicture(in url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let header = try? handle.read(upToCount: 10), header.count == 10 else { return nil }
        let h = [UInt8](header)
        guard h[0] == 0x49, h[1] == 0x44, h[2] == 0x33 else { return nil }   // "ID3"

        let major = h[3]
        let flags = h[4]
        let tagSize = synchsafe(h[6], h[7], h[8], h[9])
        guard tagSize > 0, tagSize < 64 * 1024 * 1024,
              let body = try? handle.read(upToCount: tagSize), body.count == tagSize else { return nil }

        let d = [UInt8](body)
        var i = 0

        // Skip an extended header if one is present.
        if flags & 0x40 != 0, d.count >= 4 {
            let extSize = major >= 4
                ? synchsafe(d[0], d[1], d[2], d[3])
                : Int(d[0]) << 24 | Int(d[1]) << 16 | Int(d[2]) << 8 | Int(d[3]) + 4
            i += max(0, min(extSize, d.count))
        }

        let idLength = major == 2 ? 3 : 4
        let headerLength = major == 2 ? 6 : 10
        var best: Data?

        while i + headerLength <= d.count {
            let id = String(decoding: d[i..<(i + idLength)], as: UTF8.self)
            if d[i] == 0 { break }                                   // padding

            var frameSize: Int
            if major == 2 {
                frameSize = Int(d[i + 3]) << 16 | Int(d[i + 4]) << 8 | Int(d[i + 5])
            } else if major >= 4 {
                frameSize = synchsafe(d[i + 4], d[i + 5], d[i + 6], d[i + 7])
            } else {
                frameSize = Int(d[i + 4]) << 24 | Int(d[i + 5]) << 16
                          | Int(d[i + 6]) << 8  | Int(d[i + 7])
            }
            i += headerLength
            guard frameSize > 0, i + frameSize <= d.count else { break }

            if id == "APIC" || id == "PIC" {
                let frame = Array(d[i..<(i + frameSize)])
                if let (picture, isFrontCover) = parsePicture(frame, isV22: major == 2) {
                    if isFrontCover { return picture }                // best match, stop
                    if best == nil { best = picture }                 // keep as a fallback
                }
            }
            i += frameSize
        }
        return best
    }

    /// Returns the image bytes and whether the frame is tagged as a front cover.
    private static func parsePicture(_ frame: [UInt8], isV22: Bool) -> (Data, Bool)? {
        guard frame.count > 4 else { return nil }
        let encoding = frame[0]
        var p = 1

        if isV22 {
            p += 3                                                    // 3-byte image format
        } else {
            while p < frame.count, frame[p] != 0 { p += 1 }           // MIME type
            p += 1
        }
        guard p < frame.count else { return nil }

        let pictureType = frame[p]
        p += 1

        // Description, terminated by one or two NULs depending on the encoding.
        if encoding == 1 || encoding == 2 {
            while p + 1 < frame.count, !(frame[p] == 0 && frame[p + 1] == 0) { p += 2 }
            p += 2
        } else {
            while p < frame.count, frame[p] != 0 { p += 1 }
            p += 1
        }
        guard p < frame.count else { return nil }
        return (Data(frame[p...]), pictureType == 3)
    }

    private static func synchsafe(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Int {
        Int(a & 0x7F) << 21 | Int(b & 0x7F) << 14 | Int(c & 0x7F) << 7 | Int(d & 0x7F)
    }
}
