import Foundation

/// What notes a chord symbol means, e.g. "F#m7b5" → F# A C E, "G/B" → G B D over B.
public struct ChordSpelling: Equatable {
    public let symbol: String
    public let root: Int                 // pitch class 0–11
    public let bass: Int?                // slash bass, when different from the root
    /// Semitones above the root, ascending (0 first). 14 = 9th, 17 = 11th, 21 = 13th.
    public let intervals: [Int]
    /// Intervals a guitar voicing may leave out (the 5th; the 9th/11th of big extended chords).
    public let optional: Set<Int>
    let preferFlats: Bool

    public var pitchClasses: Set<Int> { Set(intervals.map { (root + $0) % 12 } + [bass].compactMap { $0 }) }
    public var noteNames: [String] {
        var names = intervals.map { Note.name(root + $0, preferFlats: preferFlats) }
        if let bass { names.insert(Note.name(bass, preferFlats: preferFlats), at: 0) }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
    public func name(_ pc: Int) -> String { Note.name(pc, preferFlats: preferFlats) }

    /// nil for things that aren't chords ("N.C.", "x2", "(To Tag)").
    public static func parse(_ chord: String) -> ChordSpelling? {
        var text = chord.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("("), text.hasSuffix(")") { text = String(text.dropFirst().dropLast()) }
        text = text.replacingOccurrences(of: "*", with: "")
        let s = Substring(text)
        guard let (root, rootLen) = Note.parse(s) else { return nil }
        let flats = text.dropFirst().first.map { "b♭".contains($0) } ?? false
        var body = String(s.dropFirst(rootLen))
        var bass: Int?
        if let slash = body.lastIndex(of: "/") {
            let after = body[body.index(after: slash)...]
            if let (b, len) = Note.parse(after), len == after.count {
                bass = b == root ? nil : b
                body = String(body[..<slash])
            }
        }
        guard let (intervals, optional) = quality(body) else { return nil }
        let slashFlat = text.split(separator: "/").last.map { $0.count == 2 && "b♭".contains($0.last!) } ?? false
        return ChordSpelling(symbol: chord, root: root, bass: bass, intervals: intervals, optional: optional,
                             preferFlats: flats || slashFlat || [5, 10, 3, 8].contains(root) && !text.dropFirst().hasPrefix("#"))
    }

    /// Chord quality text → intervals. Handles the usual chart spellings: m, maj7, M7, Δ, 7, 9, 11, 13,
    /// sus, sus2, sus4, 2, 4, add9, add2, 6, 6/9, dim, dim7, °, ø, m7b5, aug, +, 5, b5/#5/b9/#9/#11/b13, no3.
    static func quality(_ raw: String) -> ([Int], Set<Int>)? {
        var q = raw.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
            .replacingOccurrences(of: " ", with: "")
        var third: Int? = 4, fifth: Int? = 7, seventh: Int?
        var extra = Set<Int>(), optional: Set<Int> = [7]
        func take(_ p: String) -> Bool {
            guard q.hasPrefix(p) else { return false }
            q.removeFirst(p.count); return true
        }
        func takeNumber() -> Int? {
            let digits = q.prefix { $0.isNumber }
            guard !digits.isEmpty else { return nil }
            q.removeFirst(digits.count); return Int(digits)
        }

        // Triad
        var majorSeventh = false, isDim = false
        if take("maj") || take("Maj") || take("MA") || take("Δ") || take("^") {
            majorSeventh = true
        } else if q.hasPrefix("M") && !q.hasPrefix("Maj") {
            q.removeFirst(); majorSeventh = true
        } else if take("min") || take("mi") || take("m") || take("-") {
            third = 3
            if take("maj") || take("M") || take("Δ") { majorSeventh = true }     // mMaj7
        } else if take("dim") || take("°") || take("o") {
            third = 3; fifth = 6; isDim = true
        } else if take("ø") {
            third = 3; fifth = 6; seventh = 10
        } else if take("aug") || take("+") {
            fifth = 8
        }

        // Main number: 5, 6, 7, 9, 11, 13, 2, 4
        if let n = takeNumber() {
            switch n {
            case 5 where !majorSeventh: third = nil; optional = []           // power chord
            case 6: extra.insert(9)
            case 7: seventh = majorSeventh ? 11 : (isDim ? 9 : 10)
            case 9: seventh = majorSeventh ? 11 : 10; extra.insert(14)
            case 11: seventh = majorSeventh ? 11 : 10; extra.formUnion([14, 17]); optional.insert(14)
                     if third == 4 { third = nil }                             // 11 chords drop the 3rd
            case 13: seventh = majorSeventh ? 11 : 10; extra.formUnion([14, 21]); optional.insert(14)
            case 2: third = nil; extra.insert(2)                               // worship-chart "G2" = sus2
            case 4: third = nil; extra.insert(5)
            default: return nil
            }
            majorSeventh = false
        }
        if majorSeventh { seventh = 11 }                                        // bare "maj" / "Δ"

        // Everything after: sus, add, alterations, 6/9, no3
        while !q.isEmpty {
            if take("sus") {
                let n = takeNumber() ?? 4
                guard n == 2 || n == 4 || n == 9 else { return nil }
                third = nil; extra.insert(n == 4 ? 5 : 2)
            } else if take("add") {
                guard let n = takeNumber() else { return nil }
                switch n { case 2, 9: extra.insert(n == 2 ? 2 : 14); case 4, 11: extra.insert(n == 4 ? 5 : 17)
                case 6, 13: extra.insert(9); default: return nil }
            } else if take("/9") || take("/") && takeNumber() == 9 {
                extra.insert(14)                                                // 6/9
            } else if take("b5") || take("-5") { fifth = 6; optional.remove(7)
            } else if take("#5") || take("+5") { fifth = 8; optional.remove(7)
            } else if take("b9") || take("-9") { extra.insert(13); seventh = seventh ?? 10
            } else if take("#9") || take("+9") { extra.insert(15); seventh = seventh ?? 10
            } else if take("#11") || take("+11") { extra.insert(18)
            } else if take("b13") || take("-13") { extra.insert(20)
            } else if take("no3") || take("omit3") { third = nil
            } else if take("no5") || take("omit5") { fifth = nil
            } else if let n = takeNumber() {
                switch n { case 9: extra.insert(14); case 11: extra.insert(17); case 13: extra.insert(21)
                case 7: seventh = seventh ?? 10; default: return nil }
            } else if take("M7") || take("maj7") { seventh = 11
            } else {
                return nil
            }
        }

        var set: Set<Int> = [0]
        if let third { set.insert(third) }
        if let fifth { set.insert(fifth) }
        if let seventh { set.insert(seventh) }
        set.formUnion(extra)
        if fifth != 7 { optional.remove(7) }
        return (set.sorted(), optional.intersection(set))
    }
}

/// One way to play a chord on a standard-tuned guitar.
public struct GuitarFingering: Equatable, Hashable {
    /// Low E to high E; -1 = don't play, 0 = open.
    public let frets: [Int]
    /// A barre across `barre.from...barre.to` (string indexes) at `barre.fret`, if used.
    public let barre: Barre?
    public struct Barre: Equatable, Hashable { public let fret, from, to: Int }

