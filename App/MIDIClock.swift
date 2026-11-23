import Foundation
import CoreMIDI

/// MIDI clock (24 pulses per quarter note) plus Start / Continue / Stop.
/// - send: StageCharts is the master, at the current song's BPM.
/// - receive: measures an external clock (e.g. Ableton, Playback) and shows its tempo and transport.
/// - passThrough: receive, and forward the clock from the inputs to StageCharts' outputs.
enum MIDIClockMode: String, CaseIterable, Identifiable {
    case off, send, receive, passThrough
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .send: return "Send"
        case .receive: return "Receive"
        case .passThrough: return "Pass through"
        }
    }
}

/// Clock timing runs off the main thread; the UI reads `snapshot` a few times a second.
final class MIDIClockEngine: @unchecked Sendable {
    struct Snapshot: Equatable {
        var bpm: Double?            // sending: our tempo; receiving: measured tempo
        var running = false         // transport (after Start/Continue, until Stop)
        var lastTick: Date?         // receiving: when the last pulse arrived
    }

    private let lock = NSLock()
    private var mode: MIDIClockMode = .off
    private var tempo: Double = 120
    private var running = false
    private var tickTimes: [UInt64] = []       // host times of recent incoming pulses
    private var lastTickHost: UInt64 = 0
    private var measured: Double?
    private var sendThread: Thread?
    private var nextTickHost: UInt64 = 0

    /// Where outgoing clock goes; set by MIDIController.
    var output: (_ words: [UInt32], _ hostTime: UInt64, _ toNetwork: Bool) -> Void = { _, _, _ in }

    private static let timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
    static func nanos(_ host: UInt64) -> Double { Double(host) * Double(timebase.numer) / Double(timebase.denom) }
    static func host(nanos: Double) -> UInt64 { UInt64(nanos * Double(timebase.denom) / Double(timebase.numer)) }

    /// a − b in nanoseconds, safe when b is later than a (timestamps can be scheduled ahead).
    static func gap(_ a: UInt64, _ b: UInt64) -> Double { a >= b ? nanos(a - b) : -nanos(b - a) }

    static func word(_ status: UInt8) -> UInt32 { (UInt32(0x1) << 28) | (UInt32(status) << 16) }

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        switch mode {
        case .off: return Snapshot()
        case .send: return Snapshot(bpm: tempo, running: running)
        case .receive, .passThrough:
            let fresh = lastTickHost != 0 && Self.gap(mach_absolute_time(), lastTickHost) < 1_000_000_000
            return Snapshot(bpm: fresh ? measured : nil, running: running,
                            lastTick: fresh ? Date() : nil)
        }
    }

    func setMode(_ m: MIDIClockMode) {
        lock.lock()
        let old = mode
        mode = m
        running = false; tickTimes.removeAll(); measured = nil; lastTickHost = 0
        lock.unlock()
        if old == .send && m != .send { output([Self.word(0xFC)], 0, true) }
        if m == .send { startSending() } else { sendThread?.cancel(); sendThread = nil }
    }

    func setTempo(_ bpm: Double) {
        guard bpm >= 20, bpm <= 400 else { return }
        lock.lock(); tempo = bpm; lock.unlock()
    }

    // MARK: Transport (send mode)

    func start() { transport(0xFA, running: true, resetPhase: true) }
    func `continue`() { transport(0xFB, running: true, resetPhase: false) }
    func stop() { transport(0xFC, running: false, resetPhase: false) }

    private func transport(_ status: UInt8, running r: Bool, resetPhase: Bool) {
        lock.lock()
        guard mode == .send else { lock.unlock(); return }
        running = r
        // Start: the next pulse after Start is beat 1, so begin the pulse grid right after it.
        if resetPhase { nextTickHost = mach_absolute_time() + Self.host(nanos: 2_000_000) }
        let at = nextTickHost
        lock.unlock()
        output([Self.word(status)], resetPhase ? at &- Self.host(nanos: 1_000_000) : 0, true)
    }

    // MARK: Sending

    /// Schedules pulses ~40 ms ahead with CoreMIDI timestamps, so timing doesn't depend on this thread waking exactly.
    private func startSending() {
        sendThread?.cancel()
        lock.lock(); nextTickHost = mach_absolute_time() + Self.host(nanos: 5_000_000); lock.unlock()
        let t = Thread { [weak self] in
            while let self, !Thread.current.isCancelled {
                let horizon = mach_absolute_time() + Self.host(nanos: 40_000_000)
                var due: [UInt64] = []
                self.lock.lock()
                let interval = Self.host(nanos: 60_000_000_000 / (self.tempo * 24))
                while self.nextTickHost < horizon {
                    due.append(self.nextTickHost)
                    self.nextTickHost += interval
                }
                self.lock.unlock()
                for h in due { self.output([Self.word(0xF8)], h, true) }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        t.qualityOfService = .userInteractive
        t.name = "StageCharts MIDI clock"
        sendThread = t
        t.start()
    }

    // MARK: Receiving

    /// Called from the MIDI receive thread with system real-time / common messages.
    /// Returns the words to forward when passing through.
    func received(_ status: UInt8, word: UInt32, hostTime: UInt64) -> [UInt32]? {
        lock.lock(); defer { lock.unlock() }
        guard mode == .receive || mode == .passThrough else { return nil }
        let now = hostTime != 0 ? hostTime : mach_absolute_time()
        switch status {
        case 0xF8:
            if lastTickHost != 0, abs(Self.gap(now, lastTickHost)) > 500_000_000 { tickTimes.removeAll() }   // a gap: restart
            lastTickHost = now
            tickTimes.append(now)
            if tickTimes.count > 49 { tickTimes.removeFirst(tickTimes.count - 49) }
            if tickTimes.count >= 7 {
                let span = Self.gap(tickTimes.last!, tickTimes.first!)
                let perTick = span / Double(tickTimes.count - 1)
                let bpm = 60_000_000_000 / (perTick * 24)
                measured = measured.map { abs($0 - bpm) < 0.15 ? $0 : bpm } ?? bpm   // steady display
            }
        case 0xFA, 0xFB: running = true
        case 0xFC: running = false
        default: break
        }
        return mode == .passThrough ? [word] : nil
    }
}
