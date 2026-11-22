#if os(macOS)
import Foundation
import AppKit
import PDFKit
import SQLite3
import ChordProKit

/// Imports an OnSong backup (.backup = zip of OnSong.sqlite3 + chart files): songs, keys, capos,
/// sticky notes and set lists. Charts are converted to transposable ChordPro where possible;
/// otherwise the original document is kept as a PDF-only song. Mac only (needs unzip + Word conversion).
@MainActor
enum OnSongImporter {
    struct Report {
        var converted: [String] = [], viaSongSelect: [String] = [], pdfOnly: [String] = [], documents: [String] = []
        var alreadyHad: [String] = [], missing: [String] = [], failed: [String] = []
        var sets = 0, setItemsSkipped = 0

        var summary: String {
            var lines = ["Imported \(converted.count + viaSongSelect.count) transposable charts (\(viaSongSelect.count) from OnSong's SongSelect integration)."]
            if !pdfOnly.isEmpty || !documents.isEmpty {
                lines.append("\(pdfOnly.count + documents.count) kept as the original document (can't transpose yet): " + (pdfOnly + documents).prefix(12).joined(separator: ", ") + ((pdfOnly + documents).count > 12 ? "…" : ""))
            }
            if !alreadyHad.isEmpty { lines.append("\(alreadyHad.count) already in your library (kept yours).") }
            if !missing.isEmpty { lines.append("Missing from the backup: " + missing.joined(separator: ", ")) }
            if !failed.isEmpty { lines.append("Couldn't import: " + failed.joined(separator: ", ")) }
            lines.append("\(sets) set lists imported" + (setItemsSkipped > 0 ? " (\(setItemsSkipped) entries pointed at missing songs)." : "."))
            return lines.joined(separator: "\n\n")
        }
    }

    private struct OnSongSong {
        let id, title: String
        let provider, path, ccli, key, transposedKey, notesJSON: String?
        let usefile: Bool
        let capo: Int
    }

    static func importBackup(_ backup: URL, into library: SongLibrary) throws -> Report {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("onsong-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 1. Unzip the backup.
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", backup.path, work.path]
        try unzip.run(); unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw err("Couldn't open the OnSong backup (not a zip file?)") }
        let dbURL = work.appendingPathComponent("OnSong.sqlite3")
        guard fm.fileExists(atPath: dbURL.path) else { throw err("No OnSong.sqlite3 inside the backup.") }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw err("Couldn't read the OnSong database.") }
        defer { sqlite3_close(db) }

        // 2. Songs.
        let songs = query(db, "select ID, title, providerName, usefile, filepath, ccli, key, transposedKey, capo, notes from Song where deleted=0") { r in
            OnSongSong(id: r.text(0) ?? "", title: r.text(1) ?? "Untitled", provider: r.text(2), path: r.text(4), ccli: r.text(5),
                       key: r.text(6), transposedKey: r.text(7), notesJSON: r.text(9), usefile: r.int(3) != 0, capo: r.int(8))
        }
        var report = Report()
        var fileFor: [String: String] = [:]                  // OnSong song ID → StageCharts file id
        var settingsChanges: [(String, (inout SongSettings) -> Void)] = []
        let existingByCCLI = Dictionary(library.songs.compactMap { f in f.song.ccli.map { ($0, f.id) } }, uniquingKeysWith: { a, _ in a })

