import Foundation
import CoreMIDI

/// One MIDI thru route, like an Ableton MIDI track with "MIDI From" → "MIDI To":
/// channel messages from an input (optionally one channel) go to an output (optionally on another channel).
struct MIDIRoute: Codable, Identifiable, Hashable {
    var id = UUID()
    var enabled = true
    /// Input endpoint unique ID; 0 = any input.
    var sourceID: Int32 = 0
    var sourceName = "Any input"
    /// 0 = all channels, else 1…16.
    var inChannel = 0
    /// Output endpoint unique ID; `MIDIRoute.appsOutput` = StageCharts' own output that other apps on this device listen to.
    var destID: Int32 = 0
    var destName = ""
    /// 0 = keep the incoming channel, else 1…16.
    var outChannel = 0
    /// The user's names for each end, e.g. "Helix" → "FOH laptop" (empty = use the device name).
    var sourceLabel = ""
    var destLabel = ""

    static let appsOutput: Int32 = -2

    init() {}

    var fromTitle: String { sourceLabel.isEmpty ? sourceName : sourceLabel }
    var toTitle: String { destLabel.isEmpty ? destName : destLabel }
    var inChannelText: String { inChannel == 0 ? "All channels" : "Ch. \(inChannel)" }
    var outChannelText: String { outChannel == 0 ? "Same channel" : "Ch. \(outChannel)" }

    var summary: String {
        let from = fromTitle + (inChannel == 0 ? "" : " ch \(inChannel)")
        let to = toTitle + (outChannel == 0 ? "" : " ch \(outChannel)")
        return "\(from) → \(to)"
    }

    // Routes saved before labels existed still load.
    private enum CodingKeys: String, CodingKey {
        case id, enabled, sourceID, sourceName, inChannel, destID, destName, outChannel, sourceLabel, destLabel
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        sourceID = try c.decodeIfPresent(Int32.self, forKey: .sourceID) ?? 0
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? "Any input"
        inChannel = try c.decodeIfPresent(Int.self, forKey: .inChannel) ?? 0
        destID = try c.decodeIfPresent(Int32.self, forKey: .destID) ?? 0
        destName = try c.decodeIfPresent(String.self, forKey: .destName) ?? ""
        outChannel = try c.decodeIfPresent(Int.self, forKey: .outChannel) ?? 0
        sourceLabel = try c.decodeIfPresent(String.self, forKey: .sourceLabel) ?? ""
        destLabel = try c.decodeIfPresent(String.self, forKey: .destLabel) ?? ""
    }
}

/// One channel message seen by the router: where it came from and which routes sent it where.
struct MIDIActivity: Identifiable {
    struct Send { let routeID: UUID; let word: UInt32 }
    let id: Int              // sequence number
    let time: Date
    let sourceID: Int32
    let word: UInt32         // as received (UMP type 2)
    let sends: [Send]        // empty = not routed

    /// "Note on C4 vel 100", "CC 64 = 127", "Program 5", …  (channel shown separately)
    static func describe(_ w: UInt32) -> String {
        let status = (w >> 20) & 0xF, d1 = Int((w >> 8) & 0x7F), d2 = Int(w & 0x7F)
        switch status {
        case 0x8: return "Note off \(noteName(d1))"
        case 0x9: return d2 == 0 ? "Note off \(noteName(d1))" : "Note on \(noteName(d1)) vel \(d2)"
        case 0xA: return "Aftertouch \(noteName(d1)) \(d2)"
        case 0xB: return "CC \(d1) = \(d2)"
        case 0xC: return "Program \(d1 + 1)"
        case 0xD: return "Channel pressure \(d1)"
        case 0xE: return "Pitch bend \((d2 << 7 | d1) - 8192)"
        default: return String(format: "%08X", w)
        }
    }
    static func channel(_ w: UInt32) -> Int { Int((w >> 16) & 0xF) + 1 }
    static func noteName(_ n: Int) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return "\(names[n % 12])\(n / 12 - 1)"
    }
}

/// A MIDI endpoint as shown in pickers.
struct MIDIEndpointInfo: Hashable, Identifiable {
    let id: Int32        // kMIDIPropertyUniqueID
    let name: String     // with how it's connected, e.g. "WIDI Jack · Bluetooth"
}

