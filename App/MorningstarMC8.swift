import Foundation
import CoreMIDI

/// A Morningstar MC8 programmed with a "StageCharts" bank (set up once; see Settings → Helix):
///   A = Page down (CC 80), E = Page up (CC 81), B C D F G H = Helix Native Switches 1–6 (toggles, CC 49–54 ch 2).
/// When a song opens, StageCharts relabels B–D and F–H with what the set's Helix preset put on Switches 1–6.
/// Labels are temporary (Morningstar's "override": nothing is saved, they go away on a bank change), and are only
/// sent after the MC8 confirms it is on the StageCharts bank, so other banks are never touched.
/// Uses Morningstar's documented SysEx API for external applications (model 04 = MC8).
@MainActor
final class MC8Link: ObservableObject {
    static let shared = MC8Link()

    static let enabledKey = "mc8Labels", outputKey = "mc8Output", bankKey = "mc8BankName"
    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    /// The MIDI output (unique ID) that reaches the MC8: its USB port, or a Bluetooth MIDI adapter.
    var outputID: Int32 { Int32(UserDefaults.standard.integer(forKey: Self.outputKey)) }
    var bankName: String { UserDefaults.standard.string(forKey: Self.bankKey) ?? "StageCharts" }

    @Published private(set) var status = "Not used yet"
    @Published private(set) var lastLabels: [String] = []

    /// Presets B, C, D, F, G, H (0-based) carry Switches 1–6.
    static let switchPresets: [UInt8] = [1, 2, 3, 5, 6, 7]
    static let model: UInt8 = 0x04

    private var port: MIDIPortRef = 0
    private var pendingBankName: CheckedContinuation<String?, Never>?
    private var labelTask: Task<Void, Never>?

    func configure(port: MIDIPortRef) { self.port = port }

    // MARK: Labels

    /// Relabel the switch presets for a song (names for Switches 1–6; empty = unassigned).
    func label(switches names: [String]) {
        guard enabled else { return }
        labelTask?.cancel()
        labelTask = Task { await sendLabels(names) }
    }

    private func sendLabels(_ names: [String]) async {
        guard let dest = destination else { status = "Choose the MIDI output that reaches the MC8"; return }
        // Only write when the MC8 says it's on the StageCharts bank (writes always go to its current bank).
        guard let current = await currentBankName(dest) else {
            status = "The MC8 didn't answer – check the MIDI output and that it's connected"; return
        }
        guard !Task.isCancelled else { return }
        guard current.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(bankName) == .orderedSame else {
            status = "MC8 is on “\(current.trimmingCharacters(in: .whitespaces))”, not “\(bankName)” – labels not sent"
            return
        }
        var labels: [String] = []
        for (i, preset) in Self.switchPresets.enumerated() {
            let label = Self.label(i < names.count ? names[i] : "", number: i + 1)
            labels.append(label)
            let payload = Array(label.padding(toLength: 10, withPad: " ", startingAt: 0).utf8).map { $0 & 0x7F }
            send(Self.frame(op2: 0x01, op3: preset, op4: 0x00, payload: payload), to: dest)   // short name (temporary)
            try? await Task.sleep(nanoseconds: 40_000_000)
            send(Self.frame(op2: 0x02, op3: preset, op4: 0x00, payload: payload), to: dest)   // toggle name (temporary)
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        lastLabels = labels
        status = "Labelled: " + labels.joined(separator: " · ")
    }

    /// "Heliosphere" → "Heliospher"; empty → "Switch 3". MC8 names are 10 characters, ASCII.
    static func label(_ name: String, number: Int) -> String {
        let ascii = name.folding(options: .diacriticInsensitive, locale: nil).unicodeScalars
            .filter { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F }.map(String.init).joined()
        let n = ascii.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return "Switch \(number)" }
        if n.count <= 10 { return n }
        if let first = n.split(separator: " ").first, first.count >= 3, first.count <= 10 { return String(first) }
        return String(n.prefix(10))
    }

    // MARK: Reading the bank name

