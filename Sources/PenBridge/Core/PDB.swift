import Foundation

/// Read-only parser for Pioneer rekordbox `export.pdb` (DeviceSQL) files.
/// Implemented from the crate-digger Kaitai spec (Deep Symmetry, rekordbox_pdb.ksy).
///
/// This type never opens a file for writing. It is the only code in the app that
/// touches anything inside `/PIONEER`.
enum PDBTable: UInt32 {
    case tracks = 0, genres = 1, artists = 2, albums = 3, labels = 4
    case keys = 5, colors = 6, playlistTree = 7, playlistEntries = 8
    case artwork = 13
}

struct PDBTrack: Identifiable {
    var id: UInt32
    var title: String
    var filePath: String        // e.g. "/Contents/Artist/Album/track.mp3"
    var fileName: String
    var analyzePath: String     // e.g. "/PIONEER/USBANLZ/P01D/0000C7F1/ANLZ0000.DAT"
    var comment: String
    var dateAdded: String
    var releaseDate: String
    var mixName: String
    var artistID: UInt32
    var albumID: UInt32
    var genreID: UInt32
    var keyID: UInt32
    var labelID: UInt32
    var remixerID: UInt32
    var composerID: UInt32
    var artworkID: UInt32
    var tempo: UInt32           // BPM * 100
    var duration: UInt16        // seconds
    var bitrate: UInt32
    var sampleRate: UInt32
    var sampleDepth: UInt16
    var fileSize: UInt32
    var trackNumber: UInt32
    var discNumber: UInt16
    var year: UInt16
    var playCount: UInt16
    var rating: UInt8
    var colorID: UInt8
}

struct PDBPlaylistNode {
    var id: UInt32
    var parentID: UInt32
    var sortOrder: UInt32
    var isFolder: Bool
    var name: String
}

struct PDBContents {
    var tracks: [PDBTrack] = []
    var artists: [UInt32: String] = [:]
    var albums: [UInt32: String] = [:]
    var genres: [UInt32: String] = [:]
    var keys: [UInt32: String] = [:]
    var labels: [UInt32: String] = [:]
    var colors: [UInt32: String] = [:]
    var artwork: [UInt32: String] = [:]
    var playlistNodes: [PDBPlaylistNode] = []
    /// playlist id -> ordered track ids
    var playlistEntries: [UInt32: [UInt32]] = [:]
}

struct PDBError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class PDBReader {
    private let data: [UInt8]
    private let pageSize: Int
    private var tables: [UInt32: (first: UInt32, last: UInt32)] = [:]

    init(url: URL) throws {
        guard let d = FileManager.default.contents(atPath: url.path) else {
            throw PDBError(message: "Could not read \(url.lastPathComponent)")
        }
        guard d.count >= 0x1C else { throw PDBError(message: "export.pdb is truncated") }
        self.data = [UInt8](d)

        let ps = Int(PDBReader.u32(self.data, 0x04))
        guard ps > 0, ps % 512 == 0, self.data.count % ps == 0 else {
            throw PDBError(message: "export.pdb has an implausible page size (\(ps)) — file may be corrupt")
        }
        self.pageSize = ps

        let numTables = Int(PDBReader.u32(self.data, 0x08))
        guard numTables > 0, numTables < 64, 0x1C + numTables * 16 <= self.data.count else {
            throw PDBError(message: "export.pdb has an implausible table count (\(numTables))")
        }
        for i in 0..<numTables {
            let off = 0x1C + i * 16
            let type = PDBReader.u32(self.data, off)
            let first = PDBReader.u32(self.data, off + 8)
            let last = PDBReader.u32(self.data, off + 12)
            tables[type] = (first, last)
        }
    }

    // MARK: - primitive reads

