import Foundation
import ChordProKit
import StageMIDI

/// A song file on disk plus its parsed form.
struct SongFile: Identifiable {
    let id: String          // file name, stable key for settings
    let url: URL
    let raw: String
    let song: ChordProSong
}

/// Per-song performance settings (persisted).
struct SongSettings: Codable, Equatable {
    var semitones: Int = 0      // transposition from the file's original key (sets the sounding key)
    var capo: Int = 0           // capo fret; chords are shown as the shapes played with this capo
    var fontScale: Double = 1.0
    var notes: [SongNote] = []
    var tempo: Int? = nil              // the BPM we play it at (nil = use the chart's tempo)
    var midiTrigger: MIDITrigger? = nil   // message that selects this song (CC, note or program)

    init() {}

    enum CodingKeys: String, CodingKey { case semitones, capo, fontScale, notes, tempo, midiTrigger, midiProgram }

    init(from decoder: Decoder) throws {   // tolerate settings files from older versions
        let c = try decoder.container(keyedBy: CodingKeys.self)
        semitones = try c.decodeIfPresent(Int.self, forKey: .semitones) ?? 0
        capo = try c.decodeIfPresent(Int.self, forKey: .capo) ?? 0
        fontScale = try c.decodeIfPresent(Double.self, forKey: .fontScale) ?? 1.0
        notes = try c.decodeIfPresent([SongNote].self, forKey: .notes) ?? []
        tempo = try c.decodeIfPresent(Int.self, forKey: .tempo)
        midiTrigger = try c.decodeIfPresent(MIDITrigger.self, forKey: .midiTrigger)
        if midiTrigger == nil, let p = try c.decodeIfPresent(Int.self, forKey: .midiProgram) {
            midiTrigger = MIDITrigger(.programChange, p)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(semitones, forKey: .semitones)
        try c.encode(capo, forKey: .capo)
        try c.encode(fontScale, forKey: .fontScale)
        if !notes.isEmpty { try c.encode(notes, forKey: .notes) }
        try c.encodeIfPresent(tempo, forKey: .tempo)
        try c.encodeIfPresent(midiTrigger, forKey: .midiTrigger)
    }
}

/// Loads ChordPro files from the app's Songs folder and stores per-song settings.
@MainActor
final class SongLibrary: ObservableObject {
    @Published private(set) var songs: [SongFile] = []
    @Published private(set) var settings: [String: SongSettings] = [:]
    @Published var lastError: String?
    @Published private(set) var setLists: [SetList] = []
    /// Called after the library changes on this device (Google Drive sync listens).
    var onLocalChange: (() -> Void)?
    /// Pencil markings (see ChartInk.swift); bumped when they change so charts redraw.
    let inkCache = InkCache()
    @Published var inkRevision = 0

    static let extensions: Set<String> = ["chordpro", "cho", "crd", "chopro", "pro", "txt"]

    /// Library root: this device's storage, or a folder the user picked (e.g. in Google Drive).
    @Published private(set) var base: URL
    @Published private(set) var usesCustomFolder = false
    var folder: URL { base.appendingPathComponent("Songs", isDirectory: true) }
    private var settingsURL: URL { base.appendingPathComponent("song-settings.json") }
    private var setListsURL: URL { base.appendingPathComponent("setlists.json") }
    private static let bookmarkKey = "libraryFolderBookmark"

    static var deviceBase: URL {
        let fm = FileManager.default
        #if os(macOS)
        return fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StageCharts", isDirectory: true)
        #else
        // Documents is visible in the Files app and Finder file sharing.
        return fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
    }

