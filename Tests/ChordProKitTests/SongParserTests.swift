import XCTest
@testable import ChordProKit

final class SongParserTests: XCTestCase {
    func testSegments() {
        let segs = ChordProSong.segments(of: "A - [G]mazing [G/D]grace  [D7]how")
        XCTAssertEqual(segs, [
            Segment(chord: nil, lyric: "A - "),
            Segment(chord: "G", lyric: "mazing "),
            Segment(chord: "G/D", lyric: "grace "),
            Segment(chord: "D7", lyric: "how"),
        ])
        XCTAssertEqual(ChordProSong.segments(of: "[G] [C] [D]").map(\.chord), ["G", "C", "D"])
    }

    func testSongSelectFile() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("samples/Amazing Grace (SongSelect 22025).chordpro")
        let song = ChordProSong(try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(song.title, "Amazing Grace")
        XCTAssertEqual(song.source, .songSelectChordPro)      // SongSelect's own ChordPro download
        XCTAssertEqual(song.key, Key("G"))
        XCTAssertEqual(song.tempo, "90")
        XCTAssertEqual(song.time, "3/4")
        XCTAssertEqual(song.ccli, "22025")
        XCTAssertEqual(song.artists.count, 2)
        XCTAssertEqual(song.sections.map(\.label), (1...6).map { "Verse \($0)" })
        XCTAssertEqual(song.sections[0].lines.count, 4)
        // Copyright trailer must not leak into the last verse.
        XCTAssertEqual(song.sections[5].lines.count, 4)
    }

    func testChartSources() {
        XCTAssertEqual(ChordProSong("{title: A}\n{x_pdf: A.pdf}\n{x_doc: Word}").source, .pdfDocument)
        XCTAssertEqual(ChordProSong("{title: A}\n{x_pdf: A.pdf}").documentKind, nil)
        XCTAssertEqual(ChordProSong("{title: A}\n{x_source: onsong-songselect}\n[G]a").source, .onSongSongSelect)
        XCTAssertFalse(ChartSource.pdfDocument.isTransposable)
        XCTAssertTrue(ChartSource.convertedPDF.rank > ChartSource.pdfDocument.rank)
        XCTAssertTrue(ChartSource.songSelectChordPro.rank > ChartSource.onSongSongSelect.rank)
    }

    func testEditTempoAndTime() {
        let src = "{title: X}\n{key: G}\n{tempo: 72}\n\n{comment: Verse 1}\n[G]one"
        var t = ChordProDocument.setting("tempo", to: "76", in: src)
        t = ChordProDocument.setting("time", to: "6/8", in: t)
        let song = ChordProSong(t)
        XCTAssertEqual(song.tempo, "76")
        XCTAssertEqual(song.time, "6/8")
        XCTAssertEqual(song.sections.first?.label, "Verse 1")
        XCTAssertNil(ChordProSong(ChordProDocument.setting("tempo", to: nil, in: t)).tempo)
    }

    func testChorusBlocksAndPlainLabels() {
        let song = ChordProSong("""
        {title: X}
        Verse 1
        [G]one
        {soc}
        [C]two
        {eoc}
        Bridge:
        [D]three
        {chorus}
        """)
        XCTAssertEqual(song.sections.map(\.label), ["Verse 1", "Chorus", "Bridge", "Chorus"])
        XCTAssertEqual(song.sections.map(\.isChorus), [false, true, false, true])
    }
}
