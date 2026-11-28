import XCTest
@testable import StageMIDI

final class MIDIMappingTests: XCTestCase {
    func msg(_ status: UInt8, _ d1: Int, _ d2: Int = 0) -> MIDIMessage { MIDIMessage(status: status, data1: d1, data2: d2)! }

    func testDecoding() {
        XCTAssertEqual(msg(0xC0, 5), .programChange(channel: 1, program: 6))
        XCTAssertEqual(msg(0xB3, 20, 127), .controlChange(channel: 4, controller: 20, value: 127))
        XCTAssertEqual(msg(0x90, 60, 0), .noteOff(channel: 1, note: 60))   // note-on vel 0 = off
        XCTAssertEqual(MIDITrigger.noteName(60), "C3")
    }

    func testOnSongCompatibleDefaults() {
        let m = MIDIMapping()
        XCTAssertEqual(m.listenChannel, 1)
        XCTAssertEqual(m.resolve(msg(0x90, 1, 100)), .perform(.pageDown))     // C#-2
        XCTAssertEqual(m.resolve(msg(0x90, 0, 100)), .perform(.pageUp))       // C-2
        XCTAssertEqual(m.resolve(msg(0xB0, 2, 127)), .scroll(1))              // Breath
        XCTAssertEqual(m.resolve(msg(0xB0, 2, 0)), .scroll(0))
        XCTAssertNil(m.resolve(msg(0x91, 1, 100)))                            // channel 2 ignored
        XCTAssertEqual(m.resolve(msg(0xC0, 2)), .selectSongProgram(3))
        XCTAssertEqual(MIDITrigger(.controlChange, 2).description, "CC 2 (Breath)")
        XCTAssertEqual(MIDITrigger.noteName(1), "C#-2")
    }

    func testCCPreset() {
        let m = MIDIMapping(listenChannel: 0, bindings: MIDIMapping.ccPreset)
        XCTAssertEqual(m.resolve(msg(0xB0, 20, 127)), .perform(.pageDown))
        XCTAssertNil(m.resolve(msg(0xB0, 20, 0)))                             // release ignored
        XCTAssertEqual(m.resolve(msg(0xB0, 24, 127)), .scroll(1))
    }

    func testSongTriggersLikeOnSong() {
        let m = MIDIMapping()
        let songs: [(id: String, trigger: MIDITrigger)] = [
            ("blessed", MIDITrigger(.controlChange, 101, channel: 1)),
            ("house", MIDITrigger(.controlChange, 102, channel: 1)),
        ]
        XCTAssertEqual(m.resolve(msg(0xB0, 102, 127), songTriggers: songs), .selectSong(id: "house"))
        XCTAssertNil(m.resolve(msg(0xB0, 102, 0), songTriggers: songs))       // release
        XCTAssertNil(m.resolve(msg(0xB0, 105, 127), songTriggers: songs))     // unassigned slot
        XCTAssertEqual(MIDITrigger(learningForSong: msg(0xB0, 103, 127)), MIDITrigger(.controlChange, 103, channel: 1))
        XCTAssertNil(MIDITrigger(learningForSong: msg(0xB0, 103, 0)))
    }

    func testListenChannelOverridesTriggerChannels() {
        var m = MIDIMapping()                          // listens on channel 1
        let songs: [(id: String, trigger: MIDITrigger)] = [("blessed", MIDITrigger(.controlChange, 101, channel: 1))]
        m.listenChannel = 4                            // user switches Ableton to channel 4
        XCTAssertEqual(m.resolve(msg(0xB3, 101, 127), songTriggers: songs), .selectSong(id: "blessed"))
        XCTAssertNil(m.resolve(msg(0xB0, 101, 127), songTriggers: songs))   // channel 1 now ignored
        XCTAssertEqual(m.resolve(msg(0x93, 1, 100)), .perform(.pageDown))
        m.listenChannel = 0                            // omni: trigger's own channel applies again
        XCTAssertNil(m.resolve(msg(0xB3, 101, 127), songTriggers: songs))
        XCTAssertEqual(m.resolve(msg(0xB0, 101, 127), songTriggers: songs), .selectSong(id: "blessed"))
        XCTAssertEqual(MIDITrigger(.controlChange, 101, channel: 1).label(showChannel: false), "CC 101")
    }

    func testSetSlotsCC101To110() {
        var m = MIDIMapping()
        m.listenChannel = 4
        let songs: [(id: String, trigger: MIDITrigger)] = [("blessed", MIDITrigger(.controlChange, 101, channel: 1))]
        // Set of 4 loaded: CC 101-104 pick positions, 105-110 are empty slots, slots beat song triggers
        XCTAssertEqual(m.resolve(msg(0xB3, 101, 127), songTriggers: songs, setLength: 4), .selectSetPosition(1))
        XCTAssertEqual(m.resolve(msg(0xB3, 104, 127), songTriggers: songs, setLength: 4), .selectSetPosition(4))
        XCTAssertNil(m.resolve(msg(0xB3, 105, 127), songTriggers: songs, setLength: 4))
        XCTAssertNil(m.resolve(msg(0xB3, 102, 0), songTriggers: songs, setLength: 4))       // release
        // No set loaded: the song's own trigger applies
        XCTAssertEqual(m.resolve(msg(0xB3, 101, 127), songTriggers: songs, setLength: nil), .selectSong(id: "blessed"))
        m.setSlotsEnabled = false
        XCTAssertEqual(m.resolve(msg(0xB3, 101, 127), songTriggers: songs, setLength: 4), .selectSong(id: "blessed"))
        XCTAssertEqual(MIDIMapping().setSlotCC(forPosition: 10), 110)
        XCTAssertNil(MIDIMapping().setSlotCC(forPosition: 11))
    }