        for s in songs where s.id != "welcome_to_onsong" {
            if let c = s.ccli, !c.isEmpty, let existing = existingByCCLI[c] {
                fileFor[s.id] = existing; report.alreadyHad.append(s.title); continue
            }
            do {
                guard s.usefile, let path = s.path, !path.isEmpty else { report.failed.append(s.title + " (no chart file)"); continue }
                guard let file = locate(path, in: work) else { report.missing.append(s.title); continue }

                let ext = file.pathExtension.lowercased()
                var pdfData: Data?
                var kind = "PDF"
                switch ext {
                case "pdf": pdfData = try Data(contentsOf: file)
                case "doc", "docx", "rtf", "txt": pdfData = documentToPDF(file); kind = "Word"
                case "pages": pdfData = pagesToPDF(file); kind = "Pages"
                case "png", "jpg", "jpeg", "heic": pdfData = imageToPDF(file); kind = "Image"
                default: report.failed.append(s.title + " (.\(ext))"); continue
                }
                guard let pdfData else { report.failed.append(s.title + " (couldn't read .\(ext))"); continue }

                // Try to make it a transposable chart.
                var raw: String?
                if let doc = PDFDocument(data: pdfData) {
                    for relaxed in [false, true] {                 // SongSelect layout first, then any chords-over-lyrics
                        guard raw == nil, let text = try? PDFChordSheetImporter.chordPro(from: doc, relaxed: relaxed) else { continue }
                        let song = ChordProSong(text)
                        let chords = song.sections.flatMap(\.lines).reduce(0) { n, l in
                            if case .lyrics(let segs) = l { return n + segs.filter { $0.chord != nil }.count }; return n }
                        if chords >= 6 { raw = relaxed ? text.replacingOccurrences(of: "{x_source: songselect-pdf}", with: "{x_source: chord-chart}") : text }
                    }
                }

                let fileName: String
                if var text = raw {
                    if s.provider == "SongSelect" {
                        text = text.replacingOccurrences(of: "{x_source: songselect-pdf}", with: "{x_source: onsong-songselect}")
                        report.viaSongSelect.append(s.title)
                    } else {
                        report.converted.append(s.title)
                    }
                    let title = ChordProSong(text).title
                    fileName = library.uniqueFileName(title == "Untitled" ? s.title : title, ext: "chordpro")
                    try library.addSong(fileName: fileName, raw: text)
                } else {
                    // Keep the original document; a small stub carries title, key and CCLI #.
                    if s.provider == "PraiseCharts" || path.localizedCaseInsensitiveContains("Chord Chart") { kind = "PraiseCharts" }
                    let pdfName = library.uniqueFileName(s.title, ext: "pdf", in: library.pdfFolder)
                    var stub = ["{title: \(s.title)}", "{x_pdf: \(pdfName)}", "{x_doc: \(kind)}"]
                    if let k = (s.key?.nonEmpty ?? s.transposedKey?.nonEmpty).flatMap(Key.init) { stub.append("{key: \(k.description)}") }
                    if let c = s.ccli?.nonEmpty { stub.append("{ccli: \(c)}") }
                    fileName = library.uniqueFileName(s.title, ext: "chordpro")
                    try library.addSong(fileName: fileName, raw: stub.joined(separator: "\n") + "\n", pdf: (pdfName, pdfData))
                    if kind == "PDF" || kind == "PraiseCharts" { report.pdfOnly.append(s.title) } else { report.documents.append(s.title) }
                }
                fileFor[s.id] = fileName

                // Key / capo: OnSong's transposedKey is the sounding key; the capo gives the shapes.
                let chartKey = ChordProSong(try String(contentsOf: library.folder.appendingPathComponent(fileName), encoding: .utf8)).key
                let sounding = s.transposedKey?.nonEmpty.flatMap(Key.init)
                let semis = (raw != nil) ? chartKey.flatMap { ck in sounding.map { ck.semitones(to: $0) } } : nil
                let notes = stickyNotes(from: s.notesJSON)
                let capo = s.capo
                settingsChanges.append((fileName, { st in
                    if let semis { st.semitones = semis }
                    if capo > 0 { st.capo = capo }
                    if !notes.isEmpty { st.notes = notes }
                }))
            } catch {
                report.failed.append("\(s.title) (\(error.localizedDescription))")
            }
        }
        library.reload()
        library.updateMany(settingsChanges)

