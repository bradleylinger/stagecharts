import Foundation

/// Minimal ChordPro reader: metadata directives + rendering chords above lyrics.
public struct ChordProDocument {
    public let text: String
    public private(set) var directives: [String: String] = [:]

    public init(_ text: String) {
        self.text = text
        for line in text.components(separatedBy: .newlines) {
            if let d = Self.directive(in: line), directives[d.name] == nil {
                directives[d.name] = d.value
            }
        }
    }

    public var title: String? { directives["title"] ?? directives["t"] }
    public var key: Key? { directives["key"].flatMap(Key.init) }

    /// Returns `text` with the {name: value} directive set (replaced, inserted after the header
    /// directives, or removed when value is nil/empty).
    public static func setting(_ name: String, to value: String?, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let existing = lines.firstIndex { directive(in: $0)?.name == name }
        let new = value.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : "{\(name): \($0)}" }
        switch (existing, new) {
        case let (i?, line?): lines[i] = line
        case let (i?, nil): lines.remove(at: i)
        case let (nil, line?):
            // after the last leading directive (title/artist/key…), before the song body
            var insertAt = 0
            for (i, l) in lines.enumerated() {
                if let d = directive(in: l), !["comment", "c", "soc", "start_of_chorus"].contains(d.name) { insertAt = i + 1 }
                else if !l.trimmingCharacters(in: .whitespaces).isEmpty { break }
            }
            lines.insert(line, at: insertAt)
        case (nil, nil): break
        }
        return lines.joined(separator: "\n")
    }

    /// Parses "{name: value}" / "{name}" lines. Names are lowercased.
    static func directive(in line: String) -> (name: String, value: String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("{"), t.hasSuffix("}") else { return nil }
        let inner = t.dropFirst().dropLast()
        if let colon = inner.firstIndex(of: ":") {
            let name = inner[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = inner[inner.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return (name, value)
        }
        return (inner.trimmingCharacters(in: .whitespaces).lowercased(), "")
    }

    /// Renders as plain text with chords on their own line above the lyrics.
    public func renderPlainText() -> String {
        var out: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if let d = Self.directive(in: line) {
                switch d.name {
                case "title", "t": out.append(d.value.uppercased())
                case "comment", "c", "comment_italic", "ci": out.append("[\(d.value)]")
                case "start_of_chorus", "soc": out.append("[Chorus]")
                case "key", "tempo", "time", "artist", "subtitle", "st", "copyright", "ccli":
                    out.append("\(d.name.capitalized): \(d.value)")
                default: break
                }
                continue
            }
            guard line.contains("[") else { out.append(line); continue }

            var chordLine = ""
            var lyricLine = ""
            var i = line.startIndex
            while i < line.endIndex {
                if line[i] == "[", let close = line[i...].firstIndex(of: "]") {
                    let chord = String(line[line.index(after: i)..<close])
                    // Pad lyrics if the previous chord would collide with this one.
                    if chordLine.count > lyricLine.count {
                        lyricLine += String(repeating: " ", count: chordLine.count - lyricLine.count)
                    }
                    chordLine += String(repeating: " ", count: lyricLine.count - chordLine.count)
                    chordLine += chord + " "
                    i = line.index(after: close)
                } else {
                    lyricLine.append(line[i])
                    i = line.index(after: i)
                }
            }
            out.append(chordLine.trimmingCharacters(in: .whitespaces).isEmpty ? "" : chordLine.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
            if !lyricLine.trimmingCharacters(in: .whitespaces).isEmpty { out.append(lyricLine) }
        }
        return out.joined(separator: "\n")
    }
}

extension ChordProDocument {
    /// Plain lines that are really chord lines (e.g. "Em7(4)* A7sus (*alt. G2 )" — footnote marks
    /// kept a PDF converter from seeing them as chords) are rewritten as bracketed chords, so they're
    /// styled and transposed like the rest of the chart.
    public static func bracketingChordOnlyLines(_ text: String) -> String {
        guard text.contains("\n") else { return text }
        return text.components(separatedBy: "\n").map { chordOnlyLine($0) ?? $0 }.joined(separator: "\n")
    }

    /// A chord symbol built only from real chord parts, so words like "Ending" or "Coda" don't count.
    static let chordPattern = #"^[A-G][#b♯♭]?(maj|min|dim|aug|sus|add|omit|no|m|M|Δ|ø|°|\+|-|\^|[0-9]|[#b♯♭]|\(|\))*(/[A-G][#b♯♭]?)?$"#

    static func chordOnlyLine(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.contains("["), !t.hasPrefix("{"), !t.hasPrefix("#") else { return nil }
        // Tokens, keeping "( … )" groups together.
        var tokens: [String] = [], group: String? = nil
        for w in t.split(separator: " ").map(String.init) {
            if var g = group {
                g += " " + w
                if w.hasSuffix(")") { tokens.append(g); group = nil } else { group = g }
            } else if w.hasPrefix("("), !w.hasSuffix(")") {
                group = w
            } else {
                tokens.append(w)
            }
        }
        if let g = group { tokens.append(g) }
        var chords = 0
        for tok in tokens {
            if tok.hasPrefix("(") && tok.hasSuffix(")") { continue }            // note such as "(*alt. G2 )"
            if tok == "|" || tok == "/" { continue }
            let core = tok.hasSuffix("*") ? String(tok.dropLast()) : tok
            guard core.range(of: Self.chordPattern, options: .regularExpression) != nil,
                  Transposer.transposeChord(core, by: 0, preferFlats: false) != nil else { return nil }
            chords += 1
        }
        // A lone word like "A" could be lyrics; need two chords, or a chord plus a note.
        guard chords >= 2 || (chords == 1 && tokens.count > 1) else { return nil }
        return tokens.map { tok -> String in
            if tok == "|" || tok == "/" { return tok }
            if tok.hasPrefix("(") { return "[(" + tok.dropFirst().dropLast().trimmingCharacters(in: .whitespaces) + ")]" }
            return "[\(tok)]"
        }.joined(separator: " ")
    }
}
