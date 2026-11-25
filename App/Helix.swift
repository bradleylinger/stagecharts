import Foundation

// Line 6 Helix Native presets (.hlx) made by Claude from a description.
//
// An .hlx file is JSON ("L6Preset"). Line 6 doesn't publish the format, so StageCharts learns it from the
// user's own exported presets: every amp/effect model they contain, with its full set of parameters, plus
// one Helix Native preset as the skeleton (inputs, outputs, global settings). Claude only picks models
// and values from that catalog; StageCharts assembles the file. The catalog stays in the user's library
// (never in the app's repository).
//
// Snapshots: one preset per set, one snapshot per song (up to 8). Snapshot-controlled values use
// controller 19; StageCharts recalls a snapshot with MIDI CC 69 (value 0 = snapshot 1).

typealias JSON = [String: Any]

enum HelixError: LocalizedError {
    case noPresets, noNativePreset, noCatalog, bad(String)
    var errorDescription: String? {
        switch self {
        case .noPresets: return "No Helix presets (.hlx or .hls) were found in that folder."
        case .noNativePreset: return "None of those presets came from Helix Native. Export at least one preset from Helix Native into the folder."
        case .noCatalog: return "Choose your Helix presets folder in Settings → Helix first."
        case .bad(let m): return m
        }
    }
}

// MARK: - Catalog

/// What StageCharts knows about the user's Helix: models with example settings, and a preset skeleton.
struct HelixCatalog {
    struct Model {
        let id: String
        let type: Int
        /// A real block using this model (all parameters), and any entries it references (e.g. "@cab": "cab0").
        let example: JSON
        let linked: [String: JSON]
        /// Lowest and highest value seen for each number parameter.
        let ranges: [String: (Double, Double)]
        var category: String { HelixCatalog.category(id, type: type) }
    }

    /// A setting's real limits, from Helix Native's own model definitions (res/*.models).
    struct Limit {
        let lo: Double, hi: Double
        /// Some settings have a smaller maximum when the block is stereo (e.g. Simple Delay Time 8 s mono, 4 s stereo).
        let hiStereo: Double?
        func clamp(_ x: Double, stereo: Bool) -> Double { min(max(x, lo), stereo ? (hiStereo ?? hi) : hi) }
    }

    var models: [String: Model] = [:]
    /// Model id → setting → limits. Empty when Helix Native's definitions weren't found.
    var limits: [String: [String: Limit]] = [:]
    /// Model id → Line 6's own name ("Bucket Brigade").
    var names: [String: String] = [:]
    var skeleton: JSON = [:]
    var presetCount = 0
    var scanned = Date()

    static func url(in folder: URL) -> URL { folder.appendingPathComponent("catalog.json") }

    // Models that need things StageCharts can't set up (user IR files, loops, hardware sends, pedals).
    static func usable(_ id: String) -> Bool {
        !["Impulse", "Looper", "FXLoop", "Send", "Return", "VolPan", "WahWah", "Wah", "Variax", "Input", "Output", "AppDSP"]
            .contains { id.localizedCaseInsensitiveContains($0) }
    }

    static func category(_ id: String, type: Int) -> String {
        let n = id.replacingOccurrences(of: "HD2_", with: "")
        let table: [(String, String)] = [
            ("Preamp", "preamp (needs a cab after it)"), ("Cab", "cab"), ("Dist", "drive / boost / fuzz"),
            ("Delay", "delay"), ("DL4", "delay"), ("Reverb", "reverb"), ("Chorus", "modulation"), ("Flanger", "modulation"),
            ("Phaser", "modulation"), ("Tremolo", "modulation"), ("Rotary", "modulation"), ("Vibrato", "modulation"),
            ("Mod", "modulation"), ("Compressor", "compressor"), ("Comp", "compressor"), ("EQ", "EQ"), ("Gate", "noise gate"),
            ("Pitch", "pitch / synth"), ("Poly", "pitch / synth"), ("Synth", "pitch / synth"), ("Filter", "filter"),
            ("MM4", "modulation"),
        ]
        if n.hasPrefix("Amp") { return type == 3 ? "amp with its own cab" : "amp (needs a cab after it)" }
        return table.first { n.hasPrefix($0.0) || n.contains($0.0) }?.1 ?? "effect"
    }

