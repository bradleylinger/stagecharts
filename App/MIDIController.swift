import Foundation
import CoreMIDI
import StageMIDI

/// Commands the views act on (from MIDI, keyboard or toolbar).
enum MIDIAction: Equatable {
    case selectProgram(Int)          // 1-128 (Ableton numbering), by list position
    case selectSong(String)          // song id
    case selectSetPosition(Int)      // 1-based position in the loaded set
    case goToSection(Int)            // 1-based section number
    case nextSong, previousSong
    case pageDown, pageUp
    case nextSection, previousSection
    case scrollTo(Double)            // 0...1 of the chart
    case keyUp, keyDown

    init(_ resolved: ResolvedAction) {
        switch resolved {
        case .scroll(let f): self = .scrollTo(f)
        case .selectSongProgram(let n): self = .selectProgram(n)
        case .selectSong(let id): self = .selectSong(id)
        case .selectSetPosition(let n): self = .selectSetPosition(n)
        case .goToSection(let n): self = .goToSection(n)
        case .perform(let a):
            switch a {
            case .pageDown: self = .pageDown
            case .pageUp: self = .pageUp
            case .nextSection: self = .nextSection
            case .previousSection: self = .previousSection
            case .nextSong: self = .nextSong
            case .previousSong: self = .previousSong
            case .keyUp: self = .keyUp
            case .keyDown: self = .keyDown
            case .scrollPosition: self = .scrollTo(0)
            case .goToSection: self = .goToSection(1)
            }
        }
    }

    var label: String {
        switch self {
        case .selectProgram(let n): return "Song at position \(n)"
        case .selectSong: return "Select song"
        case .selectSetPosition(let n): return "Set song \(n)"
        case .goToSection(let n): return "Go to section \(n)"
        case .scrollTo(let f): return String(format: "Scroll to %.0f%%", f * 100)
        case .nextSong: return StageAction.nextSong.title
        case .previousSong: return StageAction.previousSong.title
        case .pageDown: return StageAction.pageDown.title
        case .pageUp: return StageAction.pageUp.title
        case .nextSection: return StageAction.nextSection.title
        case .previousSection: return StageAction.previousSection.title
        case .keyUp: return StageAction.keyUp.title
        case .keyDown: return StageAction.keyDown.title
        }
    }
}

struct MIDILogEntry: Identifiable {
    let id = UUID()
    let time = Date()
    let message: String
    let result: String?
}

/// What learn mode is waiting to assign.
enum LearnTarget: Equatable {
    case action(StageAction)
    case song(id: String)
}

/// Receives MIDI from every source (network session, USB, Bluetooth, virtual) and publishes actions.
@MainActor
final class MIDIController: ObservableObject {
    struct Command: Equatable {
        let seq: Int
        let action: MIDIAction
        var local = false      // true = the user did this on this device (swipe, tap): may be announced to Ableton
    }

    @Published var mapping: MIDIMapping { didSet { saveMapping() } }
    @Published private(set) var command: Command?
    @Published private(set) var log: [MIDILogEntry] = []
    @Published private(set) var sourceNames: [String] = []
    @Published private(set) var status = "Starting…"
    @Published var learning: LearnTarget?
    @Published private(set) var learnNotice: String?

    /// Wired to the song library by the app.
    var songTriggers: () -> [(id: String, trigger: MIDITrigger)] = { [] }
    var onLearnSongTrigger: ((String, MIDITrigger) -> Void)?
    var onActionClaimedTrigger: ((MIDITrigger) -> Void)?
    var songTitle: (String) -> String = { $0 }
    /// Number of songs in the loaded set list (nil when browsing the Library).
    var activeSetLength: () -> Int? = { nil }

