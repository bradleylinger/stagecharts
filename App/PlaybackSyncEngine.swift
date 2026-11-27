#if os(macOS)
import Foundation
import AppKit
import SQLite3

/// Writes a StageCharts set into the setlist currently loaded in MultiTracks Playback (Mac), by editing
/// Playback's local Core Data store while Playback is closed. Unsupported by MultiTracks: every write is
/// guarded (schema check, backup, one transaction, optimistic Z_OPT checks) and refuses if anything is off.
///
/// What it can do: rename click items, set their key / BPM / time signature, set a new key on MultiTracks
/// songs (Playback renders it when you select the song and click Update), and reorder. It can't add items
/// or create setlists – build the Playback setlist with enough items (click items as placeholders) first.
/// Afterwards press Save in Playback's setlist menu to upload.
enum PlaybackSync {
    static let bundleID = "com.multitracks.custommixplayer"
    static var storeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Containers/com.multitracks.custommixplayer/Data/Library/Application Support/com.multitracks.playback")
    }
    static var storeURL: URL { storeDir.appendingPathComponent("AppData.storedata") }
    static var backupRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StageCharts/Playback backups", isDirectory: true)
    }

    // MARK: Input / plan

    struct Song {
        var title: String
        var keyRoot: Int?          // pitch class of the sounding key
        var keyMinor = false
        var keyName: String?       // e.g. "Bb"
        var bpm: Int?
        var time: String?          // "3/4"
        var pad: Int? = nil        // pad ContentID, 0 = Playback's default pad, nil = leave as is
        var itemID: UUID? = nil    // the StageCharts set item
    }

    /// A pad pack in Playback's library (ZPAD).
    struct Pad: Identifiable, Hashable {
        let pk: Int64
        let contentID: Int
        let title: String
        let producer: String?
        let downloaded: Bool
        var id: Int { contentID }
    }

    struct Item {
        let pk: Int64
        let opt: Int64
        let contentType: Int64     // 12 click, 13 MultiTracks song
        let title: String
        let customName: String?
        let keyID: Int64?
        let bpm: Double?
        let fok: Int64
        let order: Int64?
        let timeData: String?
        var arrangement: Int64? = nil   // the ZSONGARRANGEMENT row Playback plays (ZID = ZWORKINGCOPYARRANGEMENTID)
        var arrangementOpt: Int64 = 0
        var usesDefaultPad = true
        var storedPad: Int64? = nil     // ZPAD.Z_PK
        var isClick: Bool { contentType == 12 }
        var isSong: Bool { contentType == 13 }
        var displayName: String { (customName?.isEmpty == false ? customName! : title) }
    }

    struct Setlist { let pk: Int64; let opt: Int64; let title: String; let serverVersion: Int64?; let items: [Item] }

    /// Everything read from Playback's library.
    struct Library {
        let setlist: Setlist
        let keys: [KeyRow]
        let times: [TimeRow]
        let pads: [Pad]                 // empty if this Playback version stores pads differently
        let defaultPad: Int?            // ContentID of Playback's default pad (its preferences)
    }

    /// What a sync does to an item's pad.
    struct PadChange { let useDefault: Bool; let pad: Pad? }

    struct KeyRow { let id: Int64; let title: String; let root: Int; let minor: Bool }
    struct TimeRow { let id: Int64; let title: String }

    struct Change: Identifiable {
        let id = UUID()
        let song: Song?
        let item: Item
        var newOrder: Int          // 1-based
        var name: String?          // click items
        var keyID: Int64?
        var keyTitle: String?
        var bpm: Int?
        var time: TimeRow?
        var pad: PadChange?
        var needsUpdate = false    // MultiTracks song re-keyed: select it in Playback and click Update
        var notes: [String] = []
        var touchesRow: Bool { name != nil || keyID != nil || bpm != nil || time != nil || pad != nil }
        var touchesSong: Bool { name != nil || keyID != nil || bpm != nil || time != nil }
    }

    struct Plan {
        let setlist: Setlist
        let changes: [Change]      // every item, in the new order
        let problems: [String]     // reasons the sync can't run
        let warnings: [String]
        var canApply: Bool { problems.isEmpty }
        var needsUpdate: [Change] { changes.filter(\.needsUpdate) }
    }

    enum Failure: LocalizedError {
        case notInstalled, running, schema(String), sql(String), guardFailed(String), integrity(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Playback's library wasn't found on this Mac. Open Playback once and load a setlist."
            case .running: return "Playback is still running. Quit it first."
            case .schema(let s): return "This version of Playback stores setlists differently than expected (\(s)). Nothing was changed."
            case .sql(let s): return "Playback's library couldn't be read: \(s)"
            case .guardFailed(let s): return "Playback's setlist changed while syncing (\(s)). Nothing was changed."
            case .integrity(let s): return "Playback's library failed its integrity check (\(s)). Nothing was changed."
            }
        }
    }

    // MARK: Playback process

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Polite quit (the same request as ⌘Q from the Dock); never force-quits. Waits up to `timeout`.
    static func quitPlayback(timeout: TimeInterval = 20) async -> Bool {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) { app.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isRunning { try? await Task.sleep(for: .milliseconds(700)); return !isRunning }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return !isRunning
    }

    static func openPlayback() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Reading

    static let requiredColumns: [String: [String]] = [
        "ZSETLIST": ["Z_PK", "Z_OPT", "ZTITLE", "ZHASUNSYNCEDCHANGES"],
        "ZSONG": ["Z_PK", "Z_OPT", "ZSETLIST", "ZCONTENTTYPEID", "ZTITLE", "ZCUSTOMNAME", "ZKEYID", "ZBPM",
                  "Z_FOK_SETLIST", "ZORDER", "ZKEYIDFORSHIFT", "ZBPMFORSHIFT", "ZHASBUILTCLICKLOCALLY",
                  "ZTIMESIGNATURESDATA"],
        "ZMETADATAKEY": ["ZID", "ZTITLE"],
        "ZMETADATATIMESIGNATURE": ["ZSTOREDID", "ZTITLE"],
    ]
    /// Needed for pads only; without them the sync still runs, just without the Pad column.
    static let padColumns: [String: [String]] = [
        "ZSONG": ["ZWORKINGCOPYARRANGEMENTID"],
        "ZSONGARRANGEMENT": ["Z_PK", "Z_OPT", "ZSONG", "ZID", "ZUSEDEFAULTPAD", "ZSTOREDPAD"],
        "ZPAD": ["Z_PK", "ZCONTENTID", "ZTITLE", "ZPRODUCER", "ZSTOREDDOWNLOADEDAUDIOBYTECOUNT"],
    ]
    static var prefsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Containers/\(bundleID)/Data/Library/Preferences/\(bundleID).plist")
    }

    static func read(at url: URL = storeURL) throws -> Library {
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.notInstalled }
        // Read a private copy (all three files), so Playback's live files are never opened while it runs.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("playback-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let copy = tmp.appendingPathComponent(url.lastPathComponent)
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
            try FileManager.default.copyItem(atPath: url.path + suffix, toPath: copy.path + suffix)
        }
        let db = try DB(copy, readOnly: false)
        try checkSchema(db)
        let lists = try db.rows("SELECT Z_PK, Z_OPT, ZTITLE, ZSERVERVERSION FROM ZSETLIST")
        guard lists.count == 1, let pk = lists[0][0].int else {
            throw Failure.schema(lists.isEmpty ? "no setlist is loaded – open one in Playback first" : "\(lists.count) setlists stored")
        }
        let hasPads = (try? checkColumns(db, padColumns)) != nil
        let padJoin = hasPads ? """
            , a.Z_PK, a.Z_OPT, a.ZUSEDEFAULTPAD, a.ZSTOREDPAD FROM ZSONG s
            LEFT JOIN ZSONGARRANGEMENT a ON a.ZSONG = s.Z_PK AND a.ZID = s.ZWORKINGCOPYARRANGEMENTID
            """ : " FROM ZSONG s"
        let items = try db.rows("""
            SELECT s.Z_PK, s.Z_OPT, s.ZCONTENTTYPEID, s.ZTITLE, s.ZCUSTOMNAME, s.ZKEYID, s.ZBPM, s.Z_FOK_SETLIST, s.ZORDER,
                   CAST(s.ZTIMESIGNATURESDATA AS TEXT)\(padJoin)
            WHERE s.ZSETLIST = ? ORDER BY s.Z_FOK_SETLIST
            """, [.int(pk)]).map { r in
            var it = Item(pk: r[0].int ?? 0, opt: r[1].int ?? 0, contentType: r[2].int ?? 0, title: r[3].text ?? "",
                          customName: r[4].text, keyID: r[5].int, bpm: r[6].double, fok: r[7].int ?? 0, order: r[8].int,
                          timeData: r[9].text)
            if hasPads, let a = r[10].int {
                it.arrangement = a; it.arrangementOpt = r[11].int ?? 0
                it.usesDefaultPad = (r[12].int ?? 1) != 0; it.storedPad = r[13].int
            }
            return it
        }
        let pads: [Pad] = hasPads ? try db.rows("""
            SELECT Z_PK, ZCONTENTID, ZTITLE, ZPRODUCER, ZSTOREDDOWNLOADEDAUDIOBYTECOUNT FROM ZPAD ORDER BY ZTITLE
            """).compactMap { r in
            guard let pk = r[0].int, let cid = r[1].int, let t = r[2].text else { return nil }
            return Pad(pk: pk, contentID: Int(cid), title: t, producer: r[3].text, downloaded: (r[4].int ?? 0) > 0)
        } : []
        let prefs = NSDictionary(contentsOf: prefsURL)
        let defaultPad = (prefs?["PadPlayerDefaultPadContentID"] as? NSNumber)?.intValue
        let keys = try db.rows("SELECT ZID, ZTITLE FROM ZMETADATAKEY").compactMap { r -> KeyRow? in
            guard let id = r[0].int, let t = r[1].text, let (root, minor) = parseKey(t) else { return nil }
            return KeyRow(id: id, title: t, root: root, minor: minor)
        }
        let times = try db.rows("SELECT ZSTOREDID, ZTITLE FROM ZMETADATATIMESIGNATURE").compactMap { r -> TimeRow? in
            guard let id = r[0].int, let t = r[1].text else { return nil }
            return TimeRow(id: id, title: t.replacingOccurrences(of: " ", with: ""))
        }
        let l = lists[0]
        return Library(setlist: Setlist(pk: pk, opt: l[1].int ?? 0, title: l[2].text ?? "", serverVersion: l[3].int, items: items),
                       keys: keys, times: times, pads: pads, defaultPad: defaultPad)
    }

    static func checkSchema(_ db: DB) throws { try checkColumns(db, requiredColumns) }

    static func checkColumns(_ db: DB, _ required: [String: [String]]) throws {
        for (table, cols) in required {
            let have = Set(try db.rows("PRAGMA table_info(\(table))").compactMap { $0[1].text })
            if have.isEmpty { throw Failure.schema("missing table \(table)") }
            let missing = cols.filter { !have.contains($0) }
            if !missing.isEmpty { throw Failure.schema("\(table) lacks \(missing.joined(separator: ", "))") }
        }
    }

    /// "Bb", "F#m", "Gb", "C# Minor" → (pitch class, minor).
    static func parseKey(_ s: String) -> (Int, Bool)? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let f = t.first, let base = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][String(f).uppercased()] else { return nil }
        var rest = t.dropFirst(), pc = base
        if let a = rest.first, "#♯".contains(a) { pc += 1; rest = rest.dropFirst() }
        else if let a = rest.first, "b♭".contains(a) { pc -= 1; rest = rest.dropFirst() }
        let suffix = rest.trimmingCharacters(in: .whitespaces).lowercased()
        let minor: Bool
        switch suffix {
        case "", "maj", "major": minor = false
        case "m", "min", "minor", "-": minor = true
        default: return nil
        }
        return ((pc + 12) % 12, minor)
    }

    static func normalized(_ s: String) -> String {
        s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "&", with: "and")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    // MARK: Planning

    /// Matches set songs to Playback items: MultiTracks songs by title, the rest onto click items in order.
    static func plan(_ songs: [Song], library lib: Library, setTimeSignatures: Bool) -> Plan {
        let setlist = lib.setlist, keys = lib.keys, times = lib.times
        var problems: [String] = [], warnings: [String] = []
        var free = setlist.items
        var assigned: [(Song, Item)] = []
        var unplaced: [Int] = []
        // 1. MultiTracks songs with the same title.
        var slot: [Int: Item] = [:]
        for (i, s) in songs.enumerated() {
            let n = normalized(s.title)
            if let j = free.firstIndex(where: { $0.isSong && (normalized($0.title) == n || normalized($0.displayName) == n) }) {
                slot[i] = free.remove(at: j)
            }
        }
        // 2. Click items that already carry the song's name (a re-sync), then any click item in order.
        for (i, s) in songs.enumerated() where slot[i] == nil {
            let n = normalized(s.title)
            if let j = free.firstIndex(where: { $0.isClick && normalized($0.customName ?? "") == n }) { slot[i] = free.remove(at: j) }
        }
        for i in songs.indices where slot[i] == nil {
            if let j = free.firstIndex(where: \.isClick) { slot[i] = free.remove(at: j) } else { unplaced.append(i) }
        }
        for i in songs.indices { if let it = slot[i] { assigned.append((songs[i], it)) } }
        if !unplaced.isEmpty {
            problems.append("The Playback setlist needs \(unplaced.count) more click item\(unplaced.count == 1 ? "" : "s") for: "
                            + unplaced.map { songs[$0].title }.joined(separator: ", ")
                            + ". Add click tracks as placeholders in Playback, then sync again.")
        }

        func keyRow(_ s: Song) -> KeyRow? {
            guard let root = s.keyRoot else { return nil }
            let candidates = keys.filter { $0.root == root && $0.minor == s.keyMinor }
            return candidates.first { $0.title.replacingOccurrences(of: " ", with: "") == s.keyName } ?? candidates.first
        }

        var changes: [Change] = []
        for (n, (s, it)) in assigned.enumerated() {
            var c = Change(song: s, item: it, newOrder: n + 1)
            let k = keyRow(s)
            if s.keyRoot != nil && k == nil { c.notes.append("Playback has no key \(s.keyName ?? "?")") }
            if it.isClick {
                if it.customName != s.title { c.name = s.title }
                if let k, k.id != it.keyID { c.keyID = k.id; c.keyTitle = k.title }
                if let b = s.bpm, b > 0, Int((it.bpm ?? 0).rounded()) != b { c.bpm = b }
                if setTimeSignatures, let t = s.time?.replacingOccurrences(of: " ", with: ""),
                   let row = times.first(where: { $0.title == t }) {
                    let current = Self.timeID(from: it.timeData)
                    if current != row.id { c.time = row; c.notes.append("time signature: check the loop point plays in \(t)") }
                }
            } else if it.isSong {
                if let k, k.id != it.keyID { c.keyID = k.id; c.keyTitle = k.title; c.needsUpdate = true }
                if let b = s.bpm, let cur = it.bpm, abs(cur - Double(b)) >= 1 {
                    c.notes.append("tempo left at \(Int(cur.rounded())) (MultiTracks song tempo isn't changed)")
                }
            } else {
                c.notes.append("not a click or MultiTracks song – left as is")
            }
            if let want = s.pad, it.isClick || it.isSong {
                if it.arrangement == nil {
                    if !lib.pads.isEmpty { c.notes.append("pad not set: Playback has no arrangement for this item") }
                } else if want == 0 {
                    if !it.usesDefaultPad { c.pad = PadChange(useDefault: true, pad: nil) }
                } else if let pad = lib.pads.first(where: { $0.contentID == want }) {
                    if !pad.downloaded { c.notes.append("pad \(pad.title) isn't downloaded in Playback – left as is") }
                    else if it.usesDefaultPad || it.storedPad != pad.pk { c.pad = PadChange(useDefault: false, pad: pad) }
                } else {
                    c.notes.append("pad not in Playback's library – left as is")
                }
            }
            changes.append(c)
        }
        // Items that aren't in the StageCharts set go to the end, unchanged, in their current order.
        for it in free { changes.append(Change(song: nil, item: it, newOrder: changes.count + 1)) }
        if !free.isEmpty {
            warnings.append("\(free.count) Playback item\(free.count == 1 ? " isn't" : "s aren't") in this set and will be moved to the end: "
                            + free.map(\.displayName).joined(separator: ", "))
        }
        return Plan(setlist: setlist, changes: changes, problems: problems, warnings: warnings)
    }

    static func timeID(from json: String?) -> Int64? {
        guard let d = json?.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]], let first = arr.first else { return nil }
        return (first["timeID"] as? NSNumber)?.int64Value
    }

    // MARK: Applying

    struct Result { let backup: URL; let changedRows: Int; let needsUpdate: [String] }

    /// Playback must be closed. Backs up, applies everything in one transaction, verifies.
    static func apply(_ plan: Plan, at url: URL = storeURL) throws -> Result {
        guard plan.canApply else { throw Failure.guardFailed(plan.problems.joined(separator: " ")) }
        guard !isRunning || url != storeURL else { throw Failure.running }
        let backup = try makeBackup(of: url)
        let db = try DB(url, readOnly: false)
        try checkIntegrity(db)
        try checkSchema(db)
        try db.exec("BEGIN IMMEDIATE")
        var changed = 0
        do {
            // Order: hand the existing Z_FOK_SETLIST values out in the new order.
            let foks = plan.changes.map(\.item.fok).sorted()
            for (i, c) in plan.changes.enumerated() {
                var sets: [String] = [], args: [DB.Value] = []
                if foks[i] != c.item.fok { sets.append("Z_FOK_SETLIST = ?"); args.append(.int(foks[i])) }
                if c.item.order != Int64(c.newOrder) { sets.append("ZORDER = ?"); args.append(.int(Int64(c.newOrder))) }
                if let n = c.name { sets.append("ZCUSTOMNAME = ?"); args.append(.text(n)) }
                if let k = c.keyID {
                    if c.item.isSong {
                        sets.append("ZKEYIDFORSHIFT = ?"); args.append(.int(k))
                        sets.append("ZBPMFORSHIFT = ?"); args.append(.double(c.item.bpm ?? 0))
                    } else { sets.append("ZKEYID = ?"); args.append(.int(k)) }
                }
                if let b = c.bpm { sets.append("ZBPM = ?"); args.append(.double(Double(b))) }
                if let t = c.time {
                    let beats = Int(t.title.split(separator: "/").first ?? "4") ?? 4
                    let unit = Int(t.title.split(separator: "/").last ?? "4") ?? 4
                    let json = #"[{"order":0,"beatsPerBar":\#(beats),"timeID":\#(t.id),"time":0,"timeCode":"00:00:000","beatUnit":\#(unit)}]"#
                    sets.append("ZTIMESIGNATURESDATA = CAST(? AS BLOB)"); args.append(.text(json))
                }
                if c.bpm != nil || c.time != nil { sets.append("ZHASBUILTCLICKLOCALLY = 0") }
                if let p = c.pad, let a = c.item.arrangement {
                    // The arrangement Playback plays: "use the default pad" off and the chosen pad, or back to the default.
                    let n = p.useDefault
                        ? try db.run("UPDATE ZSONGARRANGEMENT SET ZUSEDEFAULTPAD = 1, Z_OPT = Z_OPT + 1 WHERE Z_PK = ? AND Z_OPT = ? AND ZSONG = ?",
                                     [.int(a), .int(c.item.arrangementOpt), .int(c.item.pk)])
                        : try db.run("UPDATE ZSONGARRANGEMENT SET ZUSEDEFAULTPAD = 0, ZSTOREDPAD = ?, Z_OPT = Z_OPT + 1 WHERE Z_PK = ? AND Z_OPT = ? AND ZSONG = ?",
                                     [.int(p.pad?.pk ?? 0), .int(a), .int(c.item.arrangementOpt), .int(c.item.pk)])
                    guard n == 1 else { throw Failure.guardFailed("“\(c.item.displayName)” pad") }
                    if sets.isEmpty { changed += 1 }
                }
                guard !sets.isEmpty else { continue }
                sets.append("Z_OPT = Z_OPT + 1")
                let n = try db.run("UPDATE ZSONG SET \(sets.joined(separator: ", ")) WHERE Z_PK = ? AND Z_OPT = ? AND ZSETLIST = ? AND Z_FOK_SETLIST = ?",
                                   args + [.int(c.item.pk), .int(c.item.opt), .int(plan.setlist.pk), .int(c.item.fok)])
                guard n == 1 else { throw Failure.guardFailed("“\(c.item.displayName)”") }
                changed += 1
            }
            let n = try db.run("UPDATE ZSETLIST SET ZHASUNSYNCEDCHANGES = 1, Z_OPT = Z_OPT + 1 WHERE Z_PK = ? AND Z_OPT = ?",
                               [.int(plan.setlist.pk), .int(plan.setlist.opt)])
            guard n == 1 else { throw Failure.guardFailed("setlist") }
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
        try checkIntegrity(db)
        return Result(backup: backup, changedRows: changed, needsUpdate: plan.needsUpdate.map(\.item.displayName))
    }

    static func checkIntegrity(_ db: DB) throws {
        let r = try db.rows("PRAGMA integrity_check").first?.first?.text ?? "?"
        guard r == "ok" else { throw Failure.integrity(r) }
    }

    // MARK: Backups

    static func makeBackup(of url: URL) throws -> URL {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HHmmss"
        let dir = backupRoot.appendingPathComponent(df.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: src.path) {
                try FileManager.default.copyItem(at: src, to: dir.appendingPathComponent(src.lastPathComponent))
            }
        }
        return dir
    }

    static var latestBackup: URL? {
        (try? FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil))?
            .filter { $0.hasDirectoryPath }.sorted { $0.lastPathComponent < $1.lastPathComponent }.last
    }

    /// Puts all three files back (a missing -wal/-shm in the backup removes the live one, so no stale WAL replays).
    static func restore(_ backup: URL, to url: URL = storeURL) throws {
        guard !isRunning || url != storeURL else { throw Failure.running }
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let live = URL(fileURLWithPath: url.path + suffix)
            let saved = backup.appendingPathComponent(live.lastPathComponent)
            if fm.fileExists(atPath: live.path) { try fm.removeItem(at: live) }
            if fm.fileExists(atPath: saved.path) { try fm.copyItem(at: saved, to: live) }
        }
    }
}