    /// "HD2_AmpPlacaterDirty" → "Placater Dirty".
    static func displayName(_ id: String) -> String {
        if let n = shared?.names[id] { return n }
        var n = id.replacingOccurrences(of: "HD2_", with: "").replacingOccurrences(of: "L6SPB_", with: "")
        for p in ["Amp", "Cab", "Dist", "Delay", "Reverb", "Compressor", "EQ", "Chorus", "Flanger", "Phaser", "Tremolo", "Pitch", "Filter", "Gate"]
            where n.hasPrefix(p) && n.count > p.count { n = String(n.dropFirst(p.count)); break }
        var out = ""
        for (i, c) in n.enumerated() {
            if i > 0, c.isUppercase, let prev = out.last, prev.isLowercase || prev.isNumber { out.append(" ") }
            out.append(c)
        }
        return out.replacingOccurrences(of: "_", with: " ")
    }

    /// The catalog last loaded or scanned (for display names).
    nonisolated(unsafe) static var shared: HelixCatalog?

    // MARK: Scanning

    /// Where Helix Native keeps its model definitions on a Mac.
    static let nativeResources = URL(fileURLWithPath: "/Library/Application Support/Line 6/Helix Native/res", isDirectory: true)

    /// Reads every .hlx / .hls under `folder`, plus Helix Native's model definitions (*.models) — from the folder
    /// if they were copied there, otherwise from Helix Native's own install on this Mac.
    static func scan(_ folder: URL) throws -> HelixCatalog {
        var presets: [JSON] = []
        var definitions: [URL] = []
        let fm = FileManager.default
        let e = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let u = e?.nextObject() as? URL {
            switch u.pathExtension.lowercased() {
            case "hlx":
                if let d = try? Data(contentsOf: u), let j = try? JSONSerialization.jsonObject(with: d) as? JSON { presets.append(j) }
            case "hls":
                if let d = try? Data(contentsOf: u) { presets += setlistPresets(d) }
            case "models":
                definitions.append(u)
            default: break
            }
        }
        guard !presets.isEmpty else { throw HelixError.noPresets }
        var cat = try build(from: presets)
        if definitions.isEmpty {
            definitions = (try? fm.contentsOfDirectory(at: nativeResources, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "models" } ?? []
        }
        cat.readDefinitions(definitions)
        shared = cat
        return cat
    }

    /// Helix Native's *.models files: a JSON array of {symbolicID, name, params: [{symbolicID, valueType, min, max,
    /// max_stereo?, default}], cablink/ircablink (amps), mono/stereo (effects)}. Gives every setting's real limits, and
    /// lets StageCharts use models that none of the player's presets contain, built from Line 6's default settings.
    mutating func readDefinitions(_ files: [URL]) {
        var defs: [String: (file: String, model: JSON)] = [:]
        for u in files {
            guard let d = try? Data(contentsOf: u), let list = try? JSONSerialization.jsonObject(with: d) as? [JSON] else { continue }
            let file = u.deletingPathExtension().lastPathComponent
            for m in list {
                guard let id = m["symbolicID"] as? String else { continue }
                defs[id] = (file, m)
                if let n = m["name"] as? String { names[id] = n }
                var l: [String: Limit] = [:]
                for p in m["params"] as? [JSON] ?? [] {
                    guard let k = p["symbolicID"] as? String, !k.hasPrefix("@"), (p["valueType"] as? Int) != 2,
                          let lo = p["min"].flatMap(Self.number), let hi = p["max"].flatMap(Self.number) else { continue }
                    l[k] = Limit(lo: lo, hi: hi, hiStereo: p["max_stereo"].flatMap(Self.number))
                }
                if !l.isEmpty { limits[id] = l }
            }
        }
        // Models the presets don't contain, from Line 6's defaults. Preamps (they need a separate cab block), cabs on
        // their own, send/returns and I/O are left out.
        let kinds: [String: Int] = ["amp": 3, "delay": 7, "reverb": 7, "distortion": 0, "compressor": 0, "modulation": 0,
                                    "eq": 0, "filter": 0, "pitch-synth": 0, "gate": 0]
        let data = skeleton["data"] as? JSON
        let device = data?["device"] as? Int ?? 2162944
        let version = data?["device_version"] as? Int ?? 0
        // A model newer than the player's Helix Native (per its "devices" list) is left out.
        func supported(_ m: JSON) -> Bool {
            guard let list = m["devices"] as? [JSON],
                  let need = list.first(where: { ($0["id"] as? Int) == device })?["version"] as? String else { return true }
            return Int(need.replacingOccurrences(of: "0x", with: ""), radix: 16).map { $0 <= version } ?? true
        }
        for (id, def) in defs where models[id] == nil && Self.usable(id) && supported(def.model) {
            guard let type = kinds[def.file] else { continue }
            var block = Self.defaults(def.model)
            block["@model"] = id
            block["@type"] = type
            block["@enabled"] = true
            block["@no_snapshot_bypass"] = false
            block["@path"] = 0
            block["@position"] = 0
            var linked: [String: JSON] = [:]
            if def.file == "amp" {
                guard let cabID = def.model["ircablink"] as? String, let cab = defs[cabID], supported(cab.model) else { continue }
                var c = Self.defaults(cab.model)
                c["@model"] = cabID
                c["@enabled"] = true
                linked["cab0"] = c
                block["@cab"] = "cab0"
                block["@bypassvolume"] = block["@bypassvolume"] ?? 1.0
                block["@stereo"] = nil
            } else {
                // Stereo-only models must be placed as stereo.
                block["@stereo"] = (def.model["mono"] as? Bool) == false
                if type == 7 { block["@trails"] = false }
            }
            models[id] = Model(id: id, type: type, example: block, linked: linked, ranges: [:])
        }
    }

    /// A model definition's default settings, typed the way Helix writes them (on/off, whole number or decimal).
    /// Includes "@bypassvolume" for amps; other "@" settings are set by the caller.
    private static func defaults(_ model: JSON) -> JSON {
        var out: JSON = [:]
        for p in model["params"] as? [JSON] ?? [] {
            // Stereo-only settings are kept too: Helix writes them in mono blocks as well.
            guard let k = p["symbolicID"] as? String, let v = p["default"], k == "@bypassvolume" || !k.hasPrefix("@") else { continue }
            switch p["valueType"] as? Int {
            case 2: out[k] = (v as? Bool) ?? ((number(v) ?? 0) != 0)
            case 0: out[k] = Int((number(v) ?? 0).rounded())
            default: out[k] = number(v) ?? 0
            }
        }
        return out
    }

    /// A Helix setlist (.hls): {"encoded_data": base64(zlib(JSON)), …} holding {"presets": […]}.
    static func setlistPresets(_ data: Data) -> [JSON] {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? JSON,
              let enc = j["encoded_data"] as? String, var z = Data(base64Encoded: enc) else { return [] }
        if z.count > 2, z[z.startIndex] == 0x78 { z = z.dropFirst(2) }        // zlib header → raw deflate
        guard let raw = try? (z as NSData).decompressed(using: .zlib) as Data,
              let inner = try? JSONSerialization.jsonObject(with: raw) as? JSON else { return [] }
        return (inner["presets"] as? [JSON]) ?? []
    }

    static func build(from presets: [JSON]) throws -> HelixCatalog {
        var cat = HelixCatalog()
        var ranges: [String: [String: (Double, Double)]] = [:]
        for p in presets {
            let data = (p["data"] as? JSON) ?? p
            guard let tone = data["tone"] as? JSON else { continue }
            cat.presetCount += 1
            if cat.skeleton.isEmpty, (data["device"] as? Int) == 2162944 { cat.skeleton = skeleton(from: p) }
            for dsp in ["dsp0", "dsp1"] {
                guard let blocks = tone[dsp] as? JSON else { continue }
                for (key, value) in blocks where key.hasPrefix("block") {
                    guard let b = value as? JSON, let id = b["@model"] as? String, usable(id) else { continue }
                    for (k, v) in b where !k.hasPrefix("@") {
                        guard let x = number(v) else { continue }
                        let r = ranges[id]?[k] ?? (x, x)
                        ranges[id, default: [:]][k] = (min(r.0, x), max(r.1, x))
                    }
                    if cat.models[id] == nil {
                        var linked: [String: JSON] = [:]
                        if let ref = b["@cab"] as? String, let cab = blocks[ref] as? JSON { linked[ref] = cab }
                        cat.models[id] = Model(id: id, type: b["@type"] as? Int ?? 0, example: b, linked: linked, ranges: [:])
                    }
                }
            }
        }
        guard !cat.models.isEmpty else { throw HelixError.noPresets }
        guard !cat.skeleton.isEmpty else { throw HelixError.noNativePreset }
        for (id, m) in cat.models {
            cat.models[id] = Model(id: id, type: m.type, example: m.example, linked: m.linked, ranges: ranges[id] ?? [:])
        }
        cat.scanned = Date()
        return cat
    }

    /// A Helix Native preset with its blocks, snapshots and controller/footswitch assignments removed.
    private static func skeleton(from p: JSON) -> JSON {
        var p = p
        var data = (p["data"] as? JSON) ?? [:]
        var tone = (data["tone"] as? JSON) ?? [:]
        for dsp in ["dsp0", "dsp1"] {
            if let blocks = tone[dsp] as? JSON {
                tone[dsp] = blocks.filter { k, _ in !k.hasPrefix("block") && !k.hasPrefix("cab") }
            }
        }
        for k in tone.keys where k.hasPrefix("snapshot") || k == "controller" || k == "footswitch" { tone[k] = nil }
        data["tone"] = tone
        p["data"] = data
        return p
    }

    static func number(_ v: Any) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }
    static func isBool(_ v: Any) -> Bool { (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
    static func isInteger(_ v: Any) -> Bool {
        guard let n = v as? NSNumber, !isBool(n) else { return false }
        return !CFNumberIsFloatType(n)
    }

    // MARK: Saving

    func save(in folder: URL) throws {
        var models: JSON = [:]
        for (id, m) in self.models {
            models[id] = ["type": m.type, "example": m.example, "linked": m.linked,
                          "ranges": m.ranges.mapValues { [$0.0, $0.1] }]
        }
        let lim = limits.mapValues { $0.mapValues { l -> [Double] in [l.lo, l.hi] + (l.hiStereo.map { [$0] } ?? []) } }
        let j: JSON = ["models": models, "skeleton": skeleton, "presetCount": presetCount,
                       "scanned": scanned.timeIntervalSince1970, "limits": lim, "names": names]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: j).write(to: Self.url(in: folder), options: .atomic)
    }

    static func load(from folder: URL) -> HelixCatalog? {
        guard let d = try? Data(contentsOf: url(in: folder)), let j = try? JSONSerialization.jsonObject(with: d) as? JSON,
              let models = j["models"] as? JSON, let skeleton = j["skeleton"] as? JSON else { return nil }
        var cat = HelixCatalog()
        cat.skeleton = skeleton
        cat.presetCount = j["presetCount"] as? Int ?? 0
        cat.scanned = Date(timeIntervalSince1970: j["scanned"] as? Double ?? 0)
        cat.names = j["names"] as? [String: String] ?? [:]
        for (id, v) in j["limits"] as? [String: [String: [Double]]] ?? [:] {
            cat.limits[id] = v.compactMapValues { a in
                a.count >= 2 ? Limit(lo: a[0], hi: a[1], hiStereo: a.count > 2 ? a[2] : nil) : nil
            }
        }
        for (id, v) in models {
            guard let m = v as? JSON, let ex = m["example"] as? JSON else { continue }
            let r = (m["ranges"] as? [String: [Double]] ?? [:]).compactMapValues { $0.count == 2 ? ($0[0], $0[1]) : nil }
            cat.models[id] = Model(id: id, type: m["type"] as? Int ?? 0, example: ex,
                                   linked: m["linked"] as? [String: JSON] ?? [:], ranges: r)
        }
        shared = cat
        return cat
    }

    // MARK: For Claude

    /// One line per model: id, kind, and each setting with its example value and the range seen.
    var promptText: String {
        models.values.sorted { ($0.category, $0.id) < ($1.category, $1.id) }.map { m in
            let params = m.example.keys.filter { !$0.hasPrefix("@") }.sorted().map { k -> String in
                let v = m.example[k]!
                if Self.isBool(v) { return "\(k)=\((v as? Bool) == true ? 1 : 0) (on/off)" }
                guard let x = Self.number(v) else { return "\(k)" }
                let r: String
                if let l = limits[m.id]?[k] {          // Helix Native's real limits
                    r = " [\(Self.short(l.lo))…\(Self.short(l.hi))\(l.hiStereo.map { ", stereo max \(Self.short($0))" } ?? "")]"
                } else {
                    r = m.ranges[k].map { $0.0 == $0.1 ? "" : " [seen \(Self.short($0.0))…\(Self.short($0.1))]" } ?? ""
                }
                return "\(k)=\(Self.short(x))\(r)\(Self.isInteger(v) ? " int" : "")"
            }
            let name = names[m.id].map { " (\($0))" } ?? ""
            return "\(m.id)\(name) — \(m.category): " + params.joined(separator: ", ")
        }.joined(separator: "\n")
    }

    static func short(_ x: Double) -> String {
        x == x.rounded() && abs(x) < 1e6 ? String(Int(x)) : String(format: "%.3g", x)
    }
}

extension SongLibrary {
    /// Generated presets and the catalog: the library's "Helix" folder (synced with Google Drive).
    var helixFolder: URL { base.appendingPathComponent("Helix", isDirectory: true) }
}

// MARK: - Claude's design

/// What Claude returns: the chain, the snapshots, and which song uses which snapshot.
struct HelixDesign: Codable {
    struct Setting: Codable { var param: String; var value: Double }
    struct Block: Codable { var model: String; var settings: [Setting]; var why: String? }
    struct SnapshotSetting: Codable { var block: Int; var param: String; var value: Double }
    struct Snapshot: Codable {
        var name: String
        var tempo: Double?
        var enabled: [Bool]
        var settings: [SnapshotSetting]
    }
    struct SongSnapshot: Codable { var song: Int; var snapshot: Int }

