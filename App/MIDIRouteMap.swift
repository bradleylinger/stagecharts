#if canImport(SwiftUI)
import SwiftUI
import CoreMIDI

/// Settings → MIDI monitor: a map of the MIDI routes that lights up as messages pass,
/// and a live list of what came in and where each message was sent.
struct MIDIRoutingMonitor: View {
    @ObservedObject var midi: MIDIController
    @State private var snap = MIDIRouter.Snapshot()
    @State private var now = Date()
    @State private var routedOnly = false

    var body: some View {
        Group {
            Section {
                inputsStrip
                if midi.routes.isEmpty {
                    Text("No routes yet. Add one in MIDI connections → MIDI routes.").foregroundStyle(.secondary)
                }
                ForEach(midi.routes) { r in
                    RouteMapRow(route: r,
                                sourceDevice: sourceDevice(r),
                                inLevel: level(r.sourceID == 0 ? snap.sourceLast.values.max() : snap.sourceLast[r.sourceID]),
                                outLevel: level(snap.routeLast[r.id]),
                                count: snap.routeCounts[r.id] ?? 0,
                                last: lastSent(r))
                }
            } header: {
                Text("Routing map")
            } footer: {
                Text("Each line is a route. The left box lights when its input sends anything; the line and right box light when MIDI is passed along.")
            }

            helixSection

            Section {
                Toggle("Only routed messages", isOn: $routedOnly)
                let rows = snap.recent.reversed().filter { !routedOnly || !$0.sends.isEmpty }.prefix(80)
                if rows.isEmpty {
                    Text("Nothing received yet.").foregroundStyle(.secondary)
                }
                ForEach(Array(rows)) { a in activityRow(a) }
            } header: {
                HStack {
                    Text("Routing activity")
                    Spacer()
                    Button("Clear") { midi.router.clearActivity() }.font(.caption)
                }
            }
        }
        #if DEBUG
        .task { await demoFeed() }      // -demoMIDIActivity: fake input for screenshots in the simulator
        #endif
        .task {
            // Poll the router (it lives on the MIDI thread) ten times a second while this page is open.
            while !Task.isCancelled {
                let s = midi.router.snapshot()
                if s.seq != snap.seq { snap = s }
                let t = Date()
                let latest = [s.sourceLast.values.max(), midi.helixSent.values.map(\.time).max()].compactMap { $0 }.max()
                if let latest, t.timeIntervalSince(latest) < 1.5 { now = t }
                else if t.timeIntervalSince(now) > 1.5 { now = t }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    // MARK: Pieces

    @AppStorage("helixChannel") private var helixChannel = 1
    @AppStorage("helixSendSnapshots") private var helixSnapshots = true
    @AppStorage("helixGuitarBlock") private var helixGuitarBlock = true

    /// What Settings → Helix sends: StageCharts → Helix Native (through Ableton), lit as each message goes out.
    private var helixSection: some View {
        let dest = MIDINetworkSession.default().isEnabled ? "StageCharts out + network" : "StageCharts out"
        let rows: [(key: String, from: String, detail: String, to: String, on: Bool)] = [
            ("snapshot", "Song picked", "per song in the set", "Snapshot · CC 69", helixSnapshots),
            ("guitar", "Guitar chosen", "per set or per song", "Guitar block · CC 14–16", helixGuitarBlock),
        ] + (midi.helixSent["other"] != nil ? [("other", "Test button", "Settings → Helix", "Knob", true)] : [])
        return Section {
            ForEach(rows, id: \.key) { r in
                let sent = midi.helixSent[r.key]
                HStack(spacing: 0) {
                    EndpointBox(title: r.from, device: r.detail, channel: "StageCharts", level: level(sent?.time))
                    RouteConnector(last: sent?.text, level: level(sent?.time), count: sent?.count ?? 0)
                    EndpointBox(title: "Helix Native", device: r.to,
                                channel: "Ch. \(helixChannel) · \(dest)", level: level(sent?.time))
                }
                .padding(.vertical, 4)
                .opacity(r.on ? 1 : 0.4)
                .overlay(alignment: .topTrailing) {
                    if !r.on { Text("Off").font(.caption2.weight(.bold)).foregroundStyle(.secondary) }
                }
            }
        } header: {
            HStack {
                Text("Helix")
                Spacer()
                Button("Clear") { midi.clearHelixSent() }.font(.caption)
            }
        } footer: {
            Text("Set in Settings → Helix. StageCharts sends these itself (they don't come from an input). In Ableton they reach Helix Native through a MIDI track from StageCharts; see Settings → Helix → Ableton setup guide.")
        }
    }

    /// Every input, with a light that blinks when it sends something.
    private var inputsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("Inputs").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if midi.inputs.isEmpty { Text("none connected").font(.caption).foregroundStyle(.secondary) }
                ForEach(midi.inputs) { i in
                    HStack(spacing: 5) {
                        ActivityLight(level: level(snap.sourceLast[i.id]))
                        Text(i.name).font(.caption).lineLimit(1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                }
            }
        }
    }

    private func activityRow(_ a: MIDIActivity) -> some View {
        let routes = a.sends.compactMap { s in midi.routes.first(where: { $0.id == s.routeID }).map { (r: $0, word: s.word) } }
        let from = routes.first(where: { !$0.r.sourceLabel.isEmpty })?.r.sourceLabel ?? inputName(a.sourceID)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(Self.time.string(from: a.time)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Text(from).font(.callout.weight(.semibold)).lineLimit(1)
                Text("ch \(MIDIActivity.channel(a.word))").font(.caption).foregroundStyle(.secondary)
                Text(MIDIActivity.describe(a.word)).font(.callout.monospacedDigit())
                Spacer(minLength: 0)
            }
            if routes.isEmpty {
                Text("not routed").font(.caption).foregroundStyle(.secondary).padding(.leading, 64)
            }
            ForEach(Array(routes.enumerated()), id: \.offset) { _, s in
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(Color.accentColor)
                    Text(s.r.toTitle).font(.callout)
                    Text("ch \(MIDIActivity.channel(s.word))").font(.caption).foregroundStyle(.secondary)
                    if !s.r.destLabel.isEmpty {
                        Text(s.r.destName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.leading, 64)
            }
        }
    }

    #if DEBUG
    private func demoFeed() async {
        guard ProcessInfo.processInfo.arguments.contains("-demoMIDIActivity") else { return }
        var i: UInt32 = 0
        while !Task.isCancelled {
            i += 1
            let w: UInt32 = i % 4 == 0 ? 0x20C1_0000 | ((i % 8) << 8) : 0x20B0_4000 | (i * 13 % 128) | ((i % 3) << 16)
            var list = MIDIEventList(); let p = MIDIEventListInit(&list, ._1_0); var ws = [w]
            _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, p, 0, 1, &ws)
            midi.router.route(&list, sourceID: midi.routes.first?.sourceID ?? 1)
            if i % 5 == 0 { midi.sendHelixSnapshot(Int(i / 5 % 8)) }
            if i % 7 == 0, let g = GuitarStore.shared.guitars.randomElement() { midi.sendHelixGuitar(g) }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }
    #endif

    // MARK: Helpers

    /// 1 just after activity, fading to 0 over a second.
    private func level(_ d: Date?) -> Double {
        guard let d else { return 0 }
        return max(0, 1 - now.timeIntervalSince(d) / 1.0)
    }
    private func lastSent(_ r: MIDIRoute) -> String? {
        guard let a = snap.recent.last(where: { $0.sends.contains { $0.routeID == r.id } }),
              let s = a.sends.first(where: { $0.routeID == r.id }) else { return nil }
        return "\(MIDIActivity.describe(s.word)) · ch \(MIDIActivity.channel(s.word))"
    }
    private func inputName(_ id: Int32) -> String {
        midi.inputs.first(where: { $0.id == id }).map { MIDIRoutesSection.plainName($0.name) } ?? "Input"
    }
    private func sourceDevice(_ r: MIDIRoute) -> String? {
        r.sourceLabel.isEmpty ? nil : r.sourceName
    }
    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
}

/// One route on the map: [from box] ——→ [to box].
private struct RouteMapRow: View {
    let route: MIDIRoute
    let sourceDevice: String?
    let inLevel: Double
    let outLevel: Double
    let count: Int
    let last: String?

    var body: some View {
        HStack(spacing: 0) {
            EndpointBox(title: route.fromTitle, device: sourceDevice, channel: route.inChannelText, level: inLevel)
            RouteConnector(last: last, level: outLevel, count: count)
            EndpointBox(title: route.toTitle, device: route.destLabel.isEmpty ? nil : route.destName,
                        channel: route.outChannelText, level: outLevel)
        }
        .padding(.vertical, 4)
        .opacity(route.enabled ? 1 : 0.4)
        .overlay(alignment: .topTrailing) {
            if !route.enabled { Text("Off").font(.caption2.weight(.bold)).foregroundStyle(.secondary) }
        }
    }

}

/// The line between two boxes: the last message above, a count below; lights as MIDI passes.
private struct RouteConnector: View {
    let last: String?
    let level: Double
    let count: Int

    var body: some View {
        VStack(spacing: 3) {
            Text(last ?? " ").font(.caption2.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(level > 0 ? Color.primary : Color.secondary)
            ZStack {
                Capsule().fill(Color.secondary.opacity(0.3)).frame(height: 2)
                Capsule().fill(Color.accentColor).frame(height: 3).opacity(level)
            }
            .overlay(alignment: .trailing) {
                Image(systemName: "arrowtriangle.right.fill").font(.system(size: 9))
                    .foregroundStyle(level > 0 ? Color.accentColor : Color.secondary.opacity(0.5))
                    .offset(x: 3)
            }
            Text(count == 0 ? " " : "\(count) sent").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(minWidth: 80, maxWidth: 160)
        .padding(.horizontal, 6)
    }
}

private struct EndpointBox: View {
    let title: String
    let device: String?
    let channel: String
    let level: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                ActivityLight(level: level)
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
            }
            if let device { Text(device).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Text(channel).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.06 + 0.18 * level)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.2 + 0.6 * level), lineWidth: 1))
    }
}

private struct ActivityLight: View {
    let level: Double
    var body: some View {
        Circle()
            .fill(level > 0 ? Color.green.opacity(0.35 + 0.65 * level) : Color.secondary.opacity(0.3))
            .frame(width: 8, height: 8)
            .shadow(color: .green.opacity(level), radius: 3 * level)
    }
}
#endif