    public var lowestFret: Int { frets.filter { $0 > 0 }.min() ?? 0 }
    public var highestFret: Int { frets.max() ?? 0 }
    /// "x32010"
    public var tab: String { frets.map { $0 < 0 ? "x" : ($0 > 9 ? "(\($0))" : String($0)) }.joined() }
}

public enum Guitar {
    /// Standard tuning, MIDI note numbers of the open strings (E2 A2 D3 G3 B3 E4).
    public static let tuning = [40, 45, 50, 55, 59, 64]

    /// Playable fingerings: the standard shape first (when it's a common chord), then others up the neck.
    public static func fingerings(for c: ChordSpelling, limit: Int = 8) -> [GuitarFingering] {
        var out: [GuitarFingering] = []
        if let tab = standard[key(c)] { out.append(fingering(tab)) }
        for f in search(c, limit: limit + 1) where !out.contains(where: { $0.frets == f.frets }) { out.append(f) }
        return Array(out.prefix(limit))
    }

    /// The shapes guitarists learn first (CAGED open chords and the E/A barre shapes).
    static let standardShapes: [String: String] = [
        "C": "x32010", "C#": "x46664", "D": "xx0232", "Eb": "x68886", "E": "022100", "F": "133211",
        "F#": "244322", "G": "320003", "Ab": "466544", "A": "x02220", "Bb": "x13331", "B": "x24442",
        "Cm": "x35543", "C#m": "x46654", "Dm": "xx0231", "Ebm": "x68876", "Em": "022000", "Fm": "133111",
        "F#m": "244222", "Gm": "355333", "G#m": "466444", "Am": "x02210", "Bbm": "x13321", "Bm": "x24432",
        "C7": "x32310", "C#7": "x46464", "D7": "xx0212", "Eb7": "x68686", "E7": "020100", "F7": "131211",
        "F#7": "242322", "G7": "320001", "Ab7": "464544", "A7": "x02020", "Bb7": "x13131", "B7": "x21202",
        "Cm7": "x35343", "C#m7": "x46454", "Dm7": "xx0211", "Ebm7": "x68676", "Em7": "022030", "Fm7": "131111",
        "F#m7": "242222", "Gm7": "353333", "G#m7": "464444", "Am7": "x02010", "Bbm7": "x13121", "Bm7": "x24232",
        "Cmaj7": "x32000", "C#maj7": "x46564", "Dmaj7": "xx0222", "Ebmaj7": "x68786", "Emaj7": "021100",
        "Fmaj7": "xx3210", "F#maj7": "243322", "Gmaj7": "320002", "Abmaj7": "465544", "Amaj7": "x02120",
        "Bbmaj7": "x13231", "Bmaj7": "x24342",
        "Csus4": "x33011", "Dsus4": "xx0233", "Esus4": "022200", "Fsus4": "133311", "Gsus4": "330013",
        "Asus4": "x02230", "Bsus4": "x24452", "Bbsus4": "x13341",
        "Csus2": "x30033", "Dsus2": "xx0230", "Esus2": "024400", "Gsus2": "3x0233", "Asus2": "x02200",
        "Bsus2": "x24422", "Fsus2": "xx3011",
        "Cadd9": "x32033", "Gadd9": "320203", "Eadd9": "024100", "Fadd9": "xx3213",
        "G/B": "x20003", "D/F#": "200232", "C/E": "032010", "C/G": "332010", "Am/G": "302210", "F/A": "x03211",
        "A/C#": "x42220", "D/A": "x00232", "E/G#": "422100", "G/D": "xx0003", "C/B": "x22010", "Em/D": "xx0000",
        "G/F#": "2x0003", "F/C": "x33211", "D/C": "x30232", "A/E": "002220",
        "C6": "x32210", "D6": "xx0202", "E6": "022120", "G6": "320000", "A6": "x02222",
        "Cdim7": "x3424x", "Bdim7": "x2313x", "Bm7b5": "x2323x", "F#m7b5": "2x221x", "Em7b5": "x7878x",
        "Caug": "x32110", "Eaug": "032110",
    ]
    static let standard: [String: String] = {
        var d: [String: String] = [:]
        for (name, tab) in standardShapes { if let c = ChordSpelling.parse(name) { d[key(c)] = tab } }
        return d
    }()
    static func key(_ c: ChordSpelling) -> String { "\(c.root)|\(c.intervals)|\(c.bass ?? -1)" }
    static func fingering(_ tab: String) -> GuitarFingering {
        let frets = tab.map { $0 == "x" ? -1 : Int(String($0))! }
        let fretted = frets.indices.filter { frets[$0] > 0 }
        let minF = fretted.map { frets[$0] }.min() ?? 0
        let atMin = fretted.filter { frets[$0] == minF }
        var barre: GuitarFingering.Barre?
        if fretted.count > 4, let from = atMin.first, let to = frets.indices.last(where: { frets[$0] >= 0 }),
           atMin.count >= 2, (from...to).allSatisfy({ frets[$0] >= minF }) {
            barre = .init(fret: minF, from: from, to: to)
        }
        return GuitarFingering(frets: frets, barre: barre)
    }