    var name: String
    var blocks: [Block]
    var snapshots: [Snapshot]
    var songs: [SongSnapshot]
    var summary: String
}

struct HelixSong {
    let title: String
    let artist: String?
    let key: String?
    let bpm: Int?
    let time: String?
    var note: String
}

enum HelixDesigner {
    static let system = """
    You design guitar presets for Line 6 Helix Native for a worship guitarist. You get a description of the \
    tones wanted, optionally the songs in a set list (with key, BPM and notes), and a catalog of the models \
    this player's Helix Native has, each with its settings, an example value and the range seen in their presets.

    Rules:
    - Use only model ids from the catalog, and only setting names listed for that model. Values are in the \
    same units as the examples (most knobs are 0–1; levels in dB; delay Time in seconds; frequencies in Hz). \
    On/off settings are 1 or 0. Settings marked int must be whole numbers. \
    A range in [lo…hi] is the setting's allowed range: never go outside it ("seen" ranges are only what the player has used). \
    Delay Time ranges differ a lot between models (some analog delays stop at 0.3 s): pick a delay whose Time range covers \
    every song's delay time.
    - One signal chain of at most 8 blocks, in order (e.g. gate/comp → drives → amp → cab → modulation → delay → reverb). \
    An amp marked "needs a cab after it" must be followed by a cab block. Prefer an "amp with its own cab" when available.
    - Snapshots (1–8) switch blocks on/off and change settings between songs or parts. `enabled` has one entry per block. \
    `settings` are only the values that differ from the block's own settings in that snapshot. Names at most 10 characters.
    - Delays: for timed delays set TempoSync1 (and TempoSync2 if present) to 0 and set Time (seconds) from the song's BPM: \
    quarter = 60/BPM, dotted eighth = 0.75 × 60/BPM, eighth = 30/BPM. When songs have different BPMs, give each snapshot its own Time.
    - Set each snapshot's tempo to its song's BPM when known.
    - With a set list: map every song (by index) to a snapshot; songs with the same feel can share one. Without songs, `songs` is empty.
    - Preset name at most 16 characters. `summary`: two or three sentences on the sound and how the snapshots differ.
    - Keep levels sensible: drives and boosts shouldn't add more than ~+6 dB; channel volumes near the examples.
    """

