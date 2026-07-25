# PenBridge

A small native macOS app (SwiftUI, Apple Silicon) that adds a **Denon Engine
Library** to a USB drive that already holds a **rekordbox export**, *reusing the
audio that is already on the drive*. No tracks are copied, and the rekordbox
side is never modified.

The result is one pen that works in both a Pioneer CDJ/XDJ and a Denon Prime.

```
/  (USB drive)
├── Contents/            audio — shared by both, written once
├── PIONEER/             read by Pioneer          ← never modified
│   └── rekordbox/export.pdb
└── Engine Library/      read by Denon            ← the only thing added
    └── Database2/m.db
```

## Why this works

Engine stores `Track.path` **relative to the `Engine Library` folder**, and it
accepts paths that climb out of that folder. So a track that rekordbox lists as
`/Contents/Artist/Track.mp3` is written to Engine as `../Contents/Artist/Track.mp3`.
Both databases end up pointing at the same bytes on disk.

This is the same convention libdjinterop uses in its reference example
(`relative_path = "../01 - Some Artist - Some Song.mp3"`).

## Safety model

* The rekordbox database and the ANLZ analysis files are opened **read-only**.
* The Engine database is assembled in a temp folder on the **internal disk**,
  passes `PRAGMA integrity_check`, and only then is copied to the drive.
* Every destination path passes through one guard that rejects anything not
  inside `<volume>/Engine Library`.
* **Undo** is one button, or `rm -rf "/Volumes/YOURPEN/Engine Library"`. The pen
  is then byte-for-byte what it was.

## Schema

The `CREATE TABLE`/`INDEX`/`TRIGGER`/`VIEW` statements in `EngineSchema.swift`
are generated verbatim from libdjinterop's reference databases, which were
captured from real Engine OS output. Engine refuses to load a database whose
schema differs, so this file must not be hand-edited.

| Choice | Written natively by | Read by |
|---|---|---|
| `2.21.0` | Engine OS 3.1 – 3.4 | Engine OS 3.1 → 5.x (as a legacy format) |
| `3.0.1` | Engine OS 4.3 – 4.x | Engine OS 4.3+ |
| `3.0.2` **(default)** | Engine OS 5.0+ | Engine OS 5.0+ |

Engine OS 4.0 dropped support for *legacy* (1.x) databases only, so 2.x is still
accepted everywhere — pick it if you need to support an older player.

Note that schema 2.x and 3.x differ structurally: in 2.x the performance blobs
are columns on `Track` and `PerformanceData` is a view over it, while in 3.x
`PerformanceData` is a real table whose row is created by an `AFTER INSERT`
trigger on `Track`. The writer handles both.

## What gets converted

| rekordbox | Engine |
|---|---|
| tracks + metadata (title, artist, album, genre, label, comment, rating, year) | `Track` |
| playlist tree, incl. folders and order | `Playlist` / `PlaylistEntity` |
| beatgrid (`PQTZ`) | `beatData` (markers at tempo changes, bar-aligned to the first downbeat) |
| hot cues / memory cues (`PCOB`/`PCO2`) | `quickCues` / `loops` |
| preview waveform (`PWAV`) | `overviewWaveFormData` |
| key name | `Track.key` (Engine's 0–23 index, Camelot and classical notation both handled) |

Engine OS regenerates its own detailed scrolling waveform when a track loads, so
only the overview strip is written.

## Download

Grab `PenBridge.app.zip` from the [latest release](../../releases/latest), unzip,
and drop it in `/Applications`.

The build is ad-hoc signed, not notarised, so the first launch needs one of:

* right-click the app → **Open** → **Open**, or
* `xattr -dr com.apple.quarantine /Applications/PenBridge.app`

Apple Silicon, macOS 14+.

## Build

```bash
./make-app.sh          # produces PenBridge.app
```

or open `Package.swift` in Xcode and hit Run.

Headless, for verification:

```bash
PenBridge.app/Contents/MacOS/PenBridge --headless /Volumes/YOURPEN --dry-run
PenBridge.app/Contents/MacOS/PenBridge --headless /Volumes/YOURPEN [--schema 3]
```

## Format references

* Pioneer PDB / ANLZ: Deep Symmetry `crate-digger` Kaitai specs.
* Engine schema and blob layouts: `xsco/libdjinterop`.