    static func search(_ c: ChordSpelling, limit: Int) -> [GuitarFingering] {
        let pcs = c.pitchClasses
        let bass = c.bass ?? c.root
        let required = Set(c.intervals.filter { !c.optional.contains($0) }.map { (c.root + $0) % 12 })
            .union([bass])
        var results: [(GuitarFingering, Double)] = []
        var seen = Set<[Int]>()

        for window in 1...12 {
            // Options per string: muted, open (if in the chord), or a fret in window...window+3.
            let options: [[Int]] = tuning.map { open in
                var o = [-1]
                if pcs.contains(open % 12) { o.append(0) }
                for f in window...(window + 3) where pcs.contains((open + f) % 12) { o.append(f) }
                return o
            }
            var frets = [Int](repeating: -1, count: 6)
            func walk(_ s: Int) {
                if s == 6 {
                    if let scored = evaluate(frets, c: c, bass: bass, required: required), !seen.contains(frets) {
                        seen.insert(frets); results.append(scored)
                    }
                    return
                }
                for f in options[s] { frets[s] = f; walk(s + 1) }
            }
            walk(0)
        }
        return results.sorted { $0.1 < $1.1 }.prefix(limit).map(\.0)
    }

    static func evaluate(_ frets: [Int], c: ChordSpelling, bass: Int, required: Set<Int>) -> (GuitarFingering, Double)? {
        let played = frets.indices.filter { frets[$0] >= 0 }
        guard let low = played.first, played.count >= (c.intervals.count <= 2 ? 3 : 4) else { return nil }
        // Lowest note must be the bass (root, or the slash note).
        guard (tuning[low] + frets[low]) % 12 == bass else { return nil }
        let notes = played.map { (tuning[$0] + frets[$0]) % 12 }
        guard required.isSubset(of: Set(notes)) else { return nil }

        // Mutes: below the lowest note is normal; at most one inside the chord.
        let inner = (low...5).filter { frets[$0] < 0 }.count
        guard inner <= 1 else { return nil }

        // Stretch and fingers.
        let fretted = played.filter { frets[$0] > 0 }
        let minF = fretted.map { frets[$0] }.min() ?? 0, maxF = fretted.map { frets[$0] }.max() ?? 0
        guard maxF - minF <= 3 else { return nil }
        // Open strings only go with shapes near the nut.
        if played.contains(where: { frets[$0] == 0 }) && maxF > 4 { return nil }
        var barre: GuitarFingering.Barre?
        var fingers = fretted.count
        if fingers > 4 || (minF >= 2 && fretted.filter { frets[$0] == minF }.count >= 2) {
            // Barre with the index finger at the lowest fret, from the first string at that fret to the top.
            let atMin = fretted.filter { frets[$0] == minF }
            guard let from = atMin.first, let to = played.last, atMin.count >= 2 else { return nil }
            // Every string under the barre must be fretted at or above it (no open/muted strings).
            guard (from...to).allSatisfy({ frets[$0] >= minF }) else {
                if fingers > 4 { return nil }
                return finish(frets, nil, fingers, played, inner, low, minF, c)
            }
            barre = .init(fret: minF, from: from, to: to)
            fingers = 1 + fretted.filter { frets[$0] > minF }.count
        }
        guard fingers <= 4 else { return nil }
        return finish(frets, barre, fingers, played, inner, low, minF, c)
    }