    static let schema: [String: Any] = [
        "type": "object", "additionalProperties": false,
        "required": ["name", "blocks", "snapshots", "songs", "summary"],
        "properties": [
            "name": ["type": "string"],
            "summary": ["type": "string"],
            "blocks": ["type": "array", "items": [
                "type": "object", "additionalProperties": false, "required": ["model", "settings", "why"],
                "properties": [
                    "model": ["type": "string"],
                    "why": ["type": "string"],
                    "settings": ["type": "array", "items": [
                        "type": "object", "additionalProperties": false, "required": ["param", "value"],
                        "properties": ["param": ["type": "string"], "value": ["type": "number"]],
                    ]],
                ],
            ]],
            "snapshots": ["type": "array", "items": [
                "type": "object", "additionalProperties": false, "required": ["name", "tempo", "enabled", "settings"],
                "properties": [
                    "name": ["type": "string"],
                    "tempo": ["type": ["number", "null"]],
                    "enabled": ["type": "array", "items": ["type": "boolean"]],
                    "settings": ["type": "array", "items": [
                        "type": "object", "additionalProperties": false, "required": ["block", "param", "value"],
                        "properties": ["block": ["type": "integer"], "param": ["type": "string"], "value": ["type": "number"]],
                    ]],
                ],
            ]],
            "songs": ["type": "array", "items": [
                "type": "object", "additionalProperties": false, "required": ["song", "snapshot"],
                "properties": ["song": ["type": "integer"], "snapshot": ["type": "integer"]],
            ]],
        ],
    ]

