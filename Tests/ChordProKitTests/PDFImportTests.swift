import XCTest
@testable import ChordProKit

/// Runs against real SongSelect PDFs in samples/pdf (not committed: copyrighted).
final class PDFImportTests: XCTestCase {
    var samples: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("samples/pdf")
    }

    func testHolyForever() throws {
        let url = samples.appendingPathComponent("Holy Forever-chords-Bb.pdf")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "sample PDF not present")
        let cho = try PDFChordSheetImporter.chordPro(fromPDF: url)
        XCTAssertTrue(cho.contains("{title: Holy Forever}"))
        XCTAssertTrue(cho.contains("{key: Bb}"))
        XCTAssertTrue(cho.contains("{tempo: 72}"))
        XCTAssertTrue(cho.contains("{ccli: 7201044}"))
        XCTAssertTrue(cho.contains("| [Eb] . . [Gm] | [Fsus] | [Bb/D] | [Gm] [Fsus] |"))
        XCTAssertTrue(cho.contains("A [Bb]thousand generations [Eb2]falling down in [Bb]worship"))
        XCTAssertTrue(cho.contains("All creation [Bb/D]cries Ho - [Gm7]ly"))
        XCTAssertFalse(cho.contains("For use solely"))
        XCTAssertEqual(ChordProSong(cho).source, .convertedPDF)

        let song = ChordProSong(cho)
        XCTAssertEqual(song.sections.compactMap(\.label),
                       ["Intro", "Verse 1", "Pre-Chorus", "Chorus 1", "Verse 2", "Chorus 2", "Tag"])
        // Converted chart transposes like any ChordPro file.
        let inG = try Transposer.transpose(chordPro: cho, toKey: Key("G")!)
        XCTAssertTrue(inG.contains("A [G]thousand generations [C2]falling down in [G]worship"))
    }

    /// Expected section order + a few exact lines per real SongSelect PDF.
    func testAllSamplePDFs() throws {
        let expectations: [(file: String, key: String, sections: [String], lines: [String])] = [
            ("Goodness Of God-chords-Ab.pdf", "Ab", ["Verse 1", "Chorus", "Verse 2", "Bridge", "Tag"],
             ["I love Your [Ab]voice You have [Db]led me through the [Ab]fire",
              "It’s [Eb(4)]running after [Ab]me"]),
            ("Build My Life-chords-G.pdf", "G", ["Intro", "Verse 1", "Verse 2", "Chorus", "Bridge"],
             ["| [G] | [C2] | [G/B] | [C2] |", "It is a [G/B]firm foundation",
              "And [C2]show me who You are and [Am]fill me"]),
            ("Way Maker-chords-E.pdf", "E",
             ["Verse 1", "Chorus", "Verse 2", "Verse 3", "Tag 1A", "Bridge", "Instrumental", "Tag 1B"],
             ["||: [A2] | [E] | [B(4)] | [C#m7] :||", "I worship [Bsus]You I worship [C#m]You"]),
            ("What A Beautiful Name-chords-D.pdf", "D",
             ["Verse 1", "Chorus 1", "Verse 2", "Chorus 2", "Instrumental", "Bridge 1", "Bridge 2", "Chorus 3", "Ending"],
             ["[Bm]Your hidden glory [A/C#]in cre - [D]ation", "Now and for - [Bm7]ever God You [F#m7]reign"]),
            ("O Come O Come Emmanuel (Veni Emmanuel)-chords-Em.pdf", "Em",
             ["Verse 1", "Chorus", "Verse 2", "Verse 3", "Verse 4"],
             ["[D/F#]Shall [G]come to [C]thee O [Am]Is [Em/B]- [Bm]ra - [Em]el"]),
        ]
        for e in expectations {
            let url = samples.appendingPathComponent(e.file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let cho = try PDFChordSheetImporter.chordPro(fromPDF: url)
            let song = ChordProSong(cho)
            XCTAssertEqual(song.key, Key(e.key), e.file)
            XCTAssertEqual(song.sections.compactMap(\.label), e.sections, e.file)
            for line in e.lines { XCTAssertTrue(cho.contains(line), "\(e.file) missing: \(line)") }
            XCTAssertFalse(cho.contains("\u{FFFD}"), "\(e.file) has unresolved ligature")
            XCTAssertFalse(cho.contains("Key - "), "\(e.file) key row leaked into body")
        }
    }

    func testRowMergeAttachesChordToWordStart() {
        func g(_ s: String, x: CGFloat, y: CGFloat, bold: Bool) -> [PDFGlyph] {
            s.enumerated().map { i, c in
                PDFGlyph(char: c, rect: CGRect(x: x + CGFloat(i) * 7, y: y, width: 7, height: 12), bold: bold, size: 12)
            }
        }
        let page = g("Title", x: 40, y: 700, bold: true)
            + g("VERSE 1", x: 40, y: 660, bold: true)
            + g("G", x: 54, y: 640, bold: true) + g("D/F#", x: 110, y: 640, bold: true)
            + g("A", x: 40, y: 626, bold: false) + g("mazing", x: 54, y: 626, bold: false)
            + g("grace", x: 110, y: 626, bold: false)
        let cho = ChordSheetLayout.chordPro(pages: [page])
        XCTAssertTrue(cho.contains("A [G]mazing [D/F#]grace"), cho)
        XCTAssertTrue(cho.contains("{comment: Verse 1}"))
    }
}
