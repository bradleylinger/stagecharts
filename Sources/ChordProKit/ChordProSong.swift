import Foundation

/// A chord sitting above a run of lyric text.
public struct Segment: Equatable, Hashable {
    public var chord: String?
    public var lyric: String
    public init(chord: String?, lyric: String) { self.chord = chord; self.lyric = lyric }
}

/// One rendered line of a song body.
public enum SongLine: Equatable, Hashable {
    case lyrics([Segment])      // chords + lyrics (or chords only, or lyrics only)
    case label(String)          // section heading: "Verse 1", "Chorus"
    case comment(String)        // other inline notes
    case blank
}

public struct SongSection: Equatable, Hashable, Identifiable {
    public let id: Int
    public var label: String?
    public var isChorus: Bool
    public var lines: [SongLine]
}

/// Where a chart came from: SongSelect's own ChordPro download (best), a converted PDF, or other ChordPro.
public enum ChartSource: String {
    case songSelectChordPro, convertedPDF, otherChordPro

    public var isChordPro: Bool { self != .convertedPDF }
}

/// Parsed ChordPro song, ready for display.
public struct ChordProSong: Equatable {
    public var title: String
    public var artists: [String]
    public var subtitles: [String]
    public var key: Key?
    public var tempo: String?
    public var time: String?
    public var ccli: String?
    public var copyright: String?
    public var sections: [SongSection]
    public var meta: [String: String]

    public var source: ChartSource {
        if meta["x_source"] == "songselect-pdf" { return .convertedPDF }
        if meta["ccli_license"] != nil || (meta["footer"] ?? "").contains("SongSelect") { return .songSelectChordPro }
        // Converted before the marker existed: SongSelect metadata but no ChordPro license/footer lines.
        if ccli != nil && copyright != nil { return .convertedPDF }
        return .otherChordPro
    }

    /// Section names SongSelect / other tools put in plain text or {comment:}.
    static let sectionPattern = try! NSRegularExpression(
        pattern: #"^(verse|chorus|pre-?chorus|bridge|intro|outro|tag|ending|interlude|instrumental|refrain|turnaround|vamp|coda|misc)(\s*\d+[a-z]?(\s*/\s*\d+[a-z]?)*)?\s*:?$"#,
        options: [.caseInsensitive])

    static func looksLikeSectionLabel(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return sectionPattern.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

    public init(_ text: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var meta: [String: String] = [:]
        var artists: [String] = []
        var subtitles: [String] = []
        var sections: [SongSection] = []
        var current = SongSection(id: 0, label: nil, isChorus: false, lines: [])
        var trailerStarted = false

        func flush() {
            // Trim blank lines at both ends of a section.
            while current.lines.first == .blank { current.lines.removeFirst() }
            while current.lines.last == .blank { current.lines.removeLast() }
            if current.label != nil || !current.lines.isEmpty { sections.append(current) }
        }
        func startSection(_ label: String?, chorus: Bool) {
            flush()
            current = SongSection(id: sections.count, label: label, isChorus: chorus, lines: [])
        }

        for raw in normalized.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)

            // SongSelect appends a plain-text copyright trailer after the song body.
            if line.hasPrefix("CCLI Song #") || line.hasPrefix("CCLI License #") || line.hasPrefix("©")
                || line.hasPrefix("For use solely with the SongSelect") {
                trailerStarted = true
            }
            if trailerStarted { continue }

            if let d = ChordProDocument.directive(in: line) {
                switch d.name {
                case "title", "t": meta["title"] = d.value
                case "artist", "composer", "lyricist": artists.append(d.value)
                case "subtitle", "st": subtitles.append(d.value)
                case "comment", "c", "comment_italic", "ci", "comment_box", "cb", "highlight":
                    if Self.looksLikeSectionLabel(d.value) {
                        startSection(d.value, chorus: d.value.lowercased().hasPrefix("chorus"))
                    } else {
                        current.lines.append(.comment(d.value))
                    }
                case "start_of_chorus", "soc":
                    startSection(d.value.isEmpty ? "Chorus" : d.value, chorus: true)
                case "end_of_chorus", "eoc":
                    startSection(nil, chorus: false)
                case "start_of_verse", "sov", "start_of_bridge", "sob":
                    let def = d.name.contains("bridge") || d.name == "sob" ? "Bridge" : "Verse"
                    startSection(d.value.isEmpty ? def : d.value, chorus: false)
                case "end_of_verse", "eov", "end_of_bridge", "eob":
                    startSection(nil, chorus: false)
                case "chorus":
                    // "{chorus}" = repeat the chorus here.
                    startSection(d.value.isEmpty ? "Chorus" : d.value, chorus: true)
                    current.lines.append(.comment("(repeat)"))
                default:
                    meta[d.name] = d.value
                }
                continue
            }

            if line.hasPrefix("#") { continue } // ChordPro comment line
            if line.isEmpty { current.lines.append(.blank); continue }
            if !line.contains("["), Self.looksLikeSectionLabel(line) {
                startSection(line.hasSuffix(":") ? String(line.dropLast()) : line,
                             chorus: line.lowercased().hasPrefix("chorus"))
                continue
            }
            current.lines.append(.lyrics(Self.segments(of: raw)))
        }
        flush()

        self.title = meta["title"] ?? "Untitled"
        self.artists = artists
        self.subtitles = subtitles
        self.key = meta["key"].flatMap(Key.init)
        self.tempo = meta["tempo"]
        self.time = meta["time"]?.trimmingCharacters(in: .whitespaces)
        self.ccli = meta["ccli"]
        self.copyright = meta["copyright"]
        self.sections = sections
        self.meta = meta
    }

    /// Splits "A - [G]mazing [G/D]grace" into [(nil,"A - "), ("G","mazing "), ("G/D","grace")].
    public static func segments(of line: String) -> [Segment] {
        var result: [Segment] = []
        var chord: String? = nil
        var lyric = ""
        var i = line.startIndex
        while i < line.endIndex {
            if line[i] == "[", let close = line[i...].firstIndex(of: "]") {
                if chord != nil || !lyric.isEmpty { result.append(Segment(chord: chord, lyric: lyric)) }
                chord = String(line[line.index(after: i)..<close])
                lyric = ""
                i = line.index(after: close)
            } else {
                lyric.append(line[i])
                i = line.index(after: i)
            }
        }
        if chord != nil || !lyric.isEmpty { result.append(Segment(chord: chord, lyric: lyric)) }
        // Collapse SongSelect's alignment padding ("grace  [D7]how") to single spaces.
        return result.map { seg in
            var s = seg
            s.lyric = s.lyric.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            return s
        }
    }
}
