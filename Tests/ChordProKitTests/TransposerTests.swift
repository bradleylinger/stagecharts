import XCTest
@testable import ChordProKit

final class TransposerTests: XCTestCase {
    func t(_ c: String, _ n: Int, flats: Bool = false) -> String? {
        Transposer.transposeChord(c, by: n, preferFlats: flats)
    }

    func testBasicChords() {
        XCTAssertEqual(t("G", 2), "A")
        XCTAssertEqual(t("Em7", 2), "F#m7")
        XCTAssertEqual(t("C", -2, flats: true), "Bb")
        XCTAssertEqual(t("B", 1), "C")
    }

    func testSlashAndExtensions() {
        XCTAssertEqual(t("G/B", 2), "A/C#")
        XCTAssertEqual(t("D/F#", 3, flats: true), "F/A")
        XCTAssertEqual(t("Csus4", 5, flats: true), "Fsus4")
        XCTAssertEqual(t("C6/9", 2), "D6/9")           // 6/9 is not a slash chord
        XCTAssertEqual(t("F#m7b5", 1), "Gm7b5")
        XCTAssertEqual(t("Bbmaj7", 2), "Cmaj7")
        XCTAssertEqual(t("C(add9)", 7), "G(add9)")
        XCTAssertEqual(t("(Bb)", -3), "(G)")
        XCTAssertEqual(t("(F/A)", 2), "(G/B)")
        XCTAssertNil(t("(To Chorus)", 2))
    }

    func testNonChordsLeftAlone() {
        XCTAssertNil(t("N.C.", 2))
        XCTAssertNil(t("x2", 2))
        XCTAssertNil(t("Hallelujah", 2))
    }

    func testKeyMath() {
        XCTAssertEqual(Key("G")!.semitones(to: Key("A")!), 2)
        XCTAssertEqual(Key("G")!.semitones(to: Key("E")!), -3)
        XCTAssertEqual(Key("C")!.transposed(by: 10).description, "Bb")
        XCTAssertTrue(Key("Eb")!.prefersFlats)
        XCTAssertFalse(Key("E")!.prefersFlats)
        XCTAssertEqual(Key("Am")!.transposed(by: 1).description, "Bbm")
    }

    func testDocumentToKey() throws {
        let src = """
        {title: Test}
        {key: G}
        [G]Amazing [G/B]grace how [C]sweet the [G]sound
        """
        let out = try Transposer.transpose(chordPro: src, toKey: Key("Bb")!)
        XCTAssertTrue(out.contains("{key: Bb}"))
        XCTAssertTrue(out.contains("[Bb]Amazing [Bb/D]grace how [Eb]sweet the [Bb]sound"))

        let toE = try Transposer.transpose(chordPro: src, toKey: Key("E")!)
        XCTAssertTrue(toE.contains("[E]Amazing [E/G#]grace how [A]sweet the [E]sound"))
    }

    func testRoundTrip() throws {
        let src = "{key: D}\n[D]a [A/C#]b [Bm7]c [G2]d [Em]e"
        for target in ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"] {
            let there = try Transposer.transpose(chordPro: src, toKey: Key(target)!)
            let back = try Transposer.transpose(chordPro: there, toKey: Key("D")!)
            XCTAssertEqual(back, src, "round trip via \(target)")
        }
    }
}