    /// MIDI clock: send, receive or pass through (see MIDIClock.swift).
    nonisolated let clock = MIDIClockEngine()
    /// MIDI thru routes (input / channel → output / channel), applied on the MIDI thread.
    nonisolated let router = MIDIRouter()
    @Published var routes: [MIDIRoute] = (UserDefaults.standard.data(forKey: "midiRoutes")
        .flatMap { try? JSONDecoder().decode([MIDIRoute].self, from: $0) }) ?? [] {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(routes), forKey: "midiRoutes")
            router.setRoutes(routes)
        }
    }
    /// Inputs and outputs for the route pickers (unique ID + name with connection kind).
    @Published private(set) var inputs: [MIDIEndpointInfo] = []
    @Published private(set) var outputs: [MIDIEndpointInfo] = []
    /// Ableton Link (see LinkSession.swift).
    let link = LinkSession()
    @Published var clockMode: MIDIClockMode = MIDIClockMode(rawValue: UserDefaults.standard.string(forKey: "midiClockMode") ?? "") ?? .off {
        didSet { UserDefaults.standard.set(clockMode.rawValue, forKey: "midiClockMode"); clock.setMode(clockMode); watchClock() }
    }
    /// Send mode: also send Start whenever a song is picked (off by default – it starts whatever follows the clock).
    @Published var clockStartOnSong = UserDefaults.standard.bool(forKey: "midiClockStartOnSong") {
        didSet { UserDefaults.standard.set(clockStartOnSong, forKey: "midiClockStartOnSong") }
    }
    @Published private(set) var clockState = MIDIClockEngine.Snapshot()
    private var clockTimer: Timer?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var destination = MIDIEndpointRef()
    private var outputPort = MIDIPortRef()
    private var virtualSource = MIDIEndpointRef()
    private var connected = Set<MIDIUniqueID>()
    private var seq = 0
    private static let storageKey = "midiMapping.v2"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let m = try? JSONDecoder().decode(MIDIMapping.self, from: data) {
            mapping = m
        } else {
            mapping = MIDIMapping()
        }
        start()
    }

    /// Name this device shows up as in Audio MIDI Setup's network directory.
    var networkSessionName: String {
        let name = MIDINetworkSession.default().networkName
        if !name.isEmpty { return name }
        #if os(macOS)
        return Host.current().localizedName ?? "this Mac"
        #else
        return "this iPad"
        #endif
    }

    private func start() {
        var err = MIDIClientCreateWithBlock("StageCharts" as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged {
                Task { @MainActor in self?.connectSources() }
            }
        }
        guard err == noErr else { status = "MIDI unavailable (error \(err))"; return }

        let clock = self.clock
        let router = self.router
        let networkSource = MIDINetworkSession.default().sourceEndpoint()
        let receive: MIDIReceiveBlock = { [weak self] list, refCon in
            // Clock and transport are handled right here on the MIDI thread (timing matters).
            let fromNetwork = refCon.map { MIDIEndpointRef(UInt(bitPattern: $0)) } == networkSource && networkSource != 0
            for (status, word, time) in MIDIController.systemMessages(list) {
                if let forward = clock.received(status, word: word, hostTime: time) {
                    clock.output(forward, 0, !fromNetwork)      // don't echo the network's clock back to it
                }
            }
            if let refCon {
                var uid: MIDIUniqueID = 0
                MIDIObjectGetIntegerProperty(MIDIEndpointRef(UInt(bitPattern: refCon)), kMIDIPropertyUniqueID, &uid)
                router.route(list, sourceID: uid)
            }
            let messages = MIDIController.decode(list)
            guard !messages.isEmpty else { return }
            Task { @MainActor in messages.forEach { self?.handle($0) } }
        }
        err = MIDIInputPortCreateWithProtocol(client, "StageCharts In" as CFString, ._1_0, &inputPort, receive)
        guard err == noErr else { status = "MIDI input failed (error \(err))"; return }

        // Virtual destination so apps on the same device (e.g. Ableton on the Mac) can target us directly.
        MIDIDestinationCreateWithProtocol(client, "StageCharts" as CFString, ._1_0, &destination, receive)

        // Output: a virtual source other apps can listen to, plus the network session.
        MIDIOutputPortCreate(client, "StageCharts Out" as CFString, &outputPort)
        MIDISourceCreateWithProtocol(client, "StageCharts" as CFString, ._1_0, &virtualSource)
        let (port, source) = (outputPort, virtualSource)
        router.configure(port: port, appsOutput: source)
        router.setRoutes(routes)
        clock.output = { words, time, toNetwork in
            var list = MIDIEventList()
            let packet = MIDIEventListInit(&list, ._1_0)
            var w = words
            _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, time, w.count, &w)
            let network = MIDINetworkSession.default().destinationEndpoint()
            if toNetwork, network != 0 { MIDISendEventList(port, network, &list) }
            if source != 0 { MIDIReceivedEventList(source, &list) }
        }
        clock.setMode(clockMode)
        watchClock()

        // Network MIDI (RTP-MIDI): makes this device visible in Audio MIDI Setup → Network.
        let session = MIDINetworkSession.default()
        session.isEnabled = true
        session.connectionPolicy = .anyone

        connectSources()
        status = "Listening"
    }

    /// Connects the input port to every MIDI source (re-run when devices appear/disappear).
    /// USB / Bluetooth / Network / IAC / app, from the driver that owns the endpoint's device.
    nonisolated static func connectionKind(_ endpoint: MIDIEndpointRef) -> String? {
        var entity = MIDIEntityRef(), device = MIDIDeviceRef()
        guard MIDIEndpointGetEntity(endpoint, &entity) == noErr, MIDIEntityGetDevice(entity, &device) == noErr else {
            return "app"      // virtual source published by another app (e.g. Ableton, Playback)
        }
        var owner: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(device, kMIDIPropertyDriverOwner, &owner)
        let o = (owner?.takeRetainedValue() as String?) ?? ""
        if o.contains("USB") { return "USB" }
        if o.contains("Bluetooth") || o.contains("BLE") { return "Bluetooth" }
        if o.contains("RTP") || o.contains("Network") { return "Network" }
        if o.contains("IAC") { return "IAC" }
        return nil
    }

    func connectSources() {
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            var uid: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(src, kMIDIPropertyUniqueID, &uid)
            if src == virtualSource { continue }     // our own output: listening to it would loop
            if !connected.contains(uid),
               MIDIPortConnectSource(inputPort, src, UnsafeMutableRawPointer(bitPattern: UInt(src))) == noErr {
                connected.insert(uid)
            }
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &name)
            let n = (name?.takeRetainedValue() as String?) ?? "Source \(i + 1)"
            names.append(Self.connectionKind(src).map { "\(n) · \($0)" } ?? n)
        }
        sourceNames = names

        var ins: [MIDIEndpointInfo] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            guard src != virtualSource else { continue }
            ins.append(Self.info(src))
        }
        inputs = ins
        var outs: [MIDIEndpointInfo] = [], map: [Int32: MIDIEndpointRef] = [:]
        for i in 0..<MIDIGetNumberOfDestinations() {
            let d = MIDIGetDestination(i)
            guard d != destination else { continue }       // our own input
            let inf = Self.info(d)
            outs.append(inf); map[inf.id] = d
        }
        outputs = outs
        router.setDestinations(map)
    }

    nonisolated static func info(_ e: MIDIEndpointRef) -> MIDIEndpointInfo {
        var uid: MIDIUniqueID = 0
        MIDIObjectGetIntegerProperty(e, kMIDIPropertyUniqueID, &uid)
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &name)
        let n = (name?.takeRetainedValue() as String?) ?? "MIDI \(uid)"
        return MIDIEndpointInfo(id: uid, name: connectionKind(e).map { "\(n) · \($0)" } ?? n)
    }

    // MARK: Decoding

    /// Extracts MIDI 1.0 channel-voice messages from a Universal MIDI Packet event list.
    nonisolated static func decode(_ list: UnsafePointer<MIDIEventList>) -> [MIDIMessage] {
        var out: [MIDIMessage] = []
        for packet in list.unsafeSequence() {
            let count = Int(packet.pointee.wordCount)
            withUnsafeBytes(of: packet.pointee.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                var i = 0
                while i < count {
                    let w = words[i]
                    let type = w >> 28
                    if type == 0x2, let m = MIDIMessage(status: UInt8((w >> 16) & 0xFF),
                                                        data1: Int((w >> 8) & 0x7F), data2: Int(w & 0x7F)) {
                        out.append(m)
                    }
                    // UMP sizes by message type: 0,1,2 = 1 word; 3,4 = 2 words; 5 = 4 words.
                    switch type { case 0x3, 0x4: i += 2; case 0x5: i += 4; default: i += 1 }
                }
            }
        }
        return out
    }

    /// System real-time / common messages (clock, start, continue, stop, song position) with their timestamps.
    nonisolated static func systemMessages(_ list: UnsafePointer<MIDIEventList>) -> [(UInt8, UInt32, UInt64)] {
        var out: [(UInt8, UInt32, UInt64)] = []
        for packet in list.unsafeSequence() {
            let count = Int(packet.pointee.wordCount), time = packet.pointee.timeStamp
            withUnsafeBytes(of: packet.pointee.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                var i = 0
                while i < count {
                    let w = words[i], type = w >> 28
                    if type == 0x1 { out.append((UInt8((w >> 16) & 0xFF), w, time)) }
                    switch type { case 0x3, 0x4: i += 2; case 0x5: i += 4; default: i += 1 }
                }
            }
        }
        return out
    }

    /// Publishes the clock's tempo / transport a few times a second while the clock is on.
    private func watchClock() {
        clockTimer?.invalidate(); clockTimer = nil
        clockState = clock.snapshot
        guard clockMode != .off else { return }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let s = self.clock.snapshot
                if s.bpm.map({ ($0 * 10).rounded() }) != self.clockState.bpm.map({ ($0 * 10).rounded() })
                    || s.running != self.clockState.running || (s.lastTick == nil) != (self.clockState.lastTick == nil) {
                    self.clockState = s
                }
            }
        }
    }

    /// The song on screen changed: in send mode the clock follows its tempo (and may send Start).
    func songTempoChanged(_ bpm: Int?) {
        link.songTempoChanged(bpm)
        guard clockMode == .send, let bpm, bpm > 0 else { return }
        clock.setTempo(Double(bpm))
        if clockStartOnSong { clock.start() }
        clockState = clock.snapshot
    }

    func clockStart() { clock.start(); clockState = clock.snapshot }
    func clockStop() { clock.stop(); clockState = clock.snapshot }

    // MARK: Handling

    private func handle(_ m: MIDIMessage) {
        if let target = learning, learn(m, for: target) { return }
        let resolved = mapping.resolve(m, songTriggers: songTriggers(), setLength: activeSetLength())
        let action = resolved.map(MIDIAction.init)
        var label = action?.label
        if case .selectSong(let id)? = action { label = "Song: " + songTitle(id) }
        record(m.description, label)
        if let action { send(action) }
    }

    /// Returns true if the message was consumed by learn mode.
    private func learn(_ m: MIDIMessage, for target: LearnTarget) -> Bool {
        switch target {
        case .action(let action):
            guard var trigger = MIDITrigger(learning: m, for: action) else { return false }
            if mapping.listenChannel != 0 { trigger.channel = nil }   // follows the listen channel
            let displaced = mapping.assign(trigger, to: action)
            onActionClaimedTrigger?(trigger)
            learnNotice = "\(action.title) ← \(trigger)"
                + (displaced.map { " (removed from \($0.title))" } ?? "")
        case .song(let id):
            guard var trigger = MIDITrigger(learningForSong: m) else { return false }
            if mapping.listenChannel != 0 { trigger.channel = nil }
            mapping.release(trigger)
            onLearnSongTrigger?(id, trigger)
            learnNotice = "\(songTitle(id)) ← \(trigger)"
        }
        record(m.description, "Learned")
        learning = nil
        return true
    }

    /// Two-way MIDI: tells Ableton (via the network session and the "StageCharts" virtual source)
    /// that set position `position` was picked on this device.
    func announceSongPicked(position: Int) {
        guard let msg = mapping.outgoingSongMessage(position: position) else { return }
        let word = (UInt32(0x2) << 28) | (UInt32(msg.status) << 16) | (UInt32(msg.data1) << 8) | UInt32(msg.data2)
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        var w = word
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &w)
        let network = MIDINetworkSession.default().destinationEndpoint()
        if network != 0 { MIDISendEventList(outputPort, network, &list) }
        if virtualSource != 0 { MIDIReceivedEventList(virtualSource, &list) }
        let desc = MIDIMessage(status: msg.status, data1: Int(msg.data1), data2: Int(msg.data2))?.description ?? "?"
        record("→ sent " + desc, "Song \(position) picked here")
    }

    /// Helix Native: recall snapshot `index` (0–7) with CC 69 on the Helix channel, to the
    /// "StageCharts" output (apps on this Mac, e.g. Ableton) and the network session.
    func sendHelixSnapshot(_ index: Int) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "helixSendSnapshots") == nil || defaults.bool(forKey: "helixSendSnapshots") else { return }
        let channel = sendHelixCC(69, max(0, min(7, index)))
        record("→ sent CC 69 = \(index) ch \(channel)", "Helix snapshot \(index + 1)")
        helixSent["snapshot"]?.text = "CC 69 = \(index) · snapshot \(index + 1)"
    }

    /// Helix Native: the guitar block's level, low and high (CC 14–16 → Knobs 14–16, -12…+12 dB over 0–127).
    func sendHelixGuitar(_ g: MyGuitar) {
        guard UserDefaults.standard.object(forKey: "helixGuitarBlock") as? Bool ?? true else { return }
        var channel = 1
        for (k, db) in zip(HelixBuilder.guitarKnobs, [g.level, g.low, g.high]) {
            channel = sendHelixCC(k.knob, MyGuitar.cc(db))
        }
        record("→ sent CC 14–16 ch \(channel)", "Guitar: \(g.name)")
        helixSent["guitar"]?.text = "CC 14–16 · \(MyGuitar.shortName(g.name))"
    }

    /// One control change on the Helix channel to the "StageCharts" output and the network session. Returns the channel.
    @discardableResult
    func sendHelixCC(_ cc: Int, _ value: Int) -> Int {
        let channel = max(1, min(16, UserDefaults.standard.object(forKey: "helixChannel") as? Int ?? 1))
        let status = UInt32(0xB0 | (channel - 1))
        var w = (UInt32(0x2) << 28) | (status << 16) | (UInt32(cc & 0x7F) << 8) | UInt32(max(0, min(127, value)))
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &w)
        let network = MIDINetworkSession.default().destinationEndpoint()
        if network != 0 { MIDISendEventList(outputPort, network, &list) }
        if virtualSource != 0 { MIDIReceivedEventList(virtualSource, &list) }
        let key = cc == 69 ? "snapshot" : HelixBuilder.guitarKnobs.contains(where: { $0.knob == cc }) ? "guitar" : "other"
        let v = max(0, min(127, value))
        helixSent[key] = HelixSend(time: Date(), text: "CC \(cc) = \(v)", count: (helixSent[key]?.count ?? 0) + 1)
        return channel
    }

    /// The last Helix message of each kind ("snapshot", "guitar", "other"), for MIDI monitor's routing map.
    struct HelixSend { var time: Date; var text: String; var count: Int }
    @Published private(set) var helixSent: [String: HelixSend] = [:]
    func clearHelixSent() { helixSent = [:] }

    func startLearning(_ target: LearnTarget) {
        learnNotice = nil
        learning = (learning == target) ? nil : target   // tapping again cancels
    }

    /// Also used by on-screen/keyboard controls so everything goes through one path.
    func send(_ action: MIDIAction) {
        seq += 1
        command = Command(seq: seq, action: action)
    }

    /// An action performed by the user on this device (swipe, tap).
    func sendLocal(_ action: MIDIAction) {
        seq += 1
        command = Command(seq: seq, action: action, local: true)
    }

    private func record(_ message: String, _ result: String?) {
        log.insert(MIDILogEntry(message: message, result: result), at: 0)
        if log.count > 50 { log.removeLast(log.count - 50) }
    }

    func clearLog() { log.removeAll() }

    private func saveMapping() {
        if let data = try? JSONEncoder().encode(mapping) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
    }
}
