import Foundation

/// Command-line mode, used for verification runs without launching the UI:
///
///     PenBridge --headless <volume> [--schema 2|3] [--dry-run]
///
/// It performs exactly the same work as the Build button, so whatever is proven
/// here is what the GUI does.
enum Headless {

    static func runIfRequested() {
        let args = CommandLine.arguments

        // `--watch` exercises the same auto-detection the GUI uses, so drive
        // detection can be verified without a window.
        if args.contains("--watch") {
            setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered so output survives redirection
            MainActor.assumeIsolated {
                let model = AppModel()
                var previous = ""
                model.startWatchingVolumes()
                let printer = Timer(timeInterval: 0.5, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        let now = model.drives
                            .map { "\($0.name) [\($0.hasRekordbox ? "rekordbox" : "-")]" }
                            .joined(separator: ", ")
                        if now != previous {
                            previous = now
                            print("drives: \(now.isEmpty ? "(none)" : now)")
                        }
                    }
                }
                RunLoop.main.add(printer, forMode: .common)
            }
            RunLoop.main.run()
            exit(0)
        }

        guard let i = args.firstIndex(of: "--headless") else { return }
        guard i + 1 < args.count else {
            FileHandle.standardError.write(Data("usage: PenBridge --headless <volume>\n".utf8))
            exit(2)
        }
        let volume = URL(fileURLWithPath: args[i + 1])
        var opts = WriteOptions()
        if let s = args.firstIndex(of: "--schema"), s + 1 < args.count {
            switch args[s + 1] {
            case "2", "2.21", "2.21.0": opts.schema = .v2_21_0
            case "3.0.1":               opts.schema = .v3_0_1
            default:                    opts.schema = .v3_0_2
            }
        }
        let dryRun = args.contains("--dry-run")

        do {
            let pdbURL = volume.appendingPathComponent("PIONEER/rekordbox/export.pdb")
            print("Reading \(pdbURL.path)")
            let contents = try PDBReader(url: pdbURL).read()
            print("  tracks:          \(contents.tracks.count)")
            print("  playlist nodes:  \(contents.playlistNodes.count)")
            print("  playlist entries:\(contents.playlistEntries.values.reduce(0) { $0 + $1.count })")
            print("  artists/albums:  \(contents.artists.count)/\(contents.albums.count)")

            // Key labels come in classical, Camelot and Open Key spellings, often
            // mixed in one library, so report how many actually resolve.
            var named = 0, mapped = 0
            var unmapped = Set<String>()
            for t in contents.tracks {
                guard let name = contents.keys[t.keyID], !name.isEmpty else { continue }
                named += 1
                if EngineBlobs.engineKey(from: name) != nil { mapped += 1 } else { unmapped.insert(name) }
            }
            print("  keys recognised: \(mapped)/\(named)"
                  + (unmapped.isEmpty ? "" : "  unrecognised: \(unmapped.sorted().joined(separator: ", "))"))

            if dryRun {
                print("dry run — nothing written")
                exit(0)
            }

            let writer = EngineWriter(volume: volume, options: opts)
            let result = try writer.build(contents: contents) { p in
                if p.fraction >= 0.99 || Int(p.fraction * 100) % 10 == 0 {
                    print("  [\(Int(p.fraction * 100))%] \(p.stage)")
                }
            }
            print("""
                Wrote Engine Library:
                  tracks     \(result.tracksWritten)
                  playlists  \(result.playlistsWritten)
                  entries    \(result.entriesWritten)
                  beatgrids  \(result.beatgrids)
                  cues/loops \(result.cues)/\(result.loops)
                  waveforms  \(result.waveforms)
                  album art  \(result.albumArt)
                  db size    \(result.databaseBytes) bytes
                  missing    \(result.missingAudio.count)
                """)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
