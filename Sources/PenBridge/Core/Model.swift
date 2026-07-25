import AppKit
import Foundation
import SwiftUI

extension PDBTrack: @unchecked Sendable {}
extension PDBPlaylistNode: @unchecked Sendable {}
extension PDBContents: @unchecked Sendable {}
extension WriteResult: @unchecked Sendable {}
extension WriteProgress: @unchecked Sendable {}
extension WriteOptions: @unchecked Sendable {}
extension EngineSchema: @unchecked Sendable {}

struct Drive: Identifiable, Hashable, Sendable {
    var url: URL
    var name: String
    var format: String
    var totalBytes: Int64
    var freeBytes: Int64
    var isRemovable: Bool

    var id: String { url.path }

    var hasRekordbox: Bool {
        FileManager.default.fileExists(
            atPath: url.appendingPathComponent("PIONEER/rekordbox/export.pdb").path)
    }
    var hasEngine: Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("Engine Library").path)
    }
    var formatIsCompatible: Bool {
        let f = format.lowercased()
        return f.contains("fat") || f.contains("exfat") || f.contains("hfs") || f.contains("ms-dos")
    }
}

/// A flattened playlist row for display in the browser.
struct PlaylistRow: Identifiable, Hashable {
    var id: UInt32
    var name: String
    var isFolder: Bool
    var depth: Int
    var trackCount: Int
    var children: [PlaylistRow]?
}

enum ScanState: Equatable {
    case idle
    case scanning(String)
    case loaded
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var drives: [Drive] = []
    @Published var selected: Drive?
    @Published var scanState: ScanState = .idle

    @Published var contents: PDBContents?
    @Published var playlistRows: [PlaylistRow] = []
    @Published var audioPresent = 0
    @Published var audioMissing: [String] = []
    @Published var analysisPresent = 0

    @Published var options = WriteOptions()
    @Published var isBuilding = false
    @Published var buildStage = ""
    @Published var buildFraction = 0.0
    @Published var lastResult: WriteResult?
    @Published var errorMessage: String?
    @Published var ejectError: String?

    // MARK: - drives

    private var volumeObservers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var lastVolumeSignature = ""