/// Applies the routes on the MIDI receive thread (no hop to the main thread, so routing adds no lag).
final class MIDIRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [MIDIRoute] = []
    private var destinations: [Int32: MIDIEndpointRef] = [:]
    private var port = MIDIPortRef()
    private var appsOutput = MIDIEndpointRef()
    // Activity for the monitor: the last messages plus per-route / per-input totals.
    private var recent: [MIDIActivity] = []
    private var seq = 0
    private var routeCounts: [UUID: Int] = [:]
    private var routeLast: [UUID: Date] = [:]
    private var sourceLast: [Int32: Date] = [:]
    private static let keep = 200

    struct Snapshot {
        var seq = 0
        var recent: [MIDIActivity] = []
        var routeCounts: [UUID: Int] = [:]
        var routeLast: [UUID: Date] = [:]
        var sourceLast: [Int32: Date] = [:]
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(seq: seq, recent: recent, routeCounts: routeCounts, routeLast: routeLast, sourceLast: sourceLast)
    }
    func clearActivity() {
        lock.lock(); recent = []; routeCounts = [:]; routeLast = [:]; sourceLast = [:]; seq += 1; lock.unlock()
    }

    func configure(port: MIDIPortRef, appsOutput: MIDIEndpointRef) {
        lock.lock(); self.port = port; self.appsOutput = appsOutput; lock.unlock()
    }
    func setRoutes(_ r: [MIDIRoute]) { lock.lock(); routes = r.filter(\.enabled); lock.unlock() }
    func setDestinations(_ d: [Int32: MIDIEndpointRef]) { lock.lock(); destinations = d; lock.unlock() }

    /// `sourceID` is the unique ID of the input the list came from (nil: an app sent to StageCharts directly).
    func route(_ list: UnsafePointer<MIDIEventList>, sourceID: Int32?) {
        lock.lock()
        let active = routes.filter { $0.sourceID == 0 ? sourceID != nil : $0.sourceID == sourceID }
        let (port, apps, dests) = (port, appsOutput, destinations)
        lock.unlock()

        // MIDI 1.0 channel-voice words (UMP type 2); the channel is the low nibble of the status byte.
        var words: [UInt32] = []
        for packet in list.unsafeSequence() {
            let count = Int(packet.pointee.wordCount)
            withUnsafeBytes(of: packet.pointee.words) { raw in
                let w = raw.bindMemory(to: UInt32.self)
                var i = 0
                while i < count {
                    let type = w[i] >> 28
                    if type == 0x2 { words.append(w[i]) }
                    switch type { case 0x3, 0x4: i += 2; case 0x5: i += 4; default: i += 1 }
                }
            }
        }
        guard !words.isEmpty else { return }
        var sent: [[MIDIActivity.Send]] = Array(repeating: [], count: words.count)

        for r in active {
            var out: [UInt32] = []
            for (i, w) in words.enumerated() {
                let ch = Int((w >> 16) & 0x0F) + 1
                if r.inChannel != 0 && ch != r.inChannel { continue }
                let o = r.outChannel == 0 ? w & 0xF0FF_FFFF                  // group 0, same channel
                    : (w & 0xF0F0_FFFF) | (UInt32(r.outChannel - 1) << 16)
                out.append(o)
                sent[i].append(.init(routeID: r.id, word: o))
            }
            // A MIDIEventList holds one packet of up to 64 words; send in chunks.
            for start in stride(from: 0, to: out.count, by: 60) {
                var chunk = Array(out[start..<min(start + 60, out.count)])
                var list = MIDIEventList()
                let packet = MIDIEventListInit(&list, ._1_0)
                _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, chunk.count, &chunk)
                if r.destID == MIDIRoute.appsOutput {
                    if apps != 0 { MIDIReceivedEventList(apps, &list) }
                } else if let d = dests[r.destID] {
                    MIDISendEventList(port, d, &list)
                }
            }
        }

        let now = Date()
        lock.lock()
        for (i, w) in words.enumerated() {
            seq += 1
            recent.append(MIDIActivity(id: seq, time: now, sourceID: sourceID ?? 0, word: w, sends: sent[i]))
            for s in sent[i] { routeCounts[s.routeID, default: 0] += 1; routeLast[s.routeID] = now }
        }
        if recent.count > Self.keep { recent.removeFirst(recent.count - Self.keep) }
        if let sourceID { sourceLast[sourceID] = now }
        lock.unlock()
    }
}

#if canImport(SwiftUI)
import SwiftUI

/// Settings → MIDI routes.
struct MIDIRoutesSection: View {
    @ObservedObject var midi: MIDIController
    @State private var editing: MIDIRoute?