    func testGoToSectionForPlaybackCues() {
        var m = MIDIMapping()
        m.assign(MIDITrigger(.controlChange, 30), to: .goToSection)
        XCTAssertEqual(m.resolve(msg(0xB0, 30, 3)), .goToSection(3))
        XCTAssertNil(m.resolve(msg(0xB0, 30, 0)))
        XCTAssertNil(MIDITrigger(learning: msg(0x90, 60, 100), for: .goToSection))   // CC only
    }

    func testOutgoingSongMessages() {
        var m = MIDIMapping()
        XCTAssertNil(m.outgoingSongMessage(position: 2))                 // off by default
        m.sendSongChanges = true
        m.listenChannel = 4
        XCTAssertTrue(m.outgoingSongMessage(position: 2)! == (0xB3, 102, 127))
        m.sendKind = .programChange
        XCTAssertTrue(m.outgoingSongMessage(position: 2)! == (0xC3, 1, 0)) // Program 2 (0-based 1)
    }

    func testDecodesOlderSavedMapping() throws {
        let old = #"{"listenChannel":4,"programChangeSelectsSong":true,"bindings":{}}"#.data(using: .utf8)!
        let m = try JSONDecoder().decode(MIDIMapping.self, from: old)
        XCTAssertEqual(m.listenChannel, 4)
        XCTAssertTrue(m.setSlotsEnabled)
        XCTAssertEqual(m.setSlotFirstCC, 101)
    }

    func testLearnNoteAndDisplace() {
        var m = MIDIMapping(listenChannel: 0, bindings: MIDIMapping.ccPreset)
        // Learning a note for "next song"
        let t = MIDITrigger(learning: msg(0x95, 36, 100), for: .nextSong)!
        XCTAssertEqual(t, MIDITrigger(.note, 36, channel: 6))
        m.assign(t, to: .nextSong)
        XCTAssertEqual(m.resolve(msg(0x95, 36, 90)), .perform(.nextSong))
        XCTAssertNil(m.resolve(msg(0x94, 36, 90)))                        // wrong channel
        // Re-using CC 20 for "next section" takes it away from page down
        let displaced = m.assign(MIDITrigger(.controlChange, 20), to: .nextSection)
        XCTAssertEqual(displaced, .pageDown)
        XCTAssertNil(m.trigger(for: .pageDown))
        XCTAssertEqual(m.resolve(msg(0xB0, 20, 1)), .perform(.nextSection))
    }

    func testLearnIgnoresReleasesAndWrongTypes() {
        XCTAssertNil(MIDITrigger(learning: msg(0xB0, 20, 0), for: .pageDown))
        XCTAssertNil(MIDITrigger(learning: msg(0x80, 60), for: .pageDown))
        XCTAssertNil(MIDITrigger(learning: msg(0x90, 60, 100), for: .scrollPosition))
        XCTAssertNotNil(MIDITrigger(learning: msg(0xB0, 7, 0), for: .scrollPosition))
    }

    func testProgramBoundToActionBeatsSongSelection() {
        var m = MIDIMapping(listenChannel: 0)
        m.assign(MIDITrigger(.programChange, 100), to: .nextSong)
        XCTAssertEqual(m.resolve(msg(0xC0, 99)), .perform(.nextSong))
        XCTAssertEqual(m.resolve(msg(0xC0, 4)), .selectSongProgram(5))
    }

    func testCodableRoundTrip() throws {
        var m = MIDIMapping(listenChannel: 3)
        m.assign(MIDITrigger(.note, 40, channel: 3), to: .keyUp)
        let back = try JSONDecoder().decode(MIDIMapping.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back, m)
    }
}

final class ExtraBindingTests: XCTestCase {
    func testMC8BankCCsPageAlongsideNotes() {
        let m = MIDIMapping()
        XCTAssertEqual(m.resolve(.controlChange(channel: 1, controller: 80, value: 127)), .perform(.pageDown))
        XCTAssertEqual(m.resolve(.controlChange(channel: 1, controller: 81, value: 127)), .perform(.pageUp))
        XCTAssertEqual(m.resolve(.noteOn(channel: 1, note: 1, velocity: 127)), .perform(.pageDown))
        XCTAssertNil(m.resolve(.controlChange(channel: 1, controller: 80, value: 0)))
    }
    func testOldSavedMappingGetsExtras() throws {
        let old = #"{"listenChannel":1,"programChangeSelectsSong":true,"bindings":{}}"#.data(using: .utf8)!
        let m = try JSONDecoder().decode(MIDIMapping.self, from: old)
        XCTAssertEqual(m.extraBindings[StageAction.pageUp.rawValue], MIDITrigger(.controlChange, 81))
    }
}
