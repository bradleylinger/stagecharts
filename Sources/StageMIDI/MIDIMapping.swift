import Foundation

/// A decoded MIDI 1.0 channel message. Channels are 1-16; program numbers are 1-128 (Ableton style).
public enum MIDIMessage: Equatable, CustomStringConvertible {
    case noteOn(channel: Int, note: Int, velocity: Int)
    case noteOff(channel: Int, note: Int)
    case controlChange(channel: Int, controller: Int, value: Int)
    case programChange(channel: Int, program: Int)

    public init?(status: UInt8, data1: Int, data2: Int) {
        let ch = Int(status & 0x0F) + 1
        switch status & 0xF0 {
        case 0x90: self = data2 > 0 ? .noteOn(channel: ch, note: data1, velocity: data2) : .noteOff(channel: ch, note: data1)
        case 0x80: self = .noteOff(channel: ch, note: data1)
        case 0xB0: self = .controlChange(channel: ch, controller: data1, value: data2)
        case 0xC0: self = .programChange(channel: ch, program: data1 + 1)
        default: return nil
        }
    }

    public var channel: Int {
        switch self {
        case .noteOn(let c, _, _), .noteOff(let c, _), .controlChange(let c, _, _), .programChange(let c, _): return c
        }
    }

    public var description: String {
        switch self {
        case .noteOn(let c, let n, let v): return "Ch \(c) · Note \(MIDITrigger.noteName(n)) on (vel \(v))"
        case .noteOff(let c, let n): return "Ch \(c) · Note \(MIDITrigger.noteName(n)) off"
        case .controlChange(let c, let cc, let v):
            return "Ch \(c) · CC \(cc)" + (MIDITrigger.controllerNames[cc].map { " (\($0))" } ?? "") + " = \(v)"
        case .programChange(let c, let p): return "Ch \(c) · Program \(p)"
        }
    }
}

/// App actions that can be bound to a MIDI message.
public enum StageAction: String, Codable, CaseIterable, Identifiable {
    case pageDown, pageUp, nextSection, previousSection, nextSong, previousSong, keyUp, keyDown, scrollPosition, goToSection

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .pageDown: return "Page down"
        case .pageUp: return "Page up"
        case .nextSection: return "Next section"
        case .previousSection: return "Previous section"
        case .nextSong: return "Next song"
        case .previousSong: return "Previous song"
        case .keyUp: return "Key up ½ step"
        case .keyDown: return "Key down ½ step"
        case .scrollPosition: return "Scroll position"
        case .goToSection: return "Go to section (value = section #)"
        }
    }

    /// Continuous actions follow a CC value (0-127) instead of firing once.
    public var isContinuous: Bool { self == .scrollPosition || self == .goToSection }
}

/// The message that triggers an action. `channel == nil` means any channel.
public struct MIDITrigger: Codable, Hashable, CustomStringConvertible {
    public enum Kind: String, Codable { case controlChange, note, programChange }
    public var kind: Kind
    public var number: Int          // CC number, note number, or program (1-128)
    public var channel: Int?

    public init(_ kind: Kind, _ number: Int, channel: Int? = nil) {
        self.kind = kind; self.number = number; self.channel = channel
    }

    /// Builds a trigger from a message received in learn mode. Releases (note off, CC 0) are ignored
    /// so a button's release doesn't overwrite its press. Continuous actions only learn CCs.
    public init?(learning message: MIDIMessage, for action: StageAction) {
        switch message {
        case .controlChange(let c, let cc, let v):
            guard v > 0 || action.isContinuous else { return nil }
            self.init(.controlChange, cc, channel: c)
        case .noteOn(let c, let n, _):
            guard !action.isContinuous else { return nil }
            self.init(.note, n, channel: c)
        case .programChange(let c, let p):
            guard !action.isContinuous else { return nil }
            self.init(.programChange, p, channel: c)
        case .noteOff:
            return nil
        }
    }

    /// Builds a trigger for selecting a song: any CC press, note on, or program change.
    public init?(learningForSong message: MIDIMessage) {
        switch message {
        case .controlChange(let c, let cc, let v) where v > 0: self.init(.controlChange, cc, channel: c)
        case .noteOn(let c, let n, _): self.init(.note, n, channel: c)
        case .programChange(let c, let p): self.init(.programChange, p, channel: c)
        default: return nil
        }
    }

    /// `ignoreChannel`: when the app listens on one channel, every trigger follows that channel.
    public func matches(_ m: MIDIMessage, ignoreChannel: Bool = false) -> Bool {
        if !ignoreChannel, let channel, channel != m.channel { return false }
        switch (kind, m) {
        case (.controlChange, .controlChange(_, let cc, _)): return cc == number
        case (.note, .noteOn(_, let n, _)): return n == number
        case (.programChange, .programChange(_, let p)): return p == number
        default: return false
        }
    }

    public var description: String { label(showChannel: true) }