    private static func finish(_ frets: [Int], _ barre: GuitarFingering.Barre?, _ fingers: Int, _ played: [Int],
                               _ inner: Int, _ low: Int, _ minF: Int, _ c: ChordSpelling) -> (GuitarFingering, Double) {
        let opens = played.filter { frets[$0] == 0 }.count
        let notes = Set(played.map { (tuning[$0] + frets[$0]) % 12 })
        let missingOptional = c.intervals.filter { c.optional.contains($0) && !notes.contains((c.root + $0) % 12) }.count
        var score = Double(minF) * 0.9
        score += Double(6 - played.count) * 0.8        // fewer strings = thinner
        score += Double(inner) * 2.5
        score += Double(fingers) * 0.35
        score += barre == nil ? 0 : 1.2
        score -= Double(opens) * (minF <= 3 ? 0.4 : -0.6)   // open strings with a high shape = awkward
        score += Double(missingOptional) * 0.6
        if frets[5] < 0 { score += 0.7 }                // top string muted
        if low > 2 { score += 1.5 }                     // only the top 3–4 strings
        return (GuitarFingering(frets: frets, barre: barre), score)
    }
}

public enum Piano {
    /// MIDI notes for a simple voicing: bass an octave below, chord tones stacked from the root near middle C.
    public static func notes(for c: ChordSpelling) -> [Int] {
        let base = 48 + c.root + (c.root >= 7 ? 0 : 12)     // root between G3 and F#4
        var out = c.intervals.map { base + $0 }
        if let b = c.bass {
            var n = 36 + b
            if n + 12 < out[0] - 12 { n += 12 }
            out.insert(n, at: 0)
        }
        return out
    }
}