    init() {
        base = Self.deviceBase
        if let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) {
                _ = url.startAccessingSecurityScopedResource()     // held for the app's lifetime
                base = url
                usesCustomFolder = true
                if stale, let fresh = try? url.bookmarkData() { UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey) }
            }
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !usesCustomFolder { seedSamplesIfEmpty() }
        reloadAll()
    }

    /// Re-reads songs, settings and set lists (e.g. after another device changed the shared folder).
    func reloadAll() {
        inkCache.value = [:]
        inkRevision += 1
        loadSettings()
        loadSetLists()
        reload()
    }

    /// Display name of the library location.
    var locationName: String {
        usesCustomFolder ? base.lastPathComponent : "On this device"
    }

    /// Moves the library into `url` (a folder picked by the user, e.g. in Google Drive). If that folder
    /// already holds a library, the two are merged: songs and documents missing on either side are
    /// added, set lists and settings are combined (the shared folder wins where both have an entry).
    func useFolder(_ url: URL) throws {
        guard url.startAccessingSecurityScopedResource() || FileManager.default.isReadableFile(atPath: url.path) else {
            throw CocoaError(.fileReadNoPermission)
        }
        let fm = FileManager.default
        let target = url.appendingPathComponent("Songs", isDirectory: true)
        let targetPDF = target.appendingPathComponent("PDF", isDirectory: true)
        try fm.createDirectory(at: targetPDF, withIntermediateDirectories: true)
        func copyMissing(from src: URL, to dst: URL) {
            for name in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] {
                let s = src.appendingPathComponent(name), d = dst.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: s.path, isDirectory: &isDir), !isDir.boolValue,
                      !fm.fileExists(atPath: d.path) else { continue }
                try? fm.copyItem(at: s, to: d)
            }
        }
        copyMissing(from: folder, to: target)
        copyMissing(from: pdfFolder, to: targetPDF)
        let targetInk = url.appendingPathComponent("Ink", isDirectory: true)
        try? fm.createDirectory(at: targetInk, withIntermediateDirectories: true)
        copyMissing(from: inkFolder, to: targetInk)
        let targetHelix = url.appendingPathComponent("Helix", isDirectory: true)
        try? fm.createDirectory(at: targetHelix, withIntermediateDirectories: true)
        copyMissing(from: helixFolder, to: targetHelix)

        // Merge settings and set lists (shared folder wins on conflicts).
        let mySettings = settings, mySets = setLists
        let theirSettings = Self.coordinatedData(url.appendingPathComponent("song-settings.json"))
            .flatMap { try? JSONDecoder().decode([String: SongSettings].self, from: $0) } ?? [:]
        let theirSets = Self.coordinatedData(url.appendingPathComponent("setlists.json"))
            .flatMap { try? JSONDecoder.setLists.decode([SetList].self, from: $0) } ?? []

        UserDefaults.standard.set(try url.bookmarkData(), forKey: Self.bookmarkKey)
        if usesCustomFolder { base.stopAccessingSecurityScopedResource() }
        base = url
        usesCustomFolder = true

        settings = mySettings.merging(theirSettings) { _, theirs in theirs }
        saveSettings()
        var byID = Dictionary(mySets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for s in theirSets { byID[s.id] = s }
        setLists = byID.values.sorted { $0.date > $1.date }
        saveSetLists()
        reload()
    }

    /// Brings the library from a shared folder onto this device (merging), then uses device storage.
    /// Used when switching from a Drive-for-Desktop folder to built-in Google Drive sync.
    func moveToDeviceStorage() {
        guard usesCustomFolder else { return }
        let fm = FileManager.default
        let dest = Self.deviceBase.appendingPathComponent("Songs", isDirectory: true)
        let destPDF = dest.appendingPathComponent("PDF", isDirectory: true)
        let destInk = Self.deviceBase.appendingPathComponent("Ink", isDirectory: true)
        let destHelix = Self.deviceBase.appendingPathComponent("Helix", isDirectory: true)
        for d in [destPDF, destInk, destHelix] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        for (src, dst) in [(folder, dest), (pdfFolder, destPDF), (inkFolder, destInk), (helixFolder, destHelix)] {
            for name in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] {
                let s = src.appendingPathComponent(name), d = dst.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: s.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                if let data = Self.coordinatedData(s), (try? Data(contentsOf: d)) != data { try? data.write(to: d, options: .atomic) }
            }
        }
        let mySettings = settings, mySets = setLists
        useDeviceStorage()
        settings = settings.merging(mySettings) { _, mine in mine }
        saveSettings()
        var byID = Dictionary(setLists.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for s in mySets { byID[s.id] = s }
        setLists = byID.values.sorted { $0.date > $1.date }
        saveSetLists()
        reload()
    }

    /// Switches back to this device's own storage (the shared folder is left untouched).
    func useDeviceStorage() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        if usesCustomFolder { base.stopAccessingSecurityScopedResource() }
        base = Self.deviceBase
        usesCustomFolder = false
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        reloadAll()
    }

    // MARK: Songs

    func reload() {
        let fm = FileManager.default
        var urls: [URL] = []
        Self.coordinate(readingAt: folder) { u in
            urls = (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []
        }
        // iCloud Drive may keep only a placeholder (".Name.chordpro.icloud") on this device; use the real
        // name — reading it below downloads it.
        urls = urls.map { u in
            let n = u.lastPathComponent
            guard n.hasPrefix("."), n.hasSuffix(".icloud") else { return u }
            return u.deletingLastPathComponent().appendingPathComponent(String(n.dropFirst().dropLast(7)))
        }
        songs = urls
            .filter { Self.extensions.contains($0.pathExtension.lowercased()) }
            .compactMap { url in
                guard let raw = Self.readText(url) else { return nil }
                return SongFile(id: url.lastPathComponent, url: url, raw: raw, song: ChordProSong(raw))
            }
            .sorted { $0.song.title.localizedCaseInsensitiveCompare($1.song.title) == .orderedAscending }
    }

    func song(id: String?) -> SongFile? {
        guard let id else { return nil }
        return songs.first { $0.id == id }
    }

    /// Songs that have their own MIDI trigger.
    var songTriggers: [(id: String, trigger: MIDITrigger)] {
        songs.compactMap { f in settings(for: f.id).midiTrigger.map { (f.id, $0) } }
    }

    /// Gives `trigger` to one song (clearing it from any other song). nil clears the song's trigger.
    func setTrigger(_ trigger: MIDITrigger?, for id: String) {
        if let trigger {
            for other in songs where other.id != id && settings(for: other.id).midiTrigger == trigger {
                update(other.id) { $0.midiTrigger = nil }
            }
        }
        update(id) { $0.midiTrigger = trigger }
    }

    /// Clears a trigger from every song (used when an action claims it).
    func releaseTrigger(_ trigger: MIDITrigger) {
        for f in songs where settings(for: f.id).midiTrigger == trigger { update(f.id) { $0.midiTrigger = nil } }
    }

    /// Program Change fallback: the song at that list position (1-based).
    func song(atPosition n: Int) -> SongFile? {
        songs.indices.contains(n - 1) ? songs[n - 1] : nil
    }

    /// Copies picked files into the library (replacing same-named files).
    /// Imports charts. A SongSelect ChordPro file for a song you already have from a PDF (same CCLI #)
    /// upgrades that song in place; a PDF never replaces a ChordPro version.
    /// Returns a short summary. `silent` = don't show the import alert (automatic imports use a toast).
    @discardableResult
    func importFiles(_ urls: [URL], silent: Bool = false) -> String? {
        var failures: [String] = [], upgraded: [String] = [], keptChordPro: [String] = [], alreadyHave: [String] = []
        var added: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let ext = url.pathExtension.lowercased()
                if ext == "stageset" { try importSetBundle(url); continue }

                let raw: String
                var name: String
                if ext == "pdf" {
                    raw = try PDFChordSheetImporter.chordPro(fromPDF: url)
                    guard !ChordProSong(raw).sections.isEmpty else {
                        throw NSError(domain: "StageCharts", code: 1, userInfo: [NSLocalizedDescriptionKey:
                            "unsupported PDF layout – re-download it from SongSelect"])
                    }
                    let title = ChordProSong(raw).title
                    name = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-") + ".chordpro"
                    keepOriginalPDF(url)
                } else {
                    guard let text = Self.readText(url) else { throw CocoaError(.fileReadCorruptFile) }
                    raw = text
                    name = url.lastPathComponent
                    // SongSelect saves ChordPro as .txt or without an extension; normalise.
                    if url.pathExtension.isEmpty || ext == "txt" { name = (name as NSString).deletingPathExtension + ".chordpro" }
                }

                let incoming = ChordProSong(raw)
                if let ccli = incoming.ccli, let existing = songs.first(where: { $0.song.ccli == ccli }) {
                    let (old, new) = (existing.song.source.rank, incoming.source.rank)
                    if new > old {                          // better version (e.g. ChordPro over PDF): upgrade in place
                        try upgrade(existing, to: raw)
                        upgraded.append(incoming.title)
                    } else if new < old {                   // never downgrade
                        keptChordPro.append(incoming.title)
                    } else if existing.raw != raw {         // same kind: keep what's in the library
                        alreadyHave.append(incoming.title)
                    }
                    continue
                }
                try write(raw, to: folder.appendingPathComponent(name))
                added.append(incoming.title)
            } catch {
                failures.append("\(url.lastPathComponent) (\(error.localizedDescription))")
            }
        }
        reload()
        var report: [String] = []
        if !upgraded.isEmpty { report.append("Upgraded to a better version (set lists, notes, MIDI and keys kept): " + upgraded.joined(separator: ", ")) }
        if !keptChordPro.isEmpty { report.append("Kept your better version of: " + keptChordPro.joined(separator: ", ")) }
        if !alreadyHave.isEmpty { report.append("Already in your library (kept yours): " + alreadyHave.joined(separator: ", ")) }
        if !failures.isEmpty { report.append("Couldn't import: " + failures.joined(separator: ", ")) }
        if !silent { lastError = report.isEmpty ? nil : report.joined(separator: "\n\n") }
        if !added.isEmpty { report.insert("Added: " + added.joined(separator: ", "), at: 0) }
        return report.isEmpty ? nil : report.joined(separator: "\n")
    }

    /// Our BPM for a song (nil = chart tempo); the time signature is saved in the chart itself.
    func setTempoAndTime(_ id: String, ourTempo: Int?, time: String?) {
        update(id) { $0.tempo = ourTempo }
        guard let f = song(id: id), time != f.song.time else { return }
        try? write(ChordProDocument.setting("time", to: time, in: f.raw), to: f.url)
        reload()
    }

    /// The BPM we play a song at: our setting, else the chart's.
    func tempo(for file: SongFile) -> Int? {
        settings(for: file.id).tempo ?? file.song.tempo.flatMap { Int($0) }
    }

    /// Saves a chart converted by AI: replaces `existing` (or a lower-ranked song with the same CCLI #)
    /// in place, keeping set lists, keys, capos, notes and MIDI; otherwise adds it. Returns the song id.
    @discardableResult
    /// `original`: the document the chart was made from when it isn't already in the library; it's copied
    /// next to the PDF-only files so the original can still be viewed.
    func saveAIChart(_ raw: String, replacing existing: SongFile?, original: URL? = nil) throws -> String {
        var raw = raw
        if let existing, let file = existing.song.pdfFile ?? existing.song.originalFile {
            raw = ChordProDocument.setting("x_original", to: file, in: raw)
            raw = ChordProDocument.setting("x_original_doc", to: existing.song.documentKind ?? existing.song.originalKind ?? "PDF", in: raw)
        } else if let original {
            try? FileManager.default.createDirectory(at: pdfFolder, withIntermediateDirectories: true)
            let title = ChordProSong(raw).title
            let ext = original.pathExtension.lowercased()
            let name = uniqueFileName(title.isEmpty ? original.deletingPathExtension().lastPathComponent : title,
                                      ext: ext.isEmpty ? "pdf" : ext, in: pdfFolder)
            if let data = Self.coordinatedData(original) ?? (try? Data(contentsOf: original)),
               Self.coordinatedWrite(data, to: pdfFolder.appendingPathComponent(name)) {
                raw = ChordProDocument.setting("x_original", to: name, in: raw)
                let picked = original.lastPathComponent
                let kind = picked.hasPrefix("Chart photo") ? "Image" : picked.hasPrefix("Scanned chart") ? "scanned PDF"
                    : ext == "pdf" ? "PDF" : "Image"
                raw = ChordProDocument.setting("x_original_doc", to: kind, in: raw)
            }
        }
        let incoming = ChordProSong(raw)
        let target = existing ?? incoming.ccli.flatMap { c in
            songs.first { $0.song.ccli == c && $0.song.source.rank < incoming.source.rank }
        }
        if let target {
            try upgrade(target, to: raw)
            reload()
            return target.id
        }
        let name = uniqueFileName(incoming.title.isEmpty ? "Untitled" : incoming.title, ext: "chordpro")
        try write(raw, to: folder.appendingPathComponent(name))
        reload()
        return name
    }

    /// Replaces a converted-from-PDF chart with a ChordPro chart, keeping the same file (so set lists,
    /// MIDI triggers and notes still point at it) and the same sounding keys everywhere.
    private func upgrade(_ existing: SongFile, to raw: String) throws {
        var raw = raw
        let incoming = ChordProSong(raw)
        // Keep tempo / time signature you'd set if the new file doesn't have them.
        if incoming.tempo == nil, let t = existing.song.tempo { raw = ChordProDocument.setting("tempo", to: t, in: raw) }
        if incoming.time == nil, let t = existing.song.time { raw = ChordProDocument.setting("time", to: t, in: raw) }
        try write(raw, to: existing.url)
        let oldKey = existing.song.key, newKey = ChordProSong(raw).key
        guard let oldKey, let newKey, oldKey.root != newKey.root else { return }
        let delta = newKey.semitones(to: oldKey)        // keep: newOriginal + new = oldOriginal + old
        func adjust(_ v: Int) -> Int { var x = (v + delta) % 12; if x > 6 { x -= 12 }; if x < -5 { x += 12 }; return x }
        update(existing.id) { $0.semitones = adjust($0.semitones) }
        for set in setLists {
            for item in set.items where item.songID == existing.id {
                updateItem(set: set.id, item: item.id) { $0.semitones = adjust($0.semitones ?? 0) }
            }
        }
    }

    private func write(_ text: String, to url: URL) throws {
        guard let data = text.data(using: .utf8) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        defer { onLocalChange?() }
        guard Self.coordinatedWrite(data, to: url) else {
            throw NSError(domain: "StageCharts", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "couldn't save to \(url.deletingLastPathComponent().path) – is the library folder available?"])
        }
    }

    /// Folder holding original documents of PDF-only songs.
    var pdfFolder: URL { folder.appendingPathComponent("PDF", isDirectory: true) }

    /// A file name in Songs/ (or Songs/PDF/) that isn't taken yet: "Title.ext", "Title (2).ext"…
    func uniqueFileName(_ title: String, ext: String, in dir: URL? = nil) -> String {
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let dir = dir ?? folder
        var name = "\(safe).\(ext)", n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            name = "\(safe) (\(n)).\(ext)"; n += 1
        }
        return name
    }

    /// Adds a song (ChordPro text, or a PDF-only stub with its document). Call reload() afterwards.
    func addSong(fileName: String, raw: String, pdf: (name: String, data: Data)? = nil) throws {
        if let pdf {
            try FileManager.default.createDirectory(at: pdfFolder, withIntermediateDirectories: true)
            guard Self.coordinatedWrite(pdf.data, to: pdfFolder.appendingPathComponent(pdf.name)) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try write(raw, to: folder.appendingPathComponent(fileName))
    }

    /// Applies many settings changes with a single save.
    func updateMany(_ changes: [(String, (inout SongSettings) -> Void)]) {
        for (id, change) in changes { var s = settings(for: id); change(&s); settings[id] = s }
        saveSettings()
    }

    /// Adds or replaces many set lists with a single save.
    func replaceOrAddSets(_ sets: [SetList]) {
        for set in sets {
            if let i = setLists.firstIndex(where: { $0.id == set.id }) { setLists[i] = set } else { setLists.append(set) }
        }
        setLists.sort { $0.date > $1.date }
        saveSetLists()
    }

    /// Keeps a copy of imported PDFs next to the library (fallback / reference).
    private func keepOriginalPDF(_ url: URL) {
        let fm = FileManager.default
        let originals = base.appendingPathComponent("Original PDFs", isDirectory: true)
        try? fm.createDirectory(at: originals, withIntermediateDirectories: true)
        let dest = originals.appendingPathComponent(url.lastPathComponent)
        try? fm.removeItem(at: dest)
        try? fm.copyItem(at: url, to: dest)
    }

    func delete(_ ids: [String]) {
        for id in ids {
            if let s = song(id: id) { try? FileManager.default.removeItem(at: s.url) }
            settings[id] = nil
        }
        saveSettings()
        reload()
    }

    // MARK: Settings

    func settings(for id: String) -> SongSettings { settings[id] ?? SongSettings() }

    func update(_ id: String, _ change: (inout SongSettings) -> Void) {
        var s = settings(for: id)
        change(&s)
        settings[id] = s
        saveSettings()
    }

    private func loadSettings() {
        guard let data = Self.coordinatedData(settingsURL),
              let decoded = try? JSONDecoder().decode([String: SongSettings].self, from: data) else { settings = [:]; return }
        settings = decoded
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) { Self.coordinatedWrite(data, to: settingsURL) }
        onLocalChange?()
    }

    // MARK: Set lists

    func setList(id: UUID?) -> SetList? { setLists.first { $0.id == id } }

    @discardableResult
    func createSet(name: String, date: Date = Date(), songIDs: [String] = []) -> SetList {
        let set = SetList(name: name, date: date, items: songIDs.map { SetItem(songID: $0) })
        setLists.append(set)
        setLists.sort { $0.date > $1.date }
        saveSetLists()
        return set
    }

    func updateSet(_ id: UUID, _ change: (inout SetList) -> Void) {
        guard let i = setLists.firstIndex(where: { $0.id == id }) else { return }
        change(&setLists[i])
        saveSetLists()
    }

    func updateItem(set setID: UUID, item itemID: UUID, _ change: (inout SetItem) -> Void) {
        updateSet(setID) { set in
            if let i = set.items.firstIndex(where: { $0.id == itemID }) { change(&set.items[i]) }
        }
    }

    /// Adds a set, or replaces the existing set with the same id (re-sent from another device).
    func replaceOrAddSet(_ set: SetList) {
        if let i = setLists.firstIndex(where: { $0.id == set.id }) { setLists[i] = set } else { setLists.append(set) }
        setLists.sort { $0.date > $1.date }
        saveSetLists()
    }

    func deleteSet(_ id: UUID) {
        setLists.removeAll { $0.id == id }
        saveSetLists()
    }

    private func loadSetLists() {
        guard let data = Self.coordinatedData(setListsURL),
              let decoded = try? JSONDecoder.setLists.decode([SetList].self, from: data) else { setLists = []; return }
        setLists = decoded
    }

    private func saveSetLists() {
        if let data = try? JSONEncoder.setLists.encode(setLists) { Self.coordinatedWrite(data, to: setListsURL) }
        onLocalChange?()
    }

    // MARK: Helpers

    private func seedSamplesIfEmpty() {
        let fm = FileManager.default
        let existing = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        guard existing.isEmpty, let resources = Bundle.main.resourceURL,
              let bundled = try? fm.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil) else { return }
        for url in bundled where Self.extensions.contains(url.pathExtension.lowercased()) {
            try? fm.copyItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
        }
    }

    // MARK: Coordinated file access (lets cloud providers like Google Drive download/upload safely)

    nonisolated static func coordinate(readingAt url: URL, _ body: (URL) -> Void) {
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error, byAccessor: body)
        if error != nil { body(url) }
    }

    /// iCloud placeholder for a file that hasn't been downloaded to this device yet.
    nonisolated static func placeholder(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
    }

    nonisolated static func coordinatedData(_ url: URL) -> Data? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            guard fm.fileExists(atPath: placeholder(for: url).path) else { return nil }
            try? fm.startDownloadingUbiquitousItem(at: url)   // coordinated read below waits for it
        }
        var data: Data?
        coordinate(readingAt: url) { data = try? Data(contentsOf: $0) }
        return data
    }

    @discardableResult
    nonisolated static func coordinatedWrite(_ data: Data, to url: URL) -> Bool {
        var error: NSError?
        var ok = false
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { u in
            ok = (try? data.write(to: u, options: .atomic)) != nil
        }
        if !ok { ok = (try? data.write(to: url, options: .atomic)) != nil }
        return ok
    }

    nonisolated static func readText(_ url: URL) -> String? {
        guard let data = coordinatedData(url) else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
    }
}