    static func design(description: String, songs: [HelixSong], catalog: HelixCatalog) async throws -> HelixDesign {
        var msg = "<catalog>\n\(catalog.promptText)\n</catalog>\n\n<request>\n\(description)\n</request>\n"
        if !songs.isEmpty {
            msg += "\n<songs>\n"
            for (i, s) in songs.enumerated() {
                var parts = ["\(i). \(s.title)"]
                if let a = s.artist { parts.append("by \(a)") }
                if let k = s.key { parts.append("key \(k)") }
                if let b = s.bpm { parts.append("\(b) BPM") }
                if let t = s.time { parts.append(t) }
                if !s.note.isEmpty { parts.append("note: \(s.note)") }
                msg += parts.joined(separator: " · ") + "\n"
            }
            msg += "</songs>\n"
        }
        let text = try await Claude.ask(system: system, content: [["type": "text", "text": msg]],
                                        effort: "high", schema: schema, maxTokens: 16000)
        guard let d = text.data(using: .utf8) else { throw AIError.empty }
        return try JSONDecoder().decode(HelixDesign.self, from: d)
    }
}

// MARK: - Building the .hlx

enum HelixBuilder {
    struct Result {
        var preset: JSON
        var warnings: [String]
        /// Song index → snapshot index (0-based) after clean-up.
        var songSnapshots: [Int: Int]
        var blocks: [String]
        var snapshotNames: [String]
    }

