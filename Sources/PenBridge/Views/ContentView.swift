import SwiftUI

@main
struct PenBridgeApp: App {
    @StateObject private var model = AppModel()

    init() { Headless.runIfRequested() }

    var body: some Scene {
        WindowGroup("PenBridge") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1200, minHeight: 700)
                .onAppear { model.refreshDrives() }
        }
        .defaultSize(width: 1640, height: 950)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = 0

    var body: some View {
        NavigationSplitView {
            DriveList()
                .navigationSplitViewColumnWidth(min: 150, ideal: 168, max: 220)
        } detail: {
            if model.selected == nil {
                ContentUnavailableView("Select a drive",
                                       systemImage: "externaldrive",
                                       description: Text("Plug in your USB pen and pick it on the left."))
            } else {
                VStack(spacing: 0) {
                    Picker("", selection: $tab) {
                        Text("Overview").tag(0)
                        Text("Library").tag(1)
                        Text("Build Engine Library").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(12)

                    Divider()

                    switch tab {
                    case 0: OverviewPane()
                    case 1: LibraryBrowser()
                    default: BuildPane()
                    }
                }
            }
        }
        .alert("Eject failed",
               isPresented: Binding(get: { model.ejectError != nil },
                                    set: { if !$0 { model.ejectError = nil } })) {
            Button("OK", role: .cancel) { model.ejectError = nil }
        } message: {
            Text(model.ejectError ?? "")
        }
    }
}

struct DriveList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: Binding(
            get: { model.selected?.id },
            set: { id in
                if let d = model.drives.first(where: { $0.id == id }) { model.scan(d) }
            })) {
            Section("Drives") {
                ForEach(model.drives) { d in
                    HStack(spacing: 8) {
                        Image(systemName: d.isRemovable ? "externaldrive.fill" : "externaldrive")
                            .foregroundStyle(d.hasRekordbox ? Color.blue : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.name).fontWeight(.medium).lineLimit(1)
                            Text(d.format).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            HStack(spacing: 4) {
                                if d.hasRekordbox { Tag("rekordbox", .blue) }
                                if d.hasEngine { Tag("Engine", .green) }
                            }
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(d.id)
                    .contextMenu {
                        Button("Eject \(d.name)") { model.eject(d) }
                            .disabled(model.isBuilding)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button { model.refreshDrives() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan drives")
            }
            ToolbarItem {
                Button {
                    if let d = model.selected { model.eject(d) }
                } label: {
                    Image(systemName: "eject.fill")
                }
                .help(model.selected.map { "Eject \($0.name)" } ?? "Eject the selected drive")
                .disabled(model.selected == nil || model.isBuilding)
            }
        }
    }
}

struct Tag: View {
    let text: String
    let color: Color
    init(_ t: String, _ c: Color) { text = t; color = c }
    var body: some View {
        Text(text)
            .font(.caption2).bold()
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct OverviewPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let d = model.selected {
                    GroupBox("Drive") {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                            row("Name", d.name)
                            row("Filesystem", d.format,
                                ok: d.formatIsCompatible,
                                note: d.formatIsCompatible ? "Readable by Denon and Pioneer"
                                                           : "NTFS is not readable by Denon or Pioneer")
                            row("Capacity", "\(formatBytes(d.totalBytes)) — \(formatBytes(d.freeBytes)) free")
                            row("rekordbox export", d.hasRekordbox ? "Present" : "Not found", ok: d.hasRekordbox)
                            row("Engine Library", d.hasEngine ? "Present" : "Not present", ok: true)
                        }
                        .padding(6)
                    }
                }

                switch model.scanState {
                case .scanning(let s):
                    HStack { ProgressView().controlSize(.small); Text(s) }
                case .failed(let e):
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                case .loaded:
                    if let c = model.contents {
                        GroupBox("rekordbox library") {
                            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                                row("Tracks in database", "\(c.tracks.count)")
                                row("Audio files found", "\(model.audioPresent) of \(c.tracks.count)",
                                    ok: model.audioMissing.isEmpty,
                                    note: model.audioMissing.isEmpty ? "every track resolves on disk"
                                                                     : "\(model.audioMissing.count) missing")
                                row("Analysis files found", "\(model.analysisPresent) of \(c.tracks.count)",
                                    ok: model.analysisPresent > 0,
                                    note: "beatgrids, cues and waveforms")
                                row("Playlists", "\(c.playlistNodes.filter { !$0.isFolder }.count) "
                                    + "(+\(c.playlistNodes.filter(\.isFolder).count) folders)")
                                row("Playlist entries", "\(c.playlistEntries.values.reduce(0) { $0 + $1.count })")
                                row("Artists / Albums", "\(c.artists.count) / \(c.albums.count)")
                            }
                            .padding(6)
                        }

                        if !model.audioMissing.isEmpty {
                            GroupBox("Tracks whose audio is missing") {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(model.audioMissing.prefix(20), id: \.self) { p in
                                        Text(p).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if model.audioMissing.count > 20 {
                                        Text("+ \(model.audioMissing.count - 20) more").font(.caption)
                                    }
                                }.padding(6)
                            }
                        }
                    }
                case .idle:
                    EmptyView()
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, ok: Bool? = nil, note: String? = nil) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if let ok {
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ok ? .green : .orange)
                }
                Text(value)
                if let note {
                    Text("— \(note)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
