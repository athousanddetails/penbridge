import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct WriteOptions {
    var schema: EngineSchema = .recommended
    var includeBeatgrids = true
    var includeCues = true
    var includeWaveforms = true
    var playlistPrefix = ""      // optional prefix so Engine playlists are identifiable
}

struct WriteProgress {
    var stage: String
    var fraction: Double
}

struct WriteResult {
    var tracksWritten: Int
    var playlistsWritten: Int
    var entriesWritten: Int
    var beatgrids: Int
    var cues: Int
    var loops: Int
    var waveforms: Int
    var missingAudio: [String]
    var databaseBytes: Int64
}

/// Creates an `Engine Library` next to an existing rekordbox export, reusing the
/// audio that is already on the drive.
///
/// Safety model:
///  * the database is assembled in a temporary directory on the internal disk;
///  * only after it is complete and verified is it moved onto the drive;
///  * every path this type writes is checked to sit inside `<volume>/Engine Library`.
/// Nothing under `/PIONEER` or `/Contents` is ever opened for writing.
final class EngineWriter {

    enum WriterError: LocalizedError {
        case guardTripped(String)
        case sqlite(String)
        case engineLibraryExists

        var errorDescription: String? {
            switch self {
            case .guardTripped(let p): return "Refusing to write outside the Engine Library folder: \(p)"
            case .sqlite(let m): return "Database error: \(m)"
            case .engineLibraryExists: return "An 'Engine Library' folder already exists on this drive. Remove it first."
            }
        }
    }

    private let volume: URL
    private let options: WriteOptions
    private let uuid = UUID().uuidString.lowercased()

    init(volume: URL, options: WriteOptions) {
        self.volume = volume.standardizedFileURL
        self.options = options
    }

    var engineLibraryURL: URL { volume.appendingPathComponent("Engine Library") }

    /// The one and only gate through which a destination path must pass.
    private func assertInsideEngineLibrary(_ url: URL) throws {
        let root = engineLibraryURL.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        guard target == root || target.hasPrefix(root + "/") else {
            throw WriterError.guardTripped(target)
        }
    }

    // MARK: - main entry point

    func build(contents: PDBContents,
               progress: @escaping (WriteProgress) -> Void) throws -> WriteResult {

        if FileManager.default.fileExists(atPath: engineLibraryURL.path) {
            throw WriterError.engineLibraryExists
        }

        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PenBridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let dbURL = staging.appendingPathComponent("m.db")
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
            throw WriterError.sqlite("could not create the staging database")
        }
        defer { sqlite3_close(db) }

        try exec(db, "PRAGMA journal_mode=DELETE;")
        try exec(db, "PRAGMA foreign_keys=OFF;")
        try exec(db, options.schema.ddl)

        let v = options.schema.version
        try exec(db, """
            INSERT INTO Information (id, uuid, schemaVersionMajor, schemaVersionMinor,
                                     schemaVersionPatch, currentPlayedIndiciator,
                                     lastRekordBoxLibraryImportReadCounter)
            VALUES (1, '\(uuid)', \(v.major), \(v.minor), \(v.patch), \(Int64.random(in: Int64.min...Int64.max)), NULL);
            """)

        var result = WriteResult(tracksWritten: 0, playlistsWritten: 0, entriesWritten: 0,
                                 beatgrids: 0, cues: 0, loops: 0, waveforms: 0,
                                 missingAudio: [], databaseBytes: 0)

        try exec(db, "BEGIN;")
        let trackIDMap = try insertTracks(db, contents: contents, result: &result, progress: progress)
        try insertPlaylists(db, contents: contents, trackIDMap: trackIDMap, result: &result, progress: progress)
        try exec(db, "COMMIT;")
        // Deliberately no ANALYZE / PRAGMA optimize here: it would create an
        // sqlite_stat1 table, and Engine rejects a database whose set of schema
        // objects does not match what it expects.

        // Verify the staged database before it goes anywhere near the drive.
        progress(WriteProgress(stage: "Verifying database", fraction: 0.95))
        try verify(db)
        sqlite3_close(db)

        result.databaseBytes = (try? FileManager.default
            .attributesOfItem(atPath: dbURL.path)[.size] as? Int64) ?? 0

        // Move into place, guarded.
        progress(WriteProgress(stage: "Copying to drive", fraction: 0.97))
        let db2 = engineLibraryURL.appendingPathComponent("Database2")
        try assertInsideEngineLibrary(engineLibraryURL)
        try assertInsideEngineLibrary(db2)
        let dest = db2.appendingPathComponent("m.db")
        try assertInsideEngineLibrary(dest)