    /// Display text; the channel is hidden when all triggers follow one listen channel.
    public func label(showChannel: Bool) -> String {
        let ch = showChannel ? (channel.map { "Ch \($0) · " } ?? "") : ""
        switch kind {
        case .controlChange: return ch + "CC \(number)" + (Self.controllerNames[number].map { " (\($0))" } ?? "")
        case .note: return ch + "Note \(Self.noteName(number))"
        case .programChange: return ch + "Program \(number)"
        }
    }

    public static let controllerNames: [Int: String] = [
        1: "Mod wheel", 2: "Breath", 4: "Foot", 7: "Volume", 10: "Pan", 11: "Expression",
        64: "Sustain", 66: "Sostenuto", 67: "Soft pedal",
    ]

    /// Ableton/Yamaha-style note names (C3 = 60, lowest note C-2).
    public static func noteName(_ n: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return names[((n % 12) + 12) % 12] + String(n / 12 - 2)
    }
}

/// What the app should do in response to a message.
public enum ResolvedAction: Equatable {
    case perform(StageAction)
    case scroll(Double)             // 0...1
    case selectSongProgram(Int)     // 1-128, by list position (fallback)
    case selectSong(id: String)     // a song with its own trigger
    case selectSetPosition(Int)     // 1-based position in the loaded set list
    case goToSection(Int)           // 1-based section number (e.g. from Playback timeline cues)
}

/// All MIDI settings: channel filter, song selection by Program Change, and action bindings.
public struct MIDIMapping: Codable, Equatable {
    public var listenChannel: Int = 1             // 0 = omni, else 1-16
    public var programChangeSelectsSong = true
    public var bindings: [String: MIDITrigger]    // StageAction.rawValue → trigger
    /// Second triggers that also fire an action, e.g. the MC8 StageCharts bank's CC 80/81 alongside a learned note.
    public var extraBindings: [String: MIDITrigger] = MIDIMapping.defaultExtraBindings
    /// The StageCharts bank on a Morningstar MC8 sends CC 80 (Page down) and CC 81 (Page up); its editor API can't send notes.
    public static let defaultExtraBindings: [String: MIDITrigger] = [
        StageAction.pageDown.rawValue: MIDITrigger(.controlChange, 80),
        StageAction.pageUp.rawValue: MIDITrigger(.controlChange, 81),
    ]
    /// Set-list slots: CC (firstCC + n - 1) opens song n of the loaded set (default CC 101–110).
    public var setSlotsEnabled = true
    public var setSlotFirstCC = 101
    public var setSlotCount = 10
    /// Two-way: when a song is picked on the device, send a message out (e.g. to Ableton).
    public enum SendKind: String, Codable, CaseIterable { case setSlotCC, programChange }
    public var sendSongChanges = false
    public var sendKind: SendKind = .setSlotCC

    public init(listenChannel: Int = 1, programChangeSelectsSong: Bool = true, bindings: [String: MIDITrigger]? = nil) {
        self.listenChannel = listenChannel
        self.programChangeSelectsSong = programChangeSelectsSong
        self.bindings = bindings ?? MIDIMapping.defaultBindings
    }

    enum CodingKeys: String, CodingKey {
        case listenChannel, programChangeSelectsSong, bindings, setSlotsEnabled, setSlotFirstCC, setSlotCount
        case sendSongChanges, sendKind, extraBindings
    }