    private static func u8(_ b: [UInt8], _ o: Int) -> UInt8 { o < b.count ? b[o] : 0 }
    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16 {
        guard o + 1 < b.count else { return 0 }
        return UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
    }
    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o + 3 < b.count else { return 0 }
        return UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    /// Decodes a `device_sql_string` at an absolute offset.
    private func string(at pos: Int) -> String {
        guard pos > 0, pos < data.count else { return "" }
        let kind = data[pos]
        if kind == 0x40 {                                    // long ASCII
            let len = Int(PDBReader.u16(data, pos + 1))
            guard len >= 4, pos + len <= data.count else { return "" }
            return decodeBytes(Array(data[(pos + 4)..<(pos + len)]), utf16: false)
        }
        if kind == 0x90 {                                    // long UTF-16LE
            let len = Int(PDBReader.u16(data, pos + 1))
            guard len >= 4, pos + len <= data.count else { return "" }
            return decodeBytes(Array(data[(pos + 4)..<(pos + len)]), utf16: true)
        }
        let len = Int(kind >> 1) - 1                         // short ASCII
        guard len > 0, pos + 1 + len <= data.count else { return "" }
        return decodeBytes(Array(data[(pos + 1)..<(pos + 1 + len)]), utf16: false)
    }

    private func decodeBytes(_ bytes: [UInt8], utf16: Bool) -> String {
        if utf16 {
            return String(decoding: bytes.chunkedUTF16LE(), as: UTF16.self)
        }
        // rekordbox occasionally stores UTF-8 or Latin-1 inside "ASCII" strings.
        if let s = String(bytes: bytes, encoding: .utf8) { return s }
        return String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    // MARK: - page walking

    /// Absolute offsets of every present row body in a table.
    private func rowOffsets(_ table: PDBTable) -> [Int] {
        guard let entry = tables[table.rawValue] else { return [] }
        var result: [Int] = []
        var index = entry.first
        var visited = Set<UInt32>()

        while true {
            if visited.contains(index) { break }
            visited.insert(index)
            let base = Int(index) * pageSize
            guard base >= 0, base + pageSize <= data.count else { break }

            let pageType = PDBReader.u32(data, base + 0x08)
            let nextPage = PDBReader.u32(data, base + 0x0C)
            let flags = PDBReader.u8(data, base + 0x1B)
            let smallRows = Int(PDBReader.u8(data, base + 0x18))
            let largeRows = Int(PDBReader.u16(data, base + 0x22))
            let numRows = (largeRows > smallRows && largeRows != 0x1FFF) ? largeRows : smallRows

            // A page with bit 0x40 set is not a data page; parsing it yields garbage.
            if pageType == table.rawValue, flags & 0x40 == 0, numRows > 0 {
                let heap = base + 0x28
                let groupCount = (numRows - 1) / 16 + 1
                var seen = 0
                outer: for g in 0..<groupCount {
                    let gbase = base + pageSize - (g * 0x24)
                    let flagsPos = gbase - 4
                    if flagsPos < heap { break }
                    let present = PDBReader.u16(data, flagsPos)
                    for i in 0..<16 {
                        if seen >= numRows { break outer }
                        let ofsPos = gbase - (6 + 2 * i)
                        if ofsPos < heap { break outer }
                        if (present >> UInt16(i)) & 1 == 0 { continue }
                        let ofs = Int(PDBReader.u16(data, ofsPos))
                        seen += 1
                        let rowBase = heap + ofs
                        if rowBase < base + pageSize { result.append(rowBase) }
                    }
                }
            }
            if index == entry.last { break }
            index = nextPage
        }
        return result
    }

    // MARK: - row decoding

    private static let trackStringCount = 21
    private static let idxComment = 16, idxTitle = 17, idxFilename = 19, idxFilePath = 20
    private static let idxDateAdded = 10, idxReleaseDate = 11, idxMixName = 12, idxAnalyzePath = 14

    func read() throws -> PDBContents {
        var c = PDBContents()

        for off in rowOffsets(.genres) {
            c.genres[PDBReader.u32(data, off)] = string(at: off + 4)
        }
        for off in rowOffsets(.labels) {
            c.labels[PDBReader.u32(data, off)] = string(at: off + 4)
        }
        for off in rowOffsets(.keys) {
            c.keys[PDBReader.u32(data, off)] = string(at: off + 8)
        }
        for off in rowOffsets(.colors) {
            c.colors[UInt32(PDBReader.u16(data, off + 5))] = string(at: off + 8)
        }
        for off in rowOffsets(.artwork) {
            c.artwork[PDBReader.u32(data, off)] = string(at: off + 4)
        }
        for off in rowOffsets(.artists) {
            let subtype = PDBReader.u16(data, off)
            let id = PDBReader.u32(data, off + 4)
            let nameOfs = (subtype & 0x04) != 0
                ? Int(PDBReader.u16(data, off + 0x0A))
                : Int(PDBReader.u8(data, off + 0x09))
            c.artists[id] = string(at: off + nameOfs)
        }
        for off in rowOffsets(.albums) {
            let subtype = PDBReader.u16(data, off)
            let id = PDBReader.u32(data, off + 0x0C)
            let nameOfs = (subtype & 0x04) != 0
                ? Int(PDBReader.u16(data, off + 0x16))
                : Int(PDBReader.u8(data, off + 0x15))
            c.albums[id] = string(at: off + nameOfs)
        }

        for off in rowOffsets(.tracks) {
            let stringsBase = off + 0x5E
            func str(_ index: Int) -> String {
                string(at: off + Int(PDBReader.u16(data, stringsBase + index * 2)))
            }
            let t = PDBTrack(
                id: PDBReader.u32(data, off + 0x48),
                title: str(Self.idxTitle),
                filePath: str(Self.idxFilePath),
                fileName: str(Self.idxFilename),
                analyzePath: str(Self.idxAnalyzePath),
                comment: str(Self.idxComment),
                dateAdded: str(Self.idxDateAdded),
                releaseDate: str(Self.idxReleaseDate),
                mixName: str(Self.idxMixName),
                artistID: PDBReader.u32(data, off + 0x44),
                albumID: PDBReader.u32(data, off + 0x40),
                genreID: PDBReader.u32(data, off + 0x3C),
                keyID: PDBReader.u32(data, off + 0x20),
                labelID: PDBReader.u32(data, off + 0x28),
                remixerID: PDBReader.u32(data, off + 0x2C),
                composerID: PDBReader.u32(data, off + 0x0C),
                artworkID: PDBReader.u32(data, off + 0x1C),
                tempo: PDBReader.u32(data, off + 0x38),
                duration: PDBReader.u16(data, off + 0x54),
                bitrate: PDBReader.u32(data, off + 0x30),
                sampleRate: PDBReader.u32(data, off + 0x08),
                sampleDepth: PDBReader.u16(data, off + 0x52),
                fileSize: PDBReader.u32(data, off + 0x10),
                trackNumber: PDBReader.u32(data, off + 0x34),
                discNumber: PDBReader.u16(data, off + 0x4C),
                year: PDBReader.u16(data, off + 0x50),
                playCount: PDBReader.u16(data, off + 0x4E),
                rating: PDBReader.u8(data, off + 0x59),
                colorID: PDBReader.u8(data, off + 0x58))
            if t.id != 0 { c.tracks.append(t) }
        }

        for off in rowOffsets(.playlistTree) {
            c.playlistNodes.append(PDBPlaylistNode(
                id: PDBReader.u32(data, off + 12),
                parentID: PDBReader.u32(data, off),
                sortOrder: PDBReader.u32(data, off + 8),
                isFolder: PDBReader.u32(data, off + 16) != 0,
                name: string(at: off + 20)))
        }

        var raw: [UInt32: [(UInt32, UInt32)]] = [:]
        for off in rowOffsets(.playlistEntries) {
            let entryIndex = PDBReader.u32(data, off)
            let trackID = PDBReader.u32(data, off + 4)
            let playlistID = PDBReader.u32(data, off + 8)
            raw[playlistID, default: []].append((entryIndex, trackID))
        }
        for (pid, entries) in raw {
            c.playlistEntries[pid] = entries.sorted { $0.0 < $1.0 }.map { $0.1 }
        }

        guard !c.tracks.isEmpty else {
            throw PDBError(message: "No tracks found in export.pdb — the database is empty or unreadable.")
        }
        return c
    }
}

private extension Array where Element == UInt8 {
    func chunkedUTF16LE() -> [UInt16] {
        stride(from: 0, to: count - (count % 2), by: 2).map {
            UInt16(self[$0]) | (UInt16(self[$0 + 1]) << 8)
        }
    }
}