        // 3. Set lists (named by date; OnSong sets here have no titles).
        let items = query(db, "select setID, songID, orderIndex, transposedKey, capo from SongSetItem order by setID, orderIndex") { r in
            (set: r.text(0) ?? "", song: r.text(1) ?? "", key: r.text(3), capo: r.int(4))
        }
        let itemsBySet = Dictionary(grouping: items, by: \.set)
        let sets = query(db, "select ID, title, datetime, created from SongSet") { r in
            (id: r.text(0) ?? "", title: r.text(1), date: r.double(2) > 0 ? r.double(2) : r.double(3))
        }
        var newSets: [SetList] = []
        for s in sets {
            var setItems: [SetItem] = []
            for it in itemsBySet[s.id] ?? [] {
                guard let fid = fileFor[it.song], let f = library.song(id: fid) else { report.setItemsSkipped += 1; continue }
                var item = SetItem(songID: fid)
                if f.song.source.isTransposable, let k = it.key?.nonEmpty.flatMap(Key.init), let ck = f.song.key {
                    item.semitones = ck.semitones(to: k)
                }
                if it.capo > 0 { item.capo = it.capo }
                setItems.append(item)
            }
            guard !setItems.isEmpty else { continue }
            let date = Date(timeIntervalSince1970: s.date)
            let name = s.title?.nonEmpty ?? date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
            newSets.append(SetList(id: stableUUID(s.id), name: name, date: date, items: setItems))
        }
        library.replaceOrAddSets(newSets)
        report.sets = newSets.count
        return report
    }

    // MARK: Helpers

    /// Finds a chart file in the backup, tolerating OnSong's "name.docx.pdf" exports and
    /// differences in apostrophes / spacing / case.
    private static func locate(_ path: String, in dir: URL) -> URL? {
        let fm = FileManager.default
        for candidate in [path, path + ".pdf"] {
            let u = dir.appendingPathComponent(candidate)
            if fm.fileExists(atPath: u.path) { return u }
        }
        func norm(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
                .replacingOccurrences(of: "_", with: "'").components(separatedBy: .whitespaces).joined()
        }
        let want = norm(path), wantPDF = norm(path + ".pdf")
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.first { let n = norm($0); return n == want || n == wantPDF }.map { dir.appendingPathComponent($0) }
    }

    private static func err(_ m: String) -> NSError {
        NSError(domain: "OnSongImport", code: 1, userInfo: [NSLocalizedDescriptionKey: m])
    }

    /// OnSong set IDs are UUIDs (or similar); map them to stable UUIDs so re-importing replaces sets.
    private static func stableUUID(_ s: String) -> UUID {
        if let u = UUID(uuidString: s) { return u }
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, b) in s.utf8.enumerated() { bytes[i % 16] = bytes[i % 16] &* 31 &+ b }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// OnSong stores sticky notes as JSON annotations ({"$class":"OSAnnotationNote","contents":"c5",…}).
    private static func stickyNotes(from json: String?) -> [SongNote] {
        guard let data = json?.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let anns = obj["annotations"] as? [[String: Any]] else { return [] }
        return anns.compactMap { a in
            guard (a["$class"] as? String) == "OSAnnotationNote",
                  let text = (a["contents"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return SongNote(section: nil, text: text)
        }
    }

    /// Word / RTF / text → paginated US Letter PDF.
    static func documentToPDF(_ url: URL) -> Data? {
        var opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        switch url.pathExtension.lowercased() {
        case "docx": opts[.documentType] = NSAttributedString.DocumentType.officeOpenXML
        case "doc": opts[.documentType] = NSAttributedString.DocumentType.docFormat
        case "rtf": opts[.documentType] = NSAttributedString.DocumentType.rtf
        default: opts[.documentType] = NSAttributedString.DocumentType.plain
        }
        guard let text = try? NSAttributedString(url: url, options: opts, documentAttributes: nil) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 720))
        view.textStorage?.setAttributedString(text)
        view.isVerticallyResizable = true
        view.sizeToFit()
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { return nil }
        return try? Data(contentsOf: out)
    }

    /// .pages: use the embedded preview (PDF if present, else the preview image).
    static func pagesToPDF(_ url: URL) -> Data? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        var root = url
        var isDir: ObjCBool = false
        if !(fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", url.path, dir.path]
            try? p.run(); p.waitUntilExit()
            root = dir
        }
        for candidate in ["QuickLook/Preview.pdf", "preview.pdf"] {
            if let d = try? Data(contentsOf: root.appendingPathComponent(candidate)) { return d }
        }
        for candidate in ["preview.jpg", "QuickLook/Thumbnail.jpg", "preview-web.jpg"] {
            let u = root.appendingPathComponent(candidate)
            if fm.fileExists(atPath: u.path) { return imageToPDF(u) }
        }
        return nil
    }

    static func imageToPDF(_ url: URL) -> Data? {
        guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else { return nil }
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        return doc.dataRepresentation()
    }

    // MARK: SQLite

    struct Row {
        let stmt: OpaquePointer?
        func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_double(stmt, i)) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    }

    private static func query<T>(_ db: OpaquePointer?, _ sql: String, _ map: (Row) -> T) -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(map(Row(stmt: stmt))) }
        return out
    }
}

private extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
#endif