    /// Tolerates mappings saved by earlier versions (missing keys get defaults).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        listenChannel = try c.decodeIfPresent(Int.self, forKey: .listenChannel) ?? 1
        programChangeSelectsSong = try c.decodeIfPresent(Bool.self, forKey: .programChangeSelectsSong) ?? true
        bindings = try c.decodeIfPresent([String: MIDITrigger].self, forKey: .bindings) ?? MIDIMapping.defaultBindings
        setSlotsEnabled = try c.decodeIfPresent(Bool.self, forKey: .setSlotsEnabled) ?? true
        setSlotFirstCC = try c.decodeIfPresent(Int.self, forKey: .setSlotFirstCC) ?? 101
        setSlotCount = try c.decodeIfPresent(Int.self, forKey: .setSlotCount) ?? 10
        sendSongChanges = try c.decodeIfPresent(Bool.self, forKey: .sendSongChanges) ?? false
        sendKind = try c.decodeIfPresent(SendKind.self, forKey: .sendKind) ?? .setSlotCC
        extraBindings = try c.decodeIfPresent([String: MIDITrigger].self, forKey: .extraBindings) ?? MIDIMapping.defaultExtraBindings
    }

    /// Outgoing message (status, data1, data2) announcing that set position `n` was picked on the device.
    /// Uses the listen channel (channel 1 when listening omni).
    public func outgoingSongMessage(position n: Int) -> (status: UInt8, data1: UInt8, data2: UInt8)? {
        guard sendSongChanges, n >= 1 else { return nil }
        let ch = UInt8(max(1, listenChannel) - 1)
        switch sendKind {
        case .setSlotCC:
            guard let cc = setSlotCC(forPosition: n) ?? (n <= 10 ? setSlotFirstCC + n - 1 : nil), cc <= 127 else { return nil }
            return (0xB0 | ch, UInt8(cc), 127)
        case .programChange:
            guard n <= 128 else { return nil }
            return (0xC0 | ch, UInt8(n - 1), 0)
        }
    }

    /// The CC that opens set position `n` (1-based), if slots are on and n is in range.
    public func setSlotCC(forPosition n: Int) -> Int? {
        guard setSlotsEnabled, n >= 1, n <= setSlotCount, setSlotFirstCC + n - 1 <= 127 else { return nil }
        return setSlotFirstCC + n - 1
    }

    /// Default = OnSong-compatible: note C#-2 page down, C-2 page up, Breath (CC 2) scroll position.
    public static let defaultBindings = onSongPreset

    public static let onSongPreset: [String: MIDITrigger] = [
        StageAction.pageDown.rawValue: MIDITrigger(.note, 1),
        StageAction.pageUp.rawValue: MIDITrigger(.note, 0),
        StageAction.scrollPosition.rawValue: MIDITrigger(.controlChange, 2),
    ]

    /// Alternative layout: one CC per action.
    public static let ccPreset: [String: MIDITrigger] = [
        StageAction.pageDown.rawValue: MIDITrigger(.controlChange, 20),
        StageAction.pageUp.rawValue: MIDITrigger(.controlChange, 21),
        StageAction.nextSection.rawValue: MIDITrigger(.controlChange, 22),
        StageAction.previousSection.rawValue: MIDITrigger(.controlChange, 23),
        StageAction.scrollPosition.rawValue: MIDITrigger(.controlChange, 24),
        StageAction.nextSong.rawValue: MIDITrigger(.controlChange, 25),
        StageAction.previousSong.rawValue: MIDITrigger(.controlChange, 26),
        StageAction.keyUp.rawValue: MIDITrigger(.controlChange, 27),
        StageAction.keyDown.rawValue: MIDITrigger(.controlChange, 28),
    ]

    /// Removes `trigger` from every action (used when a song claims it).
    public mutating func release(_ trigger: MIDITrigger) {
        for (k, v) in bindings where v == trigger { bindings[k] = nil }
        for (k, v) in extraBindings where v == trigger { extraBindings[k] = nil }
    }

    public func trigger(for action: StageAction) -> MIDITrigger? { bindings[action.rawValue] }

    /// Assigns `trigger` to `action`, removing it from any other action.
    /// Returns the action that previously used this trigger, if any.
    @discardableResult
    public mutating func assign(_ trigger: MIDITrigger?, to action: StageAction) -> StageAction? {
        var displaced: StageAction?
        if let trigger {
            for other in StageAction.allCases where other != action && bindings[other.rawValue] == trigger {
                bindings[other.rawValue] = nil
                displaced = other
            }
            for other in StageAction.allCases where other != action && extraBindings[other.rawValue] == trigger {
                extraBindings[other.rawValue] = nil
                displaced = other
            }
        }
        bindings[action.rawValue] = trigger
        return displaced
    }

    /// Order: action bindings → set-list slot CCs (when a set is loaded) → songs' own triggers
    /// → Program Change by list position. `setLength` = songs in the loaded set (nil = no set).
    public func resolve(_ m: MIDIMessage, songTriggers: [(id: String, trigger: MIDITrigger)] = [],
                        setLength: Int? = nil) -> ResolvedAction? {
        if listenChannel != 0 && m.channel != listenChannel { return nil }
        let follow = listenChannel != 0      // one listen channel → triggers' own channels don't matter
        let isRelease: Bool = { if case .controlChange(_, _, 0) = m { return true }; return false }()
        for action in StageAction.allCases {
            let hit = [bindings[action.rawValue], extraBindings[action.rawValue]].compactMap { $0 }
                .contains { $0.matches(m, ignoreChannel: follow) }
            guard hit else { continue }
            if action.isContinuous {
                guard case .controlChange(_, _, let v) = m else { continue }
                if action == .goToSection { return v > 0 ? .goToSection(v) : nil }
                return .scroll(Double(v) / 127)
            }
            return isRelease ? nil : .perform(action)
        }
        if setSlotsEnabled, let setLength, case .controlChange(_, let cc, let v) = m,
           cc >= setSlotFirstCC, cc < setSlotFirstCC + setSlotCount {
            let position = cc - setSlotFirstCC + 1
            guard v > 0, position <= setLength else { return nil }      // release, or empty slot
            return .selectSetPosition(position)
        }
        if let song = songTriggers.first(where: { $0.trigger.matches(m, ignoreChannel: follow) }) {
            return isRelease ? nil : .selectSong(id: song.id)
        }
        if programChangeSelectsSong, case .programChange(_, let p) = m { return .selectSongProgram(p) }
        return nil
    }
}