    static func build(_ design: HelixDesign, catalog: HelixCatalog, songCount: Int) throws -> Result {
        var warnings: [String] = []
        var preset = catalog.skeleton
        var data = preset["data"] as? JSON ?? [:]
        var tone = data["tone"] as? JSON ?? [:]
        var dsp0 = tone["dsp0"] as? JSON ?? [:]

        // Blocks Claude picked that this Helix actually has.
        var kept: [(index: Int, model: HelixCatalog.Model, block: HelixDesign.Block)] = []
        for (i, b) in design.blocks.enumerated() {
            if let m = catalog.models[b.model] { kept.append((i, m, b)) }
            else { warnings.append("Left out \(b.model): it isn't in your Helix presets.") }
        }
        kept = Array(kept.prefix(8))
        guard !kept.isEmpty else { throw HelixError.bad("Claude didn't pick any models from your Helix. Try again.") }
        let newIndex = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($1.index, $0) })

        let snaps = Array(design.snapshots.prefix(8))
        guard !snaps.isEmpty else { throw HelixError.bad("Claude didn't make any snapshots. Try again.") }

        // Values per (block, param) across snapshots, to find which ones snapshots control.
        var perSnapshot: [Int: [String: [Int: Any]]] = [:]       // block → param → snapshot → value
        var cabCount = 0
        for (bi, k) in kept.enumerated() {
            var block = k.model.example
            block["@position"] = bi
            block["@path"] = 0
            block["@enabled"] = snaps[0].enabled.indices.contains(k.index) ? snaps[0].enabled[k.index] : true
            block["@no_snapshot_bypass"] = false
            let stereo = block["@stereo"] as? Bool ?? false
            for s in k.block.settings {
                guard let v = value(s.value, param: s.param, model: k.model, stereo: stereo, catalog: catalog, warnings: &warnings) else {
                    warnings.append("\(HelixCatalog.displayName(k.model.id)): ignored unknown setting \(s.param)."); continue
                }
                block[s.param] = v
            }
            if let ref = block["@cab"] as? String, let cab = k.model.linked[ref] {
                let name = "cab\(cabCount)"; cabCount += 1
                block["@cab"] = name
                dsp0[name] = cab
            }
            dsp0["block\(bi)"] = block
        }
        for (si, s) in snaps.enumerated() {
            for st in s.settings {
                guard let bi = newIndex[st.block] else { continue }
                let stereo = (dsp0["block\(bi)"] as? JSON)?["@stereo"] as? Bool ?? false
                guard let v = value(st.value, param: st.param, model: kept[bi].model, stereo: stereo, catalog: catalog,
                                    warnings: &warnings, snapshot: clean(s.name, max: 10)) else { continue }
                perSnapshot[bi, default: [:]][st.param, default: [:]][si] = v
            }
        }

