import XCTest
@testable import ChordProKit

final class ChordShapesTests: XCTestCase {
    func spell(_ s: String) -> [String] { ChordSpelling.parse(s)!.noteNames }
    func first(_ s: String) -> String { Guitar.fingerings(for: ChordSpelling.parse(s)!).first!.tab }

    func testSpelling() {
        XCTAssertEqual(spell("C"), ["C", "E", "G"])
        XCTAssertEqual(spell("Am7"), ["A", "C", "E", "G"])
        XCTAssertEqual(spell("F#m7b5"), ["F#", "A", "C", "E"])
        XCTAssertEqual(spell("G/B"), ["B", "G", "D"])
        XCTAssertEqual(spell("Bbmaj7"), ["Bb", "D", "F", "A"])
        XCTAssertEqual(spell("Dsus4"), ["D", "G", "A"])
        XCTAssertEqual(spell("G2"), ["G", "A", "D"])
        XCTAssertEqual(spell("Cadd9"), ["C", "E", "G", "D"])
        XCTAssertEqual(spell("E7#9"), ["E", "G#", "B", "D", "G"])
        XCTAssertEqual(spell("Bdim7"), ["B", "D", "F", "G#"])
        XCTAssertEqual(spell("C6/9"), ["C", "E", "G", "A", "D"])
        XCTAssertEqual(spell("Ebm"), ["Eb", "Gb", "Bb"])
        XCTAssertNil(ChordSpelling.parse("N.C."))
        XCTAssertNil(ChordSpelling.parse("x2"))
    }

    func testCommonShapes() {
        for c in ["C", "D", "E", "G", "A", "Am", "Dm", "Em", "F", "Bm", "B7", "G/B", "D/F#", "C/G", "Cadd9", "Dsus4",
                  "Asus2", "G2", "Em7", "Am7", "Fmaj7", "Bb", "Eb", "F#m", "C#m", "Ab", "E7", "A7", "Dmaj7", "Gsus4", "D2", "Bbmaj7", "C/E", "Am/G", "F/A"] {
            let f = Guitar.fingerings(for: ChordSpelling.parse(c)!)
            print(c.padding(toLength: 7, withPad: " ", startingAt: 0), f.prefix(4).map(\.tab).joined(separator: "  "),
                  f.first?.barre.map { "barre \($0.fret)" } ?? "")
        }
        print("piano G/B", Piano.notes(for: ChordSpelling.parse("G/B")!))
    }
}

extension ChordShapesTests {
    func testStandardTableSpellsCorrectly() {
        // Every table shape must actually contain its chord's notes with the right bass.
        for (name, tab) in Guitar.standardShapes {
            let c = ChordSpelling.parse(name)!
            let f = Guitar.fingering(tab)
            let played = f.frets.indices.filter { f.frets[$0] >= 0 }
            let notes = played.map { (Guitar.tuning[$0] + f.frets[$0]) % 12 }
            XCTAssertEqual(notes.first, c.bass ?? c.root, "\(name) \(tab) bass")
            XCTAssertTrue(Set(notes).isSubset(of: c.pitchClasses), "\(name) \(tab) has a wrong note")
            XCTAssertEqual(Guitar.fingerings(for: c).first?.tab, tab, name)
        }
    }
}