    private func currentBankName(_ dest: MIDIEndpointRef) async -> String? {
        pendingBankName?.resume(returning: nil)
        return await withCheckedContinuation { c in
            pendingBankName = c
            send(Self.frame(op2: 0x30), to: dest)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                self?.pendingBankName?.resume(returning: nil); self?.pendingBankName = nil
            }
        }
    }

    /// A complete SysEx message from any MIDI source.
    func received(_ bytes: [UInt8]) {
        // Reply: F0 00 21 24 <model> <x> 70 <op2> <op3> <op4=size> … payload from index 16 … cs F7
        guard bytes.count > 17, bytes[1] == 0x00, bytes[2] == 0x21, bytes[3] == 0x24, bytes[6] == 0x70 else { return }
        if bytes[7] == 0x30, let c = pendingBankName {
            let size = Int(bytes[9])
            let text = bytes.dropFirst(16).prefix(size)
            pendingBankName = nil
            c.resume(returning: String(decoding: text, as: UTF8.self))
        }
    }

    // MARK: SysEx

    /// F0 00 21 24 <model> 00 70 op2 op3 op4 op5 op6 op7 txn 00 00 <payload> <checksum> F7
    static func frame(op2: UInt8, op3: UInt8 = 0, op4: UInt8 = 0, op5: UInt8 = 0, op6: UInt8 = 0,
                      payload: [UInt8] = []) -> [UInt8] {
        var b: [UInt8] = [0xF0, 0x00, 0x21, 0x24, model, 0x00, 0x70, op2, op3, op4, op5, op6, 0, 0, 0, 0] + payload
        b.append(b.reduce(0, ^) & 0x7F)       // XOR of everything so far, 7-bit
        b.append(0xF7)
        return b
    }

    private var destination: MIDIEndpointRef? {
        let id = outputID
        guard id != 0 else { return nil }
        var obj: MIDIObjectRef = 0, type: MIDIObjectType = .other
        guard MIDIObjectFindByUniqueID(id, &obj, &type) == noErr, type == .destination || type == .externalDestination else { return nil }
        return MIDIEndpointRef(obj)
    }

    /// Sends a SysEx message as MIDI 1.0 UMP SysEx7 packets (6 data bytes per packet, F0/F7 omitted).
    private func send(_ sysex: [UInt8], to dest: MIDIEndpointRef) {
        guard port != 0 else { return }
        let data = Array(sysex.dropFirst().dropLast())
        var list = MIDIEventList()
        var packet = MIDIEventListInit(&list, ._1_0)
        let chunks = stride(from: 0, to: data.count, by: 6).map { Array(data[$0..<min($0 + 6, data.count)]) }
        for (i, chunk) in chunks.enumerated() {
            let status: UInt32 = chunks.count == 1 ? 0 : i == 0 ? 1 : i == chunks.count - 1 ? 3 : 2
            let b = chunk + Array(repeating: 0, count: 6 - chunk.count)
            var words: [UInt32] = [
                (0x3 << 28) | (status << 20) | (UInt32(chunk.count) << 16) | (UInt32(b[0]) << 8) | UInt32(b[1]),
                (UInt32(b[2]) << 24) | (UInt32(b[3]) << 16) | (UInt32(b[4]) << 8) | UInt32(b[5]),
            ]
            packet = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 2, &words)
        }
        MIDISendEventList(port, dest, &list)
    }

    // MARK: Receiving (called on the MIDI thread)

    nonisolated(unsafe) private static var assembling: [UInt: [UInt8]] = [:]
    nonisolated private static let lock = NSLock()

    /// Collects SysEx7 packets from an event list; complete messages go to `received` on the main actor.
    nonisolated static func collect(_ list: UnsafePointer<MIDIEventList>, source: UInt) {
        var done: [[UInt8]] = []
        lock.lock()
        for packet in list.unsafeSequence() {
            let count = Int(packet.pointee.wordCount)
            withUnsafeBytes(of: packet.pointee.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                var i = 0
                while i < count {
                    let w = words[i], type = w >> 28
                    if type == 0x3, i + 1 < count {
                        let status = (w >> 20) & 0xF, n = Int((w >> 16) & 0xF), w2 = words[i + 1]
                        let bytes = [UInt8((w >> 8) & 0x7F), UInt8(w & 0x7F), UInt8((w2 >> 24) & 0x7F),
                                     UInt8((w2 >> 16) & 0x7F), UInt8((w2 >> 8) & 0x7F), UInt8(w2 & 0x7F)].prefix(min(6, n))
                        switch status {
                        case 0: done.append([0xF0] + bytes + [0xF7])
                        case 1: assembling[source] = [0xF0] + bytes
                        case 2: assembling[source, default: [0xF0]] += bytes
                        default:
                            done.append((assembling[source] ?? [0xF0]) + bytes + [0xF7]); assembling[source] = nil
                        }
                    }
                    switch type { case 0x3, 0x4: i += 2; case 0x5: i += 4; default: i += 1 }
                }
            }
        }
        lock.unlock()
        guard !done.isEmpty else { return }
        Task { @MainActor in done.forEach { MC8Link.shared.received($0) } }
    }
}