        // Snapshot-controlled values (controller 19): any setting a snapshot changes.
        var controller: JSON = [:]
        var controlled: [Int: [String: [Any]]] = [:]          // block → param → value per snapshot
        for (bi, params) in perSnapshot {
            var bc: JSON = [:]
            for (p, bySnap) in params {
                let base = (dsp0["block\(bi)"] as? JSON)?[p] ?? 0
                let values = snaps.indices.map { bySnap[$0] ?? base }
                controlled[bi, default: [:]][p] = values
                if var block = dsp0["block\(bi)"] as? JSON {      // the block itself shows snapshot 1's value
                    block[p] = values[0]; dsp0["block\(bi)"] = block
                }
                let nums = values.compactMap { HelixCatalog.number($0) }
                var entry: JSON = ["@controller": 19, "@snapshot_disable": false]
                if HelixCatalog.isBool(base) {
                    entry["@min"] = false; entry["@max"] = true
                } else {
                    let stereo = (dsp0["block\(bi)"] as? JSON)?["@stereo"] as? Bool ?? false
                    if let l = catalog.limits[kept[bi].model.id]?[p] {      // Helix Native's own range
                        entry["@min"] = l.lo
                        entry["@max"] = stereo ? (l.hiStereo ?? l.hi) : l.hi
                    } else {
                        let r = kept[bi].model.ranges[p] ?? (nums.min() ?? 0, nums.max() ?? 1)
                        let lo = min(r.0, nums.min() ?? r.0), hi = max(r.1, nums.max() ?? r.1)
                        let unit = lo >= 0 && hi <= 1          // most knobs are 0–1: give the snapshot the full range
                        entry["@min"] = unit ? 0.0 : lo
                        entry["@max"] = unit ? 1.0 : hi
                    }
                }
                bc[p] = entry
            }
            if !bc.isEmpty { controller["block\(bi)"] = bc }
        }
        tone["dsp0"] = dsp0
        if !controller.isEmpty { tone["controller"] = ["dsp0": controller] }