    /// Watches for drives being plugged in, pulled out or renamed, so the list is
    /// always live and the refresh button is only ever a manual override.
    ///
    /// NSWorkspace's mount notifications are not delivered reliably in every
    /// process context, so a cheap poll backs them up rather than trusting them
    /// as the only signal. Both paths funnel into the same refresh.
    func startWatchingVolumes() {
        guard volumeObservers.isEmpty else { return }

        let centre = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification,
                     NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            let token = centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkForVolumeChanges() }
            }
            volumeObservers.append(token)
        }

        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForVolumeChanges() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        lastVolumeSignature = Self.volumeSignature()
        refreshDrives(autoSelect: true)
    }

    private static func volumeSignature() -> String {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) ?? []
        return urls.map(\.path).sorted().joined(separator: "|")
    }

    /// Refreshes only when the set of mounted volumes actually changed, so the
    /// poll costs nothing and the UI never churns.
    private func checkForVolumeChanges() {
        let signature = Self.volumeSignature()
        guard signature != lastVolumeSignature else { return }
        lastVolumeSignature = signature
        refreshDrives(autoSelect: true)
    }

    func refreshDrives(autoSelect: Bool = false) {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey,
                                      .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                      .volumeLocalizedFormatDescriptionKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []

        var found: [Drive] = []
        for u in urls {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            let internalVolume = v.volumeIsInternal ?? false
            let removable = v.volumeIsRemovable ?? false
            // Show removable/external volumes only — the internal disk is never a target.
            guard removable || !internalVolume else { continue }
            found.append(Drive(url: u,
                               name: v.volumeName ?? u.lastPathComponent,
                               format: v.volumeLocalizedFormatDescription ?? "unknown",
                               totalBytes: Int64(v.volumeTotalCapacity ?? 0),
                               freeBytes: Int64(v.volumeAvailableCapacity ?? 0),
                               isRemovable: removable))
        }
        drives = found.sorted { $0.name < $1.name }

        // A drive that went away takes its scanned library with it.
        if let sel = selected, !drives.contains(where: { $0.id == sel.id }) {
            selected = nil
            contents = nil
            playlistRows = []
            audioMissing = []
            lastResult = nil
            scanState = .idle
        }

        // Nothing selected and a rekordbox pen just appeared? Open it.
        if autoSelect, selected == nil, !isBuilding,
           let pen = drives.first(where: { $0.hasRekordbox }) {
            scan(pen)
        }
    }

    // MARK: - scanning

    func scan(_ drive: Drive) {
        selected = drive
        contents = nil
        playlistRows = []
        lastResult = nil
        errorMessage = nil

        guard drive.hasRekordbox else {
            scanState = .failed("No rekordbox export found (expected PIONEER/rekordbox/export.pdb).")
            return
        }
        scanState = .scanning("Reading export.pdb…")

        let pdbURL = drive.url.appendingPathComponent("PIONEER/rekordbox/export.pdb")
        let root = drive.url

        Task.detached(priority: .userInitiated) {
            do {
                let reader = try PDBReader(url: pdbURL)
                let c = try reader.read()

                let fm = FileManager.default
                var present = 0
                var missing: [String] = []
                var analysis = 0
                for t in c.tracks {
                    let p = root.appendingPathComponent(String(t.filePath.dropFirst()))
                    if fm.fileExists(atPath: p.path) { present += 1 } else { missing.append(t.filePath) }
                    if !t.analyzePath.isEmpty,
                       fm.fileExists(atPath: root.appendingPathComponent(String(t.analyzePath.dropFirst())).path) {
                        analysis += 1
                    }
                }
                let rows = Self.buildPlaylistTree(c)
                let p = present, a = analysis, m = missing
                await MainActor.run {
                    self.contents = c
                    self.playlistRows = rows
                    self.audioPresent = p
                    self.audioMissing = m
                    self.analysisPresent = a
                    self.scanState = .loaded
                }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run { self.scanState = .failed(msg) }
            }
        }
    }

    nonisolated private static func buildPlaylistTree(_ c: PDBContents) -> [PlaylistRow] {
        var byParent: [UInt32: [PDBPlaylistNode]] = [:]
        for n in c.playlistNodes { byParent[n.parentID, default: []].append(n) }
        for k in byParent.keys { byParent[k]?.sort { $0.sortOrder < $1.sortOrder } }

        func build(_ parent: UInt32, _ depth: Int) -> [PlaylistRow] {
            (byParent[parent] ?? []).map { node in
                let kids = build(node.id, depth + 1)
                return PlaylistRow(id: node.id,
                                   name: node.name.isEmpty ? "Untitled" : node.name,
                                   isFolder: node.isFolder,
                                   depth: depth,
                                   trackCount: c.playlistEntries[node.id]?.count ?? 0,
                                   children: kids.isEmpty ? nil : kids)
            }
        }
        return build(0, 0)
    }

    func tracks(inPlaylist id: UInt32?) -> [PDBTrack] {
        guard let c = contents else { return [] }
        guard let id, let ids = c.playlistEntries[id] else {
            return c.tracks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        let byID = Dictionary(uniqueKeysWithValues: c.tracks.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    func displayArtist(_ t: PDBTrack) -> String { contents?.artists[t.artistID] ?? "" }
    func displayAlbum(_ t: PDBTrack) -> String { contents?.albums[t.albumID] ?? "" }
    func displayGenre(_ t: PDBTrack) -> String { contents?.genres[t.genreID] ?? "" }
    func displayKey(_ t: PDBTrack) -> String { contents?.keys[t.keyID] ?? "" }

    // MARK: - building

    func build() {
        guard let drive = selected, let c = contents else { return }
        isBuilding = true
        buildStage = "Preparing…"
        buildFraction = 0
        errorMessage = nil
        lastResult = nil

        let opts = options
        let url = drive.url

        Task.detached(priority: .userInitiated) {
            let writer = EngineWriter(volume: url, options: opts)
            do {
                let res = try writer.build(contents: c) { p in
                    Task { @MainActor in
                        self.buildStage = p.stage
                        self.buildFraction = p.fraction
                    }
                }
                await MainActor.run {
                    self.lastResult = res
                    self.isBuilding = false
                    self.buildStage = "Finished"
                    self.buildFraction = 1
                    self.refreshDrives()
                    if let d = self.drives.first(where: { $0.id == url.path }) { self.selected = d }
                }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run {
                    self.errorMessage = msg
                    self.isBuilding = false
                    self.buildStage = ""
                }
            }
        }
    }

    // MARK: - eject

    /// Unmounts and ejects a drive so another pen can be swapped in.
    /// Refuses while a build is in flight, since that would pull the volume out
    /// from under an in-progress write.
    func eject(_ drive: Drive) {
        guard !isBuilding else {
            ejectError = "A build is still running — wait for it to finish before ejecting."
            return
        }
        // Drop our reference to the scanned library first so nothing keeps the
        // volume busy.
        if selected?.id == drive.id {
            selected = nil
            contents = nil
            playlistRows = []
            audioMissing = []
            lastResult = nil
            scanState = .idle
        }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: drive.url)
            refreshDrives()
        } catch {
            ejectError = "Could not eject “\(drive.name)”: \(error.localizedDescription)"
            refreshDrives()
        }
    }

    func removeEngineLibrary() {
        guard let drive = selected else { return }
        do {
            try EngineWriter(volume: drive.url, options: options).removeEngineLibrary()
            lastResult = nil
            refreshDrives()
            if let d = drives.first(where: { $0.id == drive.url.path }) { selected = d }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

func formatBytes(_ b: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: b)
}