        try FileManager.default.createDirectory(at: db2, withIntermediateDirectories: true)
        // Write the bytes rather than copyItem: copying carries extended attributes
        // across, which makes macOS litter AppleDouble "._" files on a FAT32 drive.
        let bytes = try Data(contentsOf: dbURL)
        try bytes.write(to: dest, options: .atomic)

        progress(WriteProgress(stage: "Done", fraction: 1.0))
        return result
    }

    /// Deletes only the Engine Library folder. Nothing else is touched.
    func removeEngineLibrary() throws {
        try assertInsideEngineLibrary(engineLibraryURL)
        if FileManager.default.fileExists(atPath: engineLibraryURL.path) {
            try FileManager.default.removeItem(at: engineLibraryURL)
        }
    }

    // MARK: - tracks

    private func insertTracks(_ db: OpaquePointer, contents: PDBContents,
                              result: inout WriteResult,
                              progress: @escaping (WriteProgress) -> Void) throws -> [UInt32: Int64] {

        // Schema 2.x keeps the performance blobs as columns on Track (PerformanceData
        // is a view over it). Schema 3.x moved them into a real PerformanceData table,
        // whose row is created automatically by an AFTER INSERT trigger on Track — so
        // there we insert the track first and then update its performance row.
        let isV3 = options.schema.isV3

        let commonColumns = """
            playOrder, length, bpm, year, path, filename, bitrate,
            bpmAnalyzed, albumArtId, fileBytes, title, artist, album, genre, comment,
            label, composer, remixer, key, rating, albumArt, timeLastPlayed, isPlayed,
            fileType, isAnalyzed, dateCreated, dateAdded, isAvailable,
            isMetadataOfPackedTrackChanged, isPerfomanceDataOfPackedTrackChanged,
            playedIndicator, isMetadataImported, pdbImportKey, streamingSource, uri,
            isBeatGridLocked, originDatabaseUuid, originTrackId, streamingFlags,
            explicitLyrics
            """
        let commonValues = """
            ?,?,?,?,?,?,?,?,1,?,?,?,?,?,?,?,?,?,?,?,NULL,NULL,0,?,?,?,?,1,
            0,0,0,1,?,NULL,NULL,0,NULL,NULL,0,0
            """
        let sql = isV3
            ? "INSERT INTO Track (\(commonColumns)) VALUES (\(commonValues))"
            : """
              INSERT INTO Track (\(commonColumns), trackData, overviewWaveFormData,
                  beatData, quickCues, loops, thirdPartySourceId, activeOnLoadLoops)
              VALUES (\(commonValues),?,?,?,?,?,NULL,0)
              """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw WriterError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var perfStmt: OpaquePointer?
        if isV3 {
            let perfSQL = """
                UPDATE PerformanceData SET trackData = ?, overviewWaveFormData = ?,
                    beatData = ?, quickCues = ?, loops = ? WHERE trackId = ?
                """
            guard sqlite3_prepare_v2(db, perfSQL, -1, &perfStmt, nil) == SQLITE_OK else {
                throw WriterError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
        }
        defer { if let perfStmt { sqlite3_finalize(perfStmt) } }

        var map: [UInt32: Int64] = [:]
        let fm = FileManager.default
        let total = max(1, contents.tracks.count)

        for (i, t) in contents.tracks.enumerated() {
            if i % 64 == 0 {
                progress(WriteProgress(stage: "Writing tracks (\(i)/\(total))",
                                       fraction: 0.05 + 0.8 * Double(i) / Double(total)))
            }

            // "/Contents/x/y.mp3" on the drive is "../Contents/x/y.mp3" relative
            // to the Engine Library folder.
            let rbPath = t.filePath
            guard rbPath.hasPrefix("/") else { continue }
            let relative = ".." + rbPath
            let audioURL = volume.appendingPathComponent(String(rbPath.dropFirst()))
            if !fm.fileExists(atPath: audioURL.path) {
                result.missingAudio.append(rbPath)
                continue
            }

            let sampleRate = t.sampleRate > 0 ? Double(t.sampleRate) : 44100.0
            let seconds = Double(t.duration)
            let samples = Int64(seconds * sampleRate)
            let bpm = Double(t.tempo) / 100.0
            let keyName = contents.keys[t.keyID] ?? ""
            let engineKey = EngineBlobs.engineKey(from: keyName)

            let anlz = (options.includeBeatgrids || options.includeCues || options.includeWaveforms)
                && !t.analyzePath.isEmpty
                ? ANLZReader.read(datURL: volume.appendingPathComponent(String(t.analyzePath.dropFirst())))
                : ANLZData()

            var col = Int32(1)
            func bindInt(_ v: Int64?) {
                if let v { sqlite3_bind_int64(stmt, col, v) } else { sqlite3_bind_null(stmt, col) }
                col += 1
            }
            func bindDouble(_ v: Double?) {
                if let v { sqlite3_bind_double(stmt, col, v) } else { sqlite3_bind_null(stmt, col) }
                col += 1
            }
            func bindText(_ v: String?) {
                if let v, !v.isEmpty {
                    sqlite3_bind_text(stmt, col, v, -1, SQLITE_TRANSIENT)
                } else { sqlite3_bind_null(stmt, col) }
                col += 1
            }
            func bindBlob(_ v: Data?) {
                if let v, !v.isEmpty {
                    _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, col, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
                } else { sqlite3_bind_null(stmt, col) }
                col += 1
            }

            bindInt(Int64(t.trackNumber))                                   // playOrder
            bindInt(Int64(t.duration))                                      // length
            bindInt(Int64(bpm.rounded()))                                   // bpm
            bindInt(t.year > 0 ? Int64(t.year) : nil)                       // year
            bindText(relative)                                              // path
            bindText(t.fileName)                                            // filename
            bindInt(Int64(t.bitrate))                                       // bitrate
            bindDouble(bpm > 0 ? bpm : nil)                                 // bpmAnalyzed
            bindInt(Int64(t.fileSize))                                      // fileBytes
            bindText(t.title)
            bindText(contents.artists[t.artistID])
            bindText(contents.albums[t.albumID])
            bindText(contents.genres[t.genreID])
            bindText(t.comment)
            bindText(contents.labels[t.labelID])
            bindText(contents.artists[t.composerID])
            bindText(contents.artists[t.remixerID])
            bindInt(engineKey.map(Int64.init))                              // key
            bindInt(Int64(min(5, t.rating)) * 20)                           // rating 0...100
            bindText((t.fileName as NSString).pathExtension.lowercased())   // fileType
            bindInt(1)                                                      // isAnalyzed
            bindInt(unixTime(from: t.dateAdded))                            // dateCreated
            bindInt(unixTime(from: t.dateAdded))                            // dateAdded
            bindInt(Int64(t.id))                                            // pdbImportKey

            // Performance blobs, computed once and then written to whichever place
            // this schema keeps them.
            let trackDataBlob = EngineBlobs.trackData(sampleRate: sampleRate,
                                                      samples: samples, key: engineKey ?? 0)

            var waveformBlob: Data?
            if options.includeWaveforms,
               let wf = EngineBlobs.overviewWaveform(preview: anlz.previewWaveform, samples: samples) {
                waveformBlob = wf
                result.waveforms += 1
            }

            var beatBlob: Data?
            if options.includeBeatgrids, !anlz.beats.isEmpty {
                let markers = beatMarkers(from: anlz.beats, sampleRate: sampleRate)
                if !markers.isEmpty {
                    beatBlob = EngineBlobs.beatData(sampleRate: sampleRate,
                                                    samples: Double(samples), markers: markers)
                    result.beatgrids += 1
                }
            }

            let quickBlob: Data, loopBlob: Data
            if options.includeCues {
                let (quick, loops, mainCue, nCues, nLoops) =
                    convertCues(anlz.cues, sampleRate: sampleRate)
                quickBlob = EngineBlobs.quickCues(quick, mainCue: mainCue)
                loopBlob = EngineBlobs.loops(loops)
                result.cues += nCues
                result.loops += nLoops
            } else {
                quickBlob = EngineBlobs.quickCues([], mainCue: 0)
                loopBlob = EngineBlobs.loops([])
            }

            if !isV3 {
                bindBlob(trackDataBlob)
                bindBlob(waveformBlob)
                bindBlob(beatBlob)
                bindBlob(quickBlob)
                bindBlob(loopBlob)
            }

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw WriterError.sqlite("inserting '\(t.title)': \(String(cString: sqlite3_errmsg(db)))")
            }
            let trackRowID = sqlite3_last_insert_rowid(db)
            map[t.id] = trackRowID
            result.tracksWritten += 1
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)

            if isV3, let perfStmt {
                func bindPerf(_ i: Int32, _ v: Data?) {
                    if let v, !v.isEmpty {
                        _ = v.withUnsafeBytes {
                            sqlite3_bind_blob(perfStmt, i, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT)
                        }
                    } else { sqlite3_bind_null(perfStmt, i) }
                }
                bindPerf(1, trackDataBlob)
                bindPerf(2, waveformBlob)
                bindPerf(3, beatBlob)
                bindPerf(4, quickBlob)
                bindPerf(5, loopBlob)
                sqlite3_bind_int64(perfStmt, 6, trackRowID)
                guard sqlite3_step(perfStmt) == SQLITE_DONE else {
                    throw WriterError.sqlite("writing performance data for '\(t.title)': "
                                             + String(cString: sqlite3_errmsg(db)))
                }
                sqlite3_reset(perfStmt)
                sqlite3_clear_bindings(perfStmt)
            }
        }
        return map
    }

    /// Converts rekordbox's per-beat list into Engine's sparse marker list.
    /// Bars are aligned by starting at rekordbox's first downbeat, and an extra
    /// marker is emitted wherever the tempo changes.
    private func beatMarkers(from beats: [ANLZBeat], sampleRate: Double) -> [EngineBlobs.BeatMarker] {
        guard let firstDownbeat = beats.firstIndex(where: { $0.beatNumber == 1 }) else { return [] }
        let usable = Array(beats[firstDownbeat...])
        guard usable.count >= 2 else { return [] }

        var indices: [Int] = [0]
        for i in 1..<usable.count where abs(usable[i].bpm - usable[i - 1].bpm) > 0.005 {
            indices.append(i)
        }
        indices.append(usable.count - 1)
        indices = Array(Set(indices)).sorted()

        var markers: [EngineBlobs.BeatMarker] = []
        for (n, idx) in indices.enumerated() {
            let next = n + 1 < indices.count ? indices[n + 1] : idx
            markers.append(EngineBlobs.BeatMarker(
                sampleOffset: Double(usable[idx].timeMS) / 1000.0 * sampleRate,
                beatNumber: Int64(idx),
                numberOfBeats: Int32(next - idx)))
        }
        return markers
    }

    private func convertCues(_ cues: [ANLZCue], sampleRate: Double)
        -> ([EngineBlobs.QuickCue], [EngineBlobs.Loop], Double, Int, Int) {

        var quick = [EngineBlobs.QuickCue](repeating: .empty, count: EngineBlobs.maxQuickCues)
        var loops = [EngineBlobs.Loop](repeating: .empty, count: EngineBlobs.maxLoops)
        var mainCue: Double = 0
        var nCues = 0, nLoops = 0

        for c in cues {
            let start = Double(c.timeMS) / 1000.0 * sampleRate
            if c.hotCue == 0 {
                // First memory cue becomes Engine's main cue.
                if mainCue == 0 { mainCue = start }
                continue
            }
            let slot = c.hotCue - 1
            guard slot >= 0, slot < EngineBlobs.maxQuickCues else { continue }
            let colour = c.color ?? (0xFF, 0xFF, 0xFF, 0xFF)

            if c.isLoop, c.loopTimeMS > c.timeMS {
                loops[slot] = EngineBlobs.Loop(
                    label: c.comment,
                    startSampleOffset: start,
                    endSampleOffset: Double(c.loopTimeMS) / 1000.0 * sampleRate,
                    color: colour)
                nLoops += 1
            } else {
                quick[slot] = EngineBlobs.QuickCue(label: c.comment,
                                                   sampleOffset: start, color: colour)
                nCues += 1
            }
        }
        return (quick, loops, mainCue, nCues, nLoops)
    }

    private func unixTime(from rbDate: String) -> Int64? {
        guard !rbDate.isEmpty else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        guard let d = f.date(from: rbDate) else { return nil }
        return Int64(d.timeIntervalSince1970)
    }

    // MARK: - playlists

    private func insertPlaylists(_ db: OpaquePointer, contents: PDBContents,
                                 trackIDMap: [UInt32: Int64],
                                 result: inout WriteResult,
                                 progress: @escaping (WriteProgress) -> Void) throws {

        progress(WriteProgress(stage: "Writing playlists", fraction: 0.88))

        // Insert parents before children so parentListId always resolves.
        var byParent: [UInt32: [PDBPlaylistNode]] = [:]
        for n in contents.playlistNodes { byParent[n.parentID, default: []].append(n) }
        for k in byParent.keys { byParent[k]?.sort { $0.sortOrder < $1.sortOrder } }

        var idMap: [UInt32: Int64] = [:]        // rekordbox playlist id -> Engine playlist id
        var usedTitles: Set<String> = []

        func insertLevel(parentRB: UInt32, parentEngine: Int64) throws {
            for node in byParent[parentRB] ?? [] {
                var title = node.name.isEmpty ? "Untitled" : node.name
                if parentEngine == 0, !options.playlistPrefix.isEmpty {
                    title = options.playlistPrefix + title
                }
                // Engine enforces UNIQUE(title, parentListId).
                var candidate = title, n = 2
                while usedTitles.contains("\(parentEngine)/\(candidate)") {
                    candidate = "\(title) (\(n))"; n += 1
                }
                usedTitles.insert("\(parentEngine)/\(candidate)")

                // nextListId = 0 appends to the end of the sibling chain; the
                // schema's insert triggers repair the linked list for us.
                let sql = """
                    INSERT INTO Playlist (title, parentListId, isPersisted, nextListId,
                                          lastEditTime, isExplicitlyExported)
                    VALUES (?, ?, 1, 0, strftime('%s'), 1)
                    """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    throw WriterError.sqlite(String(cString: sqlite3_errmsg(db)))
                }
                sqlite3_bind_text(stmt, 1, candidate, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 2, parentEngine)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    let m = String(cString: sqlite3_errmsg(db))
                    sqlite3_finalize(stmt)
                    throw WriterError.sqlite("creating playlist '\(candidate)': \(m)")
                }
                sqlite3_finalize(stmt)

                let engineID = sqlite3_last_insert_rowid(db)
                idMap[node.id] = engineID
                result.playlistsWritten += 1

                try insertEntries(db, playlistRB: node.id, playlistEngine: engineID,
                                  contents: contents, trackIDMap: trackIDMap, result: &result)
                try insertLevel(parentRB: node.id, parentEngine: engineID)
            }
        }
        try insertLevel(parentRB: 0, parentEngine: 0)
    }

    private func insertEntries(_ db: OpaquePointer, playlistRB: UInt32, playlistEngine: Int64,
                               contents: PDBContents, trackIDMap: [UInt32: Int64],
                               result: inout WriteResult) throws {
        guard let entries = contents.playlistEntries[playlistRB], !entries.isEmpty else { return }

        var inserted: [Int64] = []
        var seen = Set<Int64>()
        let sql = """
            INSERT INTO PlaylistEntity (listId, trackId, databaseUuid, nextEntityId, membershipReference)
            VALUES (?, ?, ?, 0, 0)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw WriterError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        for rbTrackID in entries {
            guard let engineTrackID = trackIDMap[rbTrackID] else { continue }
            // Engine enforces UNIQUE(listId, databaseUuid, trackId).
            guard seen.insert(engineTrackID).inserted else { continue }

            sqlite3_bind_int64(stmt, 1, playlistEngine)
            sqlite3_bind_int64(stmt, 2, engineTrackID)
            sqlite3_bind_text(stmt, 3, uuid, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw WriterError.sqlite("adding track to playlist: \(String(cString: sqlite3_errmsg(db)))")
            }
            inserted.append(sqlite3_last_insert_rowid(db))
            result.entriesWritten += 1
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }

        // Chain the entity linked list: each row points at the next, last points at 0.
        guard inserted.count > 1 else { return }
        var upd: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE PlaylistEntity SET nextEntityId = ? WHERE id = ?",
                                 -1, &upd, nil) == SQLITE_OK, let upd else {
            throw WriterError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(upd) }
        for i in 0..<(inserted.count - 1) {
            sqlite3_bind_int64(upd, 1, inserted[i + 1])
            sqlite3_bind_int64(upd, 2, inserted[i])
            guard sqlite3_step(upd) == SQLITE_DONE else {
                throw WriterError.sqlite("linking playlist entries: \(String(cString: sqlite3_errmsg(db)))")
            }
            sqlite3_reset(upd)
        }
    }

    // MARK: - helpers

    private func verify(_ db: OpaquePointer) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check;", -1, &stmt, nil) == SQLITE_OK else {
            throw WriterError.sqlite("integrity check could not run")
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW,
           let c = sqlite3_column_text(stmt, 0) {
            let s = String(cString: c)
            guard s == "ok" else { throw WriterError.sqlite("integrity check failed: \(s)") }
        }
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let m = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw WriterError.sqlite(m)
        }
    }
}
