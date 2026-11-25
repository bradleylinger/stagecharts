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
    /// Model id → [can run mono, can run stereo], from Helix Native's definitions.
    var channels: [String: [Bool]] = [:]
    /// Model id → setting → expression pedal assignment from the player's presets (e.g. volume "Pedal" on EXP 2).
    var pedals: [String: [String: JSON]] = [:]
    var skeleton: JSON = [:]
    var presetCount = 0
    var scanned = Date()

    static func url(in folder: URL) -> URL { folder.appendingPathComponent("catalog.json") }

    // Models that need things StageCharts can't set up (user IR files, loops, hardware sends and inputs).
    static func usable(_ id: String) -> Bool {
        !["Impulse", "Looper", "FXLoop", "Send", "Return", "Variax", "Input", "Output", "AppDSP"]
            .contains { id.localizedCaseInsensitiveContains($0) }
    }

    static func category(_ id: String, type: Int) -> String {
        let n = id.replacingOccurrences(of: "HD2_", with: "")
        let table: [(String, String)] = [
            ("Preamp", "preamp (needs a cab after it)"), ("VolPan", "volume / pan"), ("Wah", "wah (on a pedal)"), ("Cab", "cab"), ("Dist", "drive / boost / fuzz"),
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
                if m["mono"] != nil || m["stereo"] != nil {
                    channels[id] = [(m["mono"] as? Bool) ?? true, (m["stereo"] as? Bool) ?? true]
                }
                var l: [String: Limit] = [:]
                for p in m["params"] as? [JSON] ?? [] {
                    guard let k = p["symbolicID"] as? String, !k.hasPrefix("@"), (p["valueType"] as? Int) != 2,
                          let lo = p["min"].flatMap(Self.number), let hi = p["max"].flatMap(Self.number) else { continue }
                    l[k] = Limit(lo: lo, hi: hi, hiStereo: p["max_stereo"].flatMap(Self.number))
                }
                if !l.isEmpty { limits[id] = l }
            }
        }
        // Models the presets don't contain, from Line 6's defaults: amps (with their matching cab), preamps, single
        // cabs (type 2) and every kind of effect. Send/returns, I/O and the older cab and dual-cab formats are left out.
        let kinds: [String: Int] = ["amp": 3, "preamp": 1, "cabmicirs": 2, "delay": 7, "reverb": 7, "distortion": 0,
                                    "compressor": 0, "modulation": 0, "eq": 0, "filter": 0, "pitch-synth": 0, "gate": 0,
                                    "wah": 0, "volumepan": 0]
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
            } else if type == 1 {
                block["@bypassvolume"] = block["@bypassvolume"] ?? 1.0
                block["@stereo"] = nil
            } else if type == 2 {
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
        // Pedal assignments in the player's Helix Native presets (hardware Helix presets use EXP inputs Native doesn't have).
        for p in presets {
            let data = (p["data"] as? JSON) ?? p
            guard (data["device"] as? Int) == 2162944 else { continue }
            let tone = (data["tone"] as? JSON) ?? [:]
            for (dsp, v) in tone["controller"] as? JSON ?? [:] {
                for (key, params) in v as? JSON ?? [:] {
                    guard let id = ((tone[dsp] as? JSON)?[key] as? JSON)?["@model"] as? String else { continue }
                    for (param, c) in params as? JSON ?? [:] {
                        // Only MIDI CC (18): Helix Native has no EXP inputs, so EXP 1–3 entries do nothing there.
                        guard let c = c as? JSON, (c["@controller"] as? Int) == 18, cat.pedals[id]?[param] == nil else { continue }
                        cat.pedals[id, default: [:]][param] = c.filter { ["@controller", "@cc", "@min", "@max"].contains($0.key) }
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
                       "scanned": scanned.timeIntervalSince1970, "limits": lim, "names": names, "pedals": pedals, "channels": channels]
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
        cat.pedals = j["pedals"] as? [String: [String: JSON]] ?? [:]
        cat.channels = j["channels"] as? [String: [Bool]] ?? [:]
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

    /// The expression pedal a block's settings follow: what the player's presets use for this model, else for the
    /// same kind of model. Helix Native's own Knob/Switch automation assignments aren't saved in preset files, so
    /// usually there's nothing to copy and the player assigns the pedal in Helix Native.
    /// Only wahs and volume pedals: other pedal assignments in the player's presets (e.g. a reverb mix on a pedal)
    /// belong to those presets, not to every new one.
    func pedalAssignments(for id: String) -> [String: JSON] {
        guard let m = models[id] else { return [:] }
        let isVolume = id.hasPrefix("HD2_VolPanVol")
        guard isVolume || m.category.hasPrefix("wah") else { return [:] }
        if let p = pedals[id] { return p }
        let kind = isVolume ? "volume" : m.category
        if let similar = pedals.first(where: { k, _ in
            k.hasPrefix("HD2_VolPanVol") == isVolume && (isVolume || models[k]?.category == kind) })?.value,
           similar.keys.allSatisfy({ m.example[$0] != nil }) {
            return similar
        }
        return [:]
    }

    /// A cab model as the cab inside an amp block (amp + cab): its settings, model and on/off only.
    func linkedCab(_ id: String) -> JSON? {
        guard let m = models[id], m.type == 2 else { return nil }
        return m.example.filter { k, _ in !k.hasPrefix("@") || k == "@model" || k == "@enabled" }
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
            var kind = m.category
            if m.example["@stereo"] != nil {
                switch channels[m.id] {
                case [true, false]?: kind += ", mono only"
                case [false, true]?: kind += ", stereo only"
                default: kind += ", mono or stereo"
                }
            }
            return "\(m.id)\(name) — \(kind): " + params.joined(separator: ", ")
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
    struct Block: Codable {
        var model: String
        var settings: [Setting]
        var why: String?
        /// For an amp with its own cab: a different cab model to use in place of its matching one.
        var cab: String? = nil
        /// "series", or "A" / "B" for the two parallel paths between a split and its merge.
        var lane: String? = nil
        /// true = stereo, false = mono, nil = the model's usual.
        var stereo: Bool? = nil
    }
    /// How the two parallel paths are merged: levels in dB, pans 0 (left)…1 (right), B's polarity flipped.
    struct Paths: Codable { var levelA: Double; var panA: Double; var levelB: Double; var panB: Double; var invertB: Bool }
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
    var paths: Paths? = nil
}

extension HelixDesign {
    /// The design with `model` as its first block, on in every snapshot (any other block of that model is removed).
    func withBlockFirst(_ model: String) -> HelixDesign {
        var d = self
        let keep = blocks.indices.filter { blocks[$0].model != model }
        var newIndex: [Int: Int] = [:]
        for (n, old) in keep.enumerated() { newIndex[old] = n + 1 }
        d.blocks = [Block(model: model, settings: [], why: "Your volume pedal", lane: "series")] + keep.map { blocks[$0] }
        d.snapshots = snapshots.map { s in
            var s = s
            s.enabled = [true] + keep.map { s.enabled.indices.contains($0) ? s.enabled[$0] : true }
            s.settings = s.settings.compactMap { st in
                guard let n = newIndex[st.block] else { return nil }
                var st = st; st.block = n; return st
            }
            return s
        }
        return d
    }
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
    - Blocks are listed in signal order (e.g. gate/comp → drives → amp → cab → modulation → delay → reverb). Each block's \
    `lane` is "series" for the main chain. For parallel sounds (two amps, a wet/dry rig, a pitch or reverb blended in \
    beside the dry signal) give consecutive blocks lane "A" or "B": the signal splits before the first of them and \
    merges after the last, and series blocks after them come after the merge. Use at most one split. Set `paths` \
    (merge levels in dB, usually 0; pans 0 = left, 0.5 = centre, 1 = right; invertB false) when there is a "B" \
    block, otherwise null. The chain has 8 positions: blocks before the split + the longer of A and B + blocks after \
    the merge must be at most 8.
    - `stereo`: for a model marked "mono or stereo", true or false to choose, null for its usual. Amps and cabs are \
    mono. Stereo effects after the merge keep a panned A/B spread; a mono block there collapses it to the centre.
    An amp or preamp marked "needs a cab after it" must be followed by a cab block. An "amp with its own cab" comes with \
    its matching cab; to pair it with a different cab instead, set the block's `cab` to that cab's model id (a "cab" from \
    the catalog) — this uses no extra block. Otherwise `cab` is null. Mixing a preamp or amp with a cab it isn't \
    usually paired with is fine when it suits the tone.
    - Wahs and volume pedals are played with the player's expression pedal; their Pedal setting is only where it \
    starts. When the request says the player's volume pedal is added automatically, don't add a volume pedal, and \
    use at most 7 positions.
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
        "required": ["name", "blocks", "snapshots", "songs", "summary", "paths"],
        "properties": [
            "name": ["type": "string"],
            "paths": ["type": ["object", "null"], "additionalProperties": false,
                      "required": ["levelA", "panA", "levelB", "panB", "invertB"],
                      "properties": ["levelA": ["type": "number"], "panA": ["type": "number"], "levelB": ["type": "number"],
                                     "panB": ["type": "number"], "invertB": ["type": "boolean"]]],
            "summary": ["type": "string"],
            "blocks": ["type": "array", "items": [
                "type": "object", "additionalProperties": false, "required": ["model", "settings", "why", "cab", "lane", "stereo"],
                "properties": [
                    "model": ["type": "string"],
                    "lane": ["type": "string", "enum": ["series", "A", "B"]],
                    "stereo": ["type": ["boolean", "null"]],
                    "why": ["type": "string"],
                    "cab": ["type": ["string", "null"]],
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

    static func design(description: String, songs: [HelixSong], catalog: HelixCatalog,
                       volumePedal: Bool = false) async throws -> HelixDesign {
        var msg = "<catalog>\n\(catalog.promptText)\n</catalog>\n\n<request>\n\(description)\n</request>\n"
        if volumePedal {
            msg += "\nThe player's volume pedal (on their expression pedal) is added automatically as the first block.\n"
        }
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

    /// The volume pedal StageCharts puts first when the player asks for one: their own, else Helix's Volume Pedal.
    static func volumeModel(_ catalog: HelixCatalog) -> String? {
        ["HD2_VolPanVol", "HD2_VolPanVolStereo"].first { catalog.models[$0] != nil }
            ?? catalog.models.keys.sorted().first { $0.hasPrefix("HD2_VolPanVol") }
    }

    static func build(_ design: HelixDesign, catalog: HelixCatalog, songCount: Int, volumePedal: Bool = false) throws -> Result {
        var warnings: [String] = []
        var design = design
        if volumePedal {
            if let v = volumeModel(catalog) { design = design.withBlockFirst(v) }
            else { warnings.append("Your Helix presets don't include a volume pedal, so none was added.") }
        }
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
        guard !kept.isEmpty else { throw HelixError.bad("Claude didn't pick any models from your Helix. Try again.") }

        // Layout: series blocks before the split, paths A and B side by side, series blocks after the merge.
        typealias Kept = (index: Int, model: HelixCatalog.Model, block: HelixDesign.Block)
        let parallel = kept.contains { $0.block.lane == "B" }
        let firstParallel = parallel ? kept.firstIndex { $0.block.lane == "A" || $0.block.lane == "B" } : nil
        var pre: [Kept] = [], laneA: [Kept] = [], laneB: [Kept] = [], post: [Kept] = []
        for (i, k) in kept.enumerated() {
            switch (parallel ? k.block.lane : nil) {
            case "A"?: laneA.append(k)
            case "B"?: laneB.append(k)
            default: if let f = firstParallel, i > f { post.append(k) } else { pre.append(k) }
            }
        }
        while pre.count + max(laneA.count, laneB.count) + post.count > 8 {
            let dropped: Kept
            if !post.isEmpty { dropped = post.removeLast() }
            else if laneA.count >= laneB.count, !laneA.isEmpty { dropped = laneA.removeLast() }
            else if !laneB.isEmpty { dropped = laneB.removeLast() }
            else { dropped = pre.removeLast() }
            warnings.append("Left out \(HelixCatalog.displayName(dropped.model.id)): the chain only has 8 positions.")
        }
        if laneB.isEmpty { pre += laneA + post; laneA = []; post = [] }       // no path B: one straight chain
        let width = max(laneA.count, laneB.count)
        let splitAt = laneB.isEmpty ? 0 : pre.count
        let joinAt = laneB.isEmpty ? 8 : pre.count + width
        var place: [(path: Int, position: Int)] = pre.indices.map { (0, $0) }
        place += laneA.indices.map { (0, pre.count + $0) } + laneB.indices.map { (1, pre.count + $0) }
        place += post.indices.map { (0, joinAt + $0) }
        kept = pre + laneA + laneB + post
        let newIndex = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($1.index, $0) })

        let snaps = Array(design.snapshots.prefix(8))
        guard !snaps.isEmpty else { throw HelixError.bad("Claude didn't make any snapshots. Try again.") }

        // Values per (block, param) across snapshots, to find which ones snapshots control.
        var perSnapshot: [Int: [String: [Int: Any]]] = [:]       // block → param → snapshot → value
        var cabCount = 0
        for (bi, k) in kept.enumerated() {
            var block = k.model.example
            block["@position"] = place[bi].position
            block["@path"] = place[bi].path
            block["@enabled"] = snaps[0].enabled.indices.contains(k.index) ? snaps[0].enabled[k.index] : true
            block["@no_snapshot_bypass"] = false
            if let want = k.block.stereo, block["@stereo"] != nil {
                let can = catalog.channels[k.model.id] ?? [true, true]
                if can[want ? 1 : 0] { block["@stereo"] = want }
                else { warnings.append("\(HelixCatalog.displayName(k.model.id)) only runs \(want ? "mono" : "stereo"), so it stays that way.") }
            }
            let stereo = block["@stereo"] as? Bool ?? false
            for s in k.block.settings {
                guard let v = value(s.value, param: s.param, model: k.model, stereo: stereo, catalog: catalog, warnings: &warnings) else {
                    warnings.append("\(HelixCatalog.displayName(k.model.id)): ignored unknown setting \(s.param)."); continue
                }
                block[s.param] = v
            }
            if let ref = block["@cab"] as? String, var cab = k.model.linked[ref] {
                if let other = k.block.cab, other != cab["@model"] as? String {
                    if let c = catalog.linkedCab(other) { cab = c; cab["@enabled"] = true }
                    else { warnings.append("\(HelixCatalog.displayName(k.model.id)): kept its own cab (\(other) isn't a cab in your Helix).") }
                }
                let name = "cab\(cabCount)"; cabCount += 1
                block["@cab"] = name
                dsp0[name] = cab
            } else if let other = k.block.cab, !other.isEmpty {
                warnings.append("\(HelixCatalog.displayName(k.model.id)) has no cab of its own, so \(HelixCatalog.displayName(other)) wasn't used.")
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
        // Expression pedals (wahs, volume): the player's own assignments. A snapshot-controlled setting can't also follow a pedal.
        for (bi, k) in kept.enumerated() {
            let assigned = catalog.pedalAssignments(for: k.model.id)
            if assigned.isEmpty, k.model.id.hasPrefix("HD2_VolPanVol") || k.model.category.hasPrefix("wah") {
                warnings.append("In Helix Native, assign \(HelixCatalog.displayName(k.model.id))'s Position to the knob your pedal "
                                + "controls (Controller Assign, e.g. Knob 1): preset files can't carry that assignment.")
            }
            for (p, entry) in assigned {
                var bc = controller["block\(bi)"] as? JSON ?? [:]
                if bc[p] != nil {
                    warnings.append("\(HelixCatalog.displayName(k.model.id)) \(p) changes with snapshots, so it isn't on your expression pedal.")
                    continue
                }
                var e = entry
                e["@snapshot_disable"] = false
                bc[p] = e
                controller["block\(bi)"] = bc
            }
        }
        // The split and merge (always present in Helix; at the ends of the chain when path B isn't used).
        let pj = design.paths ?? .init(levelA: 0, panA: 0.5, levelB: 0, panB: 0.5, invertB: false)
        func level(_ x: Double) -> Double { min(max(x, -60), 12) }
        func pan(_ x: Double) -> Double { min(max(x, 0), 1) }
        dsp0["split"] = ["@enabled": true, "@model": "HD2_AppDSPFlowSplitY", "@position": splitAt,
                         "BalanceA": 0.5, "BalanceB": 0.5, "bypass": false]
        dsp0["join"] = ["@enabled": true, "@model": "HD2_AppDSPFlowJoin", "@position": joinAt,
                        "A Level": laneB.isEmpty ? 0.0 : level(pj.levelA), "A Pan": laneB.isEmpty ? 0.5 : pan(pj.panA),
                        "B Level": laneB.isEmpty ? 0.0 : level(pj.levelB), "B Pan": laneB.isEmpty ? 0.5 : pan(pj.panB),
                        "B Polarity": laneB.isEmpty ? false : pj.invertB, "Level": 0.0]
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
            blocks["split"] = true          // Helix Native saves the split's on/off in every snapshot
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
            global["@topology0"] = laneB.isEmpty ? "A" : "SABJ"
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