// MARK: Minimal SQLite wrapper

extension PlaybackSync {
    final class DB {
        enum Value {
            case int(Int64), double(Double), text(String), null
            var int: Int64? { if case .int(let v) = self { return v }; if case .double(let d) = self { return Int64(d) }; return nil }
            var double: Double? { if case .double(let v) = self { return v }; if case .int(let i) = self { return Double(i) }; return nil }
            var text: String? { if case .text(let v) = self { return v }; return nil }
        }
        private var handle: OpaquePointer?
        private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        init(_ url: URL, readOnly: Bool) throws {
            let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
            guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
                defer { sqlite3_close(handle) }
                throw Failure.sql(String(cString: sqlite3_errmsg(handle)))
            }
            sqlite3_busy_timeout(handle, 3000)
        }
        deinit { sqlite3_close(handle) }

        private func prepare(_ sql: String, _ args: [Value]) throws -> OpaquePointer? {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &st, nil) == SQLITE_OK else { throw Failure.sql(String(cString: sqlite3_errmsg(handle))) }
            for (i, a) in args.enumerated() {
                let n = Int32(i + 1)
                switch a {
                case .int(let v): sqlite3_bind_int64(st, n, v)
                case .double(let v): sqlite3_bind_double(st, n, v)
                case .text(let v): sqlite3_bind_text(st, n, v, -1, Self.transient)
                case .null: sqlite3_bind_null(st, n)
                }
            }
            return st
        }

        func rows(_ sql: String, _ args: [Value] = []) throws -> [[Value]] {
            let st = try prepare(sql, args)
            defer { sqlite3_finalize(st) }
            var out: [[Value]] = []
            while true {
                let rc = sqlite3_step(st)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw Failure.sql(String(cString: sqlite3_errmsg(handle))) }
                out.append((0..<sqlite3_column_count(st)).map { c in
                    switch sqlite3_column_type(st, c) {
                    case SQLITE_INTEGER: return .int(sqlite3_column_int64(st, c))
                    case SQLITE_FLOAT: return .double(sqlite3_column_double(st, c))
                    case SQLITE_TEXT, SQLITE_BLOB:
                        return sqlite3_column_text(st, c).map { .text(String(cString: $0)) } ?? .null
                    default: return .null
                    }
                })
            }
            return out
        }

        @discardableResult func run(_ sql: String, _ args: [Value] = []) throws -> Int {
            let st = try prepare(sql, args)
            defer { sqlite3_finalize(st) }
            guard sqlite3_step(st) == SQLITE_DONE else { throw Failure.sql(String(cString: sqlite3_errmsg(handle))) }
            return Int(sqlite3_changes(handle))
        }

        func exec(_ sql: String) throws {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.sql(String(cString: sqlite3_errmsg(handle))) }
        }
    }
}
#endif
