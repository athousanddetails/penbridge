import SwiftUI

/// Read-only browser over the rekordbox database that is already on the pen:
/// the playlist tree on the left, the tracks of the selection on the right.
struct LibraryBrowser: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedPlaylist: UInt32?
    @State private var search = ""

    private var tracks: [PDBTrack] {
        let base = model.tracks(inPlaylist: selectedPlaylist)
        guard !search.isEmpty else { return base }
        let q = search.lowercased()
        return base.filter {
            $0.title.lowercased().contains(q)
            || model.displayArtist($0).lowercased().contains(q)
            || model.displayAlbum($0).lowercased().contains(q)
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedPlaylist) {
                    Label("All tracks (\(model.contents?.tracks.count ?? 0))",
                          systemImage: "music.note.list")
                        .tag(UInt32.max)
                    Section("Playlists") {
                        OutlineGroup(model.playlistRows, children: \.children) { row in
                            HStack(spacing: 6) {
                                Image(systemName: row.isFolder ? "folder" : "music.note.list")
                                    .foregroundStyle(row.isFolder ? Color.secondary : Color.blue)
                                Text(row.name).lineLimit(1)
                                Spacer()
                                if !row.isFolder {
                                    Text("\(row.trackCount)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .tag(row.id)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 200, idealWidth: 240)

            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter by title, artist or album", text: $search)
                        .textFieldStyle(.plain)
                    Text("\(tracks.count) tracks").font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
                Divider()

                Table(tracks) {
                    TableColumn("Title") { t in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.title.isEmpty ? t.fileName : t.title)
                                .font(.system(size: 13))
                                .lineLimit(1)
                            Text(t.filePath)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.vertical, 1)
                    }
                    .width(min: 300, ideal: 440)

                    TableColumn("Artist") { t in
                        Text(model.displayArtist(t)).font(.system(size: 13)).lineLimit(1)
                    }
                    .width(min: 140, ideal: 210)

                    TableColumn("Album") { t in
                        Text(model.displayAlbum(t)).font(.system(size: 13)).lineLimit(1)
                    }
                    .width(min: 140, ideal: 230)

                    TableColumn("Genre") { t in
                        Text(model.displayGenre(t)).font(.system(size: 13)).lineLimit(1)
                    }
                    .width(min: 90, ideal: 140)

                    TableColumn("BPM") { t in
                        Text(t.tempo > 0 ? String(format: "%.2f", Double(t.tempo) / 100) : "—")
                            .font(.system(size: 13))
                    }
                    .width(66)

                    TableColumn("Key") { t in
                        Text(model.displayKey(t)).font(.system(size: 13))
                    }
                    .width(54)

                    TableColumn("Time") { t in
                        Text(String(format: "%d:%02d", t.duration / 60, t.duration % 60))
                            .font(.system(size: 13))
                    }
                    .width(56)
                }
            }
            .frame(minWidth: 480)
        }
    }
}

struct BuildPane: View {
    @EnvironmentObject var model: AppModel
    @State private var confirming = false

    private var engineExists: Bool { model.selected?.hasEngine ?? false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                GroupBox {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(.green).font(.title2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your rekordbox pen is not modified").bold()
                            Text("""
                                 Only a new folder called “Engine Library” is added. \
                                 The database is assembled on your Mac first and copied over \
                                 only once it is complete and verified. Nothing inside PIONEER \
                                 or Contents is ever opened for writing, and no audio is copied \
                                 — Engine is pointed at the files already on the pen.
                                 """)
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(6)
                }

                GroupBox("Options") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Engine schema", selection: $model.options.schema) {
                            ForEach(EngineSchema.allCases) { s in Text(s.label).tag(s) }
                        }
                        Text("""
                             Pick 2.21.0 unless you know the player runs Engine OS 4.3 or newer. \
                             Older Engine OS cannot read a 3.0.1 database; Engine OS 4.x and 5.x \
                             read both.
                             """)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        Toggle("Beatgrids", isOn: $model.options.includeBeatgrids)
                        Toggle("Hot cues, loops and memory cues", isOn: $model.options.includeCues)
                        Toggle("Overview waveforms", isOn: $model.options.includeWaveforms)

                        HStack {
                            Text("Playlist name prefix")
                            TextField("none", text: $model.options.playlistPrefix)
                                .frame(width: 160)
                        }
                        .font(.callout)
                    }.padding(6)
                }

                if let r = model.lastResult {
                    GroupBox("Result") {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                            GridRow { Text("Tracks").foregroundStyle(.secondary); Text("\(r.tracksWritten)") }
                            GridRow { Text("Playlists").foregroundStyle(.secondary); Text("\(r.playlistsWritten)") }
                            GridRow { Text("Playlist entries").foregroundStyle(.secondary); Text("\(r.entriesWritten)") }
                            GridRow { Text("Beatgrids").foregroundStyle(.secondary); Text("\(r.beatgrids)") }
                            GridRow { Text("Hot cues / loops").foregroundStyle(.secondary); Text("\(r.cues) / \(r.loops)") }
                            GridRow { Text("Waveforms").foregroundStyle(.secondary); Text("\(r.waveforms)") }
                            GridRow { Text("Database size").foregroundStyle(.secondary); Text(formatBytes(r.databaseBytes)) }
                            GridRow { Text("Audio copied").foregroundStyle(.secondary)
                                      Text("none — existing files referenced").foregroundStyle(.green) }
                        }.padding(6)
                    }
                }

                if let e = model.errorMessage {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }

                if model.isBuilding {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: model.buildFraction)
                        Text(model.buildStage).font(.caption).foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        confirming = true
                    } label: {
                        Label("Build Engine Library", systemImage: "hammer.fill")
                            .frame(minWidth: 180)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBuilding || model.contents == nil || engineExists)

                    if engineExists {
                        Button(role: .destructive) {
                            model.removeEngineLibrary()
                        } label: {
                            Label("Remove Engine Library", systemImage: "trash")
                        }
                        .help("Deletes only the Engine Library folder, returning the pen to rekordbox-only.")
                    }
                }

                if engineExists {
                    Text("This drive already has an Engine Library. Remove it first to rebuild.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Add an Engine Library to “\(model.selected?.name ?? "")”?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Build Engine Library") { model.build() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("A new “Engine Library” folder will be created. Existing rekordbox data is left untouched and no audio is duplicated.")
        }
    }
}