    var body: some View {
        Section {
            ForEach($midi.routes) { $r in
                HStack {
                    Toggle(isOn: $r.enabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.summary).lineLimit(2)
                            if !r.sourceLabel.isEmpty || !r.destLabel.isEmpty {
                                Text("\(r.sourceName) → \(r.destName)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Edit") { editing = r }.buttonStyle(.borderless)
                }
            }
            .onDelete { midi.routes.remove(atOffsets: $0) }
            // The sheet hangs off this one row: on a Section it would be attached to every row.
            Button("Add route…") { editing = newRoute() }
                .sheet(item: $editing) { r in
                    MIDIRouteEditor(route: r, inputs: midi.inputs, outputs: midi.outputs) { saved in
                        if let i = midi.routes.firstIndex(where: { $0.id == saved.id }) { midi.routes[i] = saved }
                        else { midi.routes.append(saved) }
                    }
                }
        } header: {
            Text("MIDI routes")
        } footer: {
            Text("Pass MIDI from a device to another output, like an Ableton MIDI track: e.g. a Bluetooth pedal → Network Session 1 on channel 3, so another iPad or computer receives it. Notes, CCs, program changes and pitch bend are passed; StageCharts still reacts to them too. Don't route an output back into its own input.")
        }
    }

    private func newRoute() -> MIDIRoute {
        var r = MIDIRoute()
        if let net = midi.outputs.first(where: { $0.name.contains("Network") }) ?? midi.outputs.first {
            r.destID = net.id; r.destName = Self.plainName(net.name)
        } else {
            r.destID = MIDIRoute.appsOutput; r.destName = "StageCharts output"
        }
        return r
    }

    static func plainName(_ s: String) -> String { s.components(separatedBy: " · ").first ?? s }
}

struct MIDIRouteEditor: View {
    @State var route: MIDIRoute
    let inputs: [MIDIEndpointInfo]
    let outputs: [MIDIEndpointInfo]
    let onSave: (MIDIRoute) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetNavigation {
            Form {
                Section("MIDI from") {
                    TextField("Name", text: $route.sourceLabel, prompt: Text("e.g. Helix, Keys pedal"))
                    Picker("Input", selection: $route.sourceID) {
                        Text("Any input").tag(Int32(0))
                        ForEach(inputs) { Text($0.name).tag($0.id) }
                        if route.sourceID != 0 && !inputs.contains(where: { $0.id == route.sourceID }) {
                            Text("\(route.sourceName) (not connected)").tag(route.sourceID)
                        }
                    }
                    Picker("Channel", selection: $route.inChannel) {
                        Text("All channels").tag(0)
                        ForEach(1...16, id: \.self) { Text("Ch. \($0)").tag($0) }
                    }
                }
                Section {
                    TextField("Name", text: $route.destLabel, prompt: Text("e.g. FOH laptop, Ableton"))
                    Picker("Output", selection: $route.destID) {
                        ForEach(outputs) { Text($0.name).tag($0.id) }
                        Text("StageCharts output (apps on this device)").tag(MIDIRoute.appsOutput)
                        if route.destID != MIDIRoute.appsOutput && !outputs.contains(where: { $0.id == route.destID }) {
                            Text("\(route.destName) (not connected)").tag(route.destID)
                        }
                    }
                    Picker("Channel", selection: $route.outChannel) {
                        Text("Same as incoming").tag(0)
                        ForEach(1...16, id: \.self) { Text("Ch. \($0)").tag($0) }
                    }
                } header: {
                    Text("MIDI to")
                } footer: {
                    Text("Names are yours: they label this route in Settings and in MIDI monitor's routing map. Leave blank to show the device name.")
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("MIDI route")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var r = route
                        r.sourceLabel = r.sourceLabel.trimmingCharacters(in: .whitespaces)
                        r.destLabel = r.destLabel.trimmingCharacters(in: .whitespaces)
                        r.sourceName = r.sourceID == 0 ? "Any input"
                            : inputs.first(where: { $0.id == r.sourceID }).map { MIDIRoutesSection.plainName($0.name) } ?? r.sourceName
                        r.destName = r.destID == MIDIRoute.appsOutput ? "StageCharts output"
                            : outputs.first(where: { $0.id == r.destID }).map { MIDIRoutesSection.plainName($0.name) } ?? r.destName
                        onSave(r); dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
        #endif
    }
}
#endif
