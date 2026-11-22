import Foundation

/// Pitch-class math and note spelling for transposing chord symbols.
public enum Note {
    static let sharpNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    static let flatNames  = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
    static let letterPC: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]

    /// Parses a note like "C", "F#", "Bb", "E♭" at the start of `s`.
    /// Returns pitch class and the number of characters consumed.
    static func parse(_ s: Substring) -> (pc: Int, length: Int)? {
        guard let first = s.first, let base = letterPC[first] else { return nil }
        var pc = base
        var len = 1
        let rest = s.dropFirst()
        if let acc = rest.first {
            switch acc {
            case "#", "♯": pc += 1; len += 1
            case "b", "♭": pc -= 1; len += 1
            default: break
            }
        }
        return ((pc + 12) % 12, len)
    }

    static func name(_ pc: Int, preferFlats: Bool) -> String {
        let i = ((pc % 12) + 12) % 12
        return preferFlats ? flatNames[i] : sharpNames[i]
    }
}

/// A musical key such as "G", "Bb", "F#m".
public struct Key: Equatable, CustomStringConvertible {
    public let root: Int        // pitch class 0-11
    public let isMinor: Bool

    // Conventional spellings for each key (fewest accidentals; common worship-chart usage).
    static let majorNames = ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    static let minorNames = ["Cm", "C#m", "Dm", "Ebm", "Em", "Fm", "F#m", "Gm", "G#m", "Am", "Bbm", "Bm"]

    public init(root: Int, isMinor: Bool) {
        self.root = ((root % 12) + 12) % 12
        self.isMinor = isMinor
    }

    public init?(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let (pc, len) = Note.parse(Substring(t)) else { return nil }
        let suffix = t.dropFirst(len).lowercased()
        let minor: Bool
        switch suffix {
        case "", "maj", "major": minor = false
        case "m", "min", "minor", "-": minor = true
        default: return nil
        }
        self.init(root: pc, isMinor: minor)
    }

    public var description: String {
        isMinor ? Key.minorNames[root] : Key.majorNames[root]
    }

    /// Whether chords in this key should be spelled with flats.
    public var prefersFlats: Bool {
        description.contains("b") || description == "F" || description == "Dm"
    }

    public func transposed(by semitones: Int) -> Key {
        Key(root: root + semitones, isMinor: isMinor)
    }

    /// Smallest signed interval (-5...+6) to move from self to `other`.
    public func semitones(to other: Key) -> Int {
        var d = ((other.root - root) % 12 + 12) % 12
        if d > 6 { d -= 12 }
        return d
    }
}

public enum Transposer {
    /// Transposes a single chord symbol, e.g. "G/B", "Bbsus4", "F#m7b5", "C6/9".
    /// Returns nil if the text isn't a recognizable chord (e.g. "N.C.", "x2").
    public static func transposeChord(_ chord: String, by semitones: Int, preferFlats: Bool) -> String? {
        // Bracketed chords such as "(Bb)" or "(F/A)": transpose what's inside.
        if chord.hasPrefix("("), chord.hasSuffix(")"), chord.count > 2 {
            let inside = String(chord.dropFirst().dropLast())
            if let inner = transposeChord(inside, by: semitones, preferFlats: preferFlats) { return "(" + inner + ")" }
            // Notes naming an alternative chord, e.g. "(*alt. G2)": transpose the chord words in them.
            if inside.lowercased().contains("alt") || inside.hasPrefix("*") {
                return "(" + inside.split(separator: " ").map { w in
                    w.count > 1 ? (transposeChord(String(w), by: semitones, preferFlats: preferFlats) ?? String(w)) : String(w)
                }.joined(separator: " ") + ")"
            }
        }
        let s = Substring(chord)
        guard let (rootPC, rootLen) = Note.parse(s) else { return nil }
        var body = String(s.dropFirst(rootLen))
        var bass = ""

        // Slash bass: only when the part after the LAST "/" is a bare note (so "6/9" stays intact).
        if let slash = body.lastIndex(of: "/") {
            let after = body[body.index(after: slash)...]
            if let (bassPC, bassLen) = Note.parse(after), bassLen == after.count {
                bass = "/" + Note.name(bassPC + semitones, preferFlats: preferFlats)
                body = String(body[..<slash])
            }
        }

        // Sanity check the quality text so lyric-ish brackets don't get mangled.
        let allowed = CharacterSet(charactersIn: "majminMdimaugsus+-()#b♯♭°ø/0123456789add^Δnoomit*")   // * = footnote mark
        guard body.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }

        return Note.name(rootPC + semitones, preferFlats: preferFlats) + body + bass
    }

    /// Transposes a whole ChordPro document: inline [chords] and the {key:} directive.
    public static func transpose(chordPro text: String, by semitones: Int, preferFlats: Bool? = nil) -> String {
        let doc = ChordProDocument(text)
        let flats: Bool
        if let p = preferFlats { flats = p }
        else if let k = doc.key { flats = k.transposed(by: semitones).prefersFlats }
        else { flats = false }

        var out: [String] = []
        for line in ChordProDocument.bracketingChordOnlyLines(text).components(separatedBy: "\n") {
            out.append(transposeLine(line, by: semitones, preferFlats: flats))
        }
        return out.joined(separator: "\n")
    }

    /// Transposes to a named target key (e.g. "A", "Bb"). Requires the source key in {key:}.
    public static func transpose(chordPro text: String, toKey target: Key) throws -> String {
        guard let source = ChordProDocument(text).key else { throw TransposeError.missingSourceKey }
        let shift = source.semitones(to: target)
        return transpose(chordPro: text, by: shift, preferFlats: target.prefersFlats)
    }

    static func transposeLine(_ line: String, by semitones: Int, preferFlats: Bool) -> String {
        // {key: X} directive
        if let d = ChordProDocument.directive(in: line), d.name == "key", let k = Key(d.value) {
            return "{key: \(k.transposed(by: semitones))}"
        }
        // Inline [Chord] markers
        var result = ""
        var i = line.startIndex
        while i < line.endIndex {
            if line[i] == "[", let close = line[i...].firstIndex(of: "]") {
                let inner = String(line[line.index(after: i)..<close])
                let replaced = transposeChord(inner, by: semitones, preferFlats: preferFlats) ?? inner
                result += "[\(replaced)]"
                i = line.index(after: close)
            } else {
                result.append(line[i])
                i = line.index(after: i)
            }
        }
        return result
    }
}

public enum TransposeError: Error, CustomStringConvertible {
    case missingSourceKey
    public var description: String { "Song has no {key: ...} directive; transpose by semitones instead." }
}
