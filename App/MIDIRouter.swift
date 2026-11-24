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

    static let appsOutput: Int32 = -2

    var summary: String {
        let from = sourceName + (inChannel == 0 ? "" : " ch \(inChannel)")
        let to = destName + (outChannel == 0 ? "" : " ch \(outChannel)")
        return "\(from) → \(to)"
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
        guard !active.isEmpty else { return }

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

        for r in active {
            let out: [UInt32] = words.compactMap { w in
                let ch = Int((w >> 16) & 0x0F) + 1
                if r.inChannel != 0 && ch != r.inChannel { return nil }
                guard r.outChannel != 0 else { return w & 0xF0FF_FFFF }     // group 0, same channel
                return (w & 0xF0F0_FFFF) | (UInt32(r.outChannel - 1) << 16)
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
                        Text(r.summary).lineLimit(2)
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
                Section("MIDI to") {
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