        // Snapshots 1–8 (unused ones are copies of the first, marked not valid).
        var names: [String] = []
        for si in 0..<8 {
            let s = si < snaps.count ? snaps[si] : snaps[0]
            var blocks: JSON = [:]
            for (bi, k) in kept.enumerated() {
                blocks["block\(bi)"] = s.enabled.indices.contains(k.index) ? s.enabled[k.index] : true
            }
            var ctl: JSON = [:]
            for (bi, params) in controlled {
                var b: JSON = [:]
                for (p, values) in params { b[p] = ["@fs_enabled": false, "@value": values[si < snaps.count ? si : 0]] }
                ctl["block\(bi)"] = b
            }
            let name = si < snaps.count ? clean(s.name, max: 10) : "SNAPSHOT \(si + 1)"
            if si < snaps.count { names.append(name) }
            var snap: JSON = ["@name": name, "@custom_name": si < snaps.count, "@valid": si < snaps.count,
                              "@ledcolor": 0, "@pedalstate": 2, "@tempo": s.tempo ?? 120.0,
                              "blocks": ["dsp0": blocks]]
            if !ctl.isEmpty { snap["controllers"] = ["dsp0": ctl] }
            tone["snapshot\(si)"] = snap
        }
        if var global = tone["global"] as? JSON {
            global["@current_snapshot"] = 0
            global["@cursor_dsp"] = 0
            global["@cursor_group"] = "block0"
            global["@tempo"] = snaps[0].tempo ?? 120.0
            tone["global"] = global
        }
        data["tone"] = tone
        var meta = data["meta"] as? JSON ?? [:]
        meta["name"] = clean(design.name, max: 16)
        meta["modifieddate"] = Int(Date().timeIntervalSince1970)
        meta["author"] = "StageCharts"
        data["meta"] = meta
        preset["data"] = data

        var map: [Int: Int] = [:]
        for s in design.songs where s.song >= 0 && s.song < songCount {
            map[s.song] = min(max(0, s.snapshot), snaps.count - 1)
        }
        return Result(preset: preset, warnings: warnings, songSnapshots: map,
                      blocks: kept.map { HelixCatalog.displayName($0.model.id) }, snapshotNames: names)
    }

    /// Claude's number as the parameter's own type (on/off, whole number or decimal); nil for unknown settings.
    /// Values outside Helix Native's limits are pulled inside them (Helix would clamp them anyway), with a warning.
    private static func value(_ x: Double, param: String, model: HelixCatalog.Model, stereo: Bool, catalog: HelixCatalog,
                              warnings: inout [String], snapshot: String? = nil) -> Any? {
        guard let example = model.example[param], !param.hasPrefix("@") else { return nil }
        if HelixCatalog.isBool(example) { return x >= 0.5 }
        var x = x
        if let l = catalog.limits[model.id]?[param] {
            let c = l.clamp(x, stereo: stereo)
            if abs(c - x) > 1e-9 {
                let w = "\(HelixCatalog.displayName(model.id)) \(param)\(snapshot.map { " (\($0))" } ?? ""): "
                    + "\(HelixCatalog.short(x)) is outside its range, so it's set to \(HelixCatalog.short(c))."
                warnings.append(w)
                x = c
            }
        }
        if HelixCatalog.isInteger(example) { return Int(x.rounded()) }
        return x
    }

    /// Helix names: limited length and characters.
    static func clean(_ s: String, max: Int) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_+=!@#$&()?:'\",./ ")
        let t = String(s.filter { allowed.contains($0) }.prefix(max)).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "StageCharts" : t
    }

    /// Writes the preset into the library's Helix folder; returns the file.
    static func save(_ preset: JSON, name: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent(clean(name, max: 40) + ".hlx")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(clean(name, max: 40) + " \(n).hlx"); n += 1
        }
        let d = try JSONSerialization.data(withJSONObject: preset, options: [.prettyPrinted, .sortedKeys])
        try d.write(to: url, options: .atomic)
        return url
    }
}
