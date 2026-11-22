import Foundation
import CoreGraphics

/// One positioned character from a PDF page (PDF coordinates: y grows upward).
public struct PDFGlyph: Equatable {
    public var char: Character
    public var rect: CGRect
    public var bold: Bool
    public var size: CGFloat
    public init(char: Character, rect: CGRect, bold: Bool, size: CGFloat) {
        self.char = char; self.rect = rect; self.bold = bold; self.size = size
    }
}

/// Rebuilds ChordPro text from the positioned glyphs of a "chords over lyrics" chord sheet
/// (layout used by SongSelect PDF chord sheets). Pure logic, no PDFKit, so it's unit-testable.
public enum ChordSheetLayout {

    struct Row {
        var glyphs: [PDFGlyph]          // sorted left → right
        var midY: CGFloat
        var minX: CGFloat { glyphs.first?.rect.minX ?? 0 }
        var size: CGFloat { glyphs.map(\.size).max() ?? 12 }
        var boldFraction: Double {
            glyphs.isEmpty ? 0 : Double(glyphs.filter(\.bold).count) / Double(glyphs.count)
        }
        var text: String { ChordSheetLayout.join(glyphs) }
    }

    struct Token { var text: String; var minX: CGFloat }

    /// Converts all pages. `pages` = glyphs per page, `pageWidth` for column detection.
    public static func chordPro(pages: [[PDFGlyph]], pageWidth: CGFloat = 612) -> String {
        var rows: [Row] = []
        for (index, glyphs) in pages.enumerated() {
            rows += rowsInReadingOrder(glyphs, pageWidth: pageWidth, firstPage: index == 0)
        }
        return build(rows)
    }

    // MARK: Rows

    /// Groups glyphs into visual rows in reading order. Two-column sheets are detected by an
    /// empty vertical gutter in the body; the left column is read fully before the right one.
    /// The title block (page 1) and the copyright footer span the full width and are kept whole.
    static func rowsInReadingOrder(_ glyphs: [PDFGlyph], pageWidth: CGFloat, firstPage: Bool) -> [Row] {
        var all = groupRows(glyphs)
        // Page 2+ starts with a running header like "Holy Forever - 2".
        if !firstPage, let first = all.first,
           first.text.range(of: #" - \d+$"#, options: .regularExpression) != nil {
            all.removeFirst()
        }
        guard !all.isEmpty else { return [] }

        // Header = rows above the first section label (first page only).
        var headerRows: [Row] = []
        var bodyTop = CGFloat.infinity
        if firstPage {
            guard let firstLabel = all.firstIndex(where: hasLabelChunk) else { return all }
            headerRows = Array(all[..<firstLabel])
            bodyTop = all[firstLabel].midY + 2
        }
        // Footer = from "CCLI Song #" down.
        let footerIndex = all.firstIndex { $0.text.hasPrefix("CCLI Song #") || $0.text.hasPrefix("©") }
        let footerRows = footerIndex.map { Array(all[$0...]) } ?? []
        let footerTop = footerIndex.map { all[$0].midY + 2 } ?? -CGFloat.infinity

        let body = glyphs.filter { $0.rect.midY <= bodyTop && $0.rect.midY > footerTop }
        let bodyRows = all.filter { $0.midY <= bodyTop && $0.midY > footerTop }
        guard let split = gutter(body, pageWidth: pageWidth) else {
            return headerRows + bodyRows + footerRows
        }
        let left = groupRows(body.filter { $0.rect.midX < split })
        let right = groupRows(body.filter { $0.rect.midX >= split })
        return headerRows + left + right + footerRows
    }

    /// x position of an empty vertical strip near the page centre, if the body has two columns.
    static func gutter(_ glyphs: [PDFGlyph], pageWidth: CGFloat) -> CGFloat? {
        guard glyphs.count > 20 else { return nil }
        let lo = Int(pageWidth * 0.3), hi = Int(pageWidth * 0.7)
        var covered = [Bool](repeating: false, count: hi - lo + 1)
        for g in glyphs {
            let a = max(lo, Int(g.rect.minX.rounded(.down))), b = min(hi, Int(g.rect.maxX.rounded(.up)))
            if a <= b { for x in a...b { covered[x - lo] = true } }
        }
        // Longest uncovered run.
        var best = (start: 0, len: 0), runStart = -1
        for (i, c) in covered.enumerated() {
            if !c { if runStart < 0 { runStart = i } ; if i - runStart + 1 > best.len { best = (runStart, i - runStart + 1) } }
            else { runStart = -1 }
        }
        guard best.len >= 8 else { return nil }
        let x = CGFloat(lo + best.start) + CGFloat(best.len) / 2
        // Both sides must actually hold text.
        let leftCount = glyphs.filter { $0.rect.midX < x }.count
        let rightCount = glyphs.count - leftCount
        return min(leftCount, rightCount) > glyphs.count / 10 ? x : nil
    }

    /// True if any widely-separated chunk of the row is a section label ("VERSE 1   VERSE 2").
    static func hasLabelChunk(_ row: Row) -> Bool {
        var chunks: [[PDFGlyph]] = [[]]
        for g in row.glyphs {
            if let p = chunks[chunks.count - 1].last, g.rect.minX - p.rect.maxX > row.size * 1.5 { chunks.append([]) }
            chunks[chunks.count - 1].append(g)
        }
        return chunks.contains { ChordProSong.looksLikeSectionLabel(join($0)) }
    }

    static func groupRows(_ glyphs: [PDFGlyph]) -> [Row] {
        let sorted = glyphs.sorted { $0.rect.midY > $1.rect.midY }
        var rows: [Row] = []
        for g in sorted {
            // Superscripts (the "2" in Eb2) sit ~3pt higher; chord/lyric rows are ~12pt apart.
            if var last = rows.last, abs(last.midY - g.rect.midY) <= max(4, g.size * 0.38) {
                last.glyphs.append(g)
                rows[rows.count - 1] = last
            } else {
                rows.append(Row(glyphs: [g], midY: g.rect.midY))
            }
        }
        return rows.map { r in
            var r = r
            r.glyphs.sort { $0.rect.minX < $1.rect.minX }
            // Use the dominant (full-size) glyphs' centre as the row position.
            let big = r.glyphs.filter { $0.size >= r.size - 0.5 }
            r.midY = big.map(\.rect.midY).reduce(0, +) / CGFloat(max(1, big.count))
            return r
        }
    }

    /// Joins glyphs into text, inserting spaces at visual gaps.
    static func join(_ glyphs: [PDFGlyph]) -> String {
        var out = ""
        var prev: PDFGlyph?
        for g in glyphs {
            if let p = prev, g.rect.minX - p.rect.maxX > p.size * 0.15 { out += " " }
            out.append(g.char)
            prev = g
        }
        return out
    }

    /// Tokens with consecutive non-chord words merged: "(To" "Tag)" -> "(To Tag)".
    static func chordTokens(_ row: Row) -> [Token] {
        var out: [Token] = []
        for t in tokens(row) {
            if let last = out.last, !isChord(last.text), !barSymbols.contains(last.text),
               !isChord(t.text), !barSymbols.contains(t.text) {
                out[out.count - 1].text += " " + t.text
            } else {
                out.append(t)
            }
        }
        return out
    }

    static func tokens(_ row: Row) -> [Token] {
        var result: [Token] = []
        var current: [PDFGlyph] = []
        for g in row.glyphs {
            if let p = current.last, g.rect.minX - p.rect.maxX > p.size * 0.15 {
                result.append(Token(text: String(current.map(\.char)), minX: current[0].rect.minX))
                current = []
            }
            current.append(g)
        }
        if !current.isEmpty { result.append(Token(text: String(current.map(\.char)), minX: current[0].rect.minX)) }
        return result
    }

    // MARK: Classification

    static let barSymbols: Set<String> = ["|", "||", ".", "/", "%", "-", "(", ")", ":", "|:", ":|", "||:", ":||"]

    /// "No chord" markers count as chords for row detection (kept as-is, never transposed).
    static let noChordMarks: Set<String> = ["N.C.", "N.C", "NC", "(N.C.)"]

    static func isChord(_ s: String) -> Bool {
        if noChordMarks.contains(s) { return true }
        var t = s
        if t.hasPrefix("(") && t.hasSuffix(")") && t.count > 2 { t = String(t.dropFirst().dropLast()) }
        return Transposer.transposeChord(t, by: 0, preferFlats: false) != nil
    }

    static func isKeyTempoRow(_ row: Row) -> Bool {
        let t = row.text
        return t.contains("Key - ") || t.contains("Tempo - ") || t.contains("Time - ")
    }

    static func isLabel(_ row: Row) -> Bool {
        ChordProSong.looksLikeSectionLabel(row.text)
    }

    static func isChordRow(_ row: Row) -> Bool {
        guard row.boldFraction > 0.7, !isLabel(row), !isKeyTempoRow(row) else { return false }
        // Merged tokens: "(To" "Verse" "1)" → "(To Verse 1)". Allowed besides chords: bar symbols,
        // bracketed annotations like "(1.)", "(To Chorus)", "(Last x)", and repeat marks like "x2".
        let toks = chordTokens(row).map(\.text)
        let chords = toks.filter(isChord).count
        let other = toks.filter { t in
            !isChord(t) && barSymbols.contains(t) || (!isChord(t) && t.hasPrefix("(") && t.hasSuffix(")"))
                || (!isChord(t) && t.range(of: #"^[xX]\d+$"#, options: .regularExpression) != nil)
        }.count
        return chords > 0 && chords + other == toks.count
    }

    // MARK: Build ChordPro

    static func build(_ rows: [Row]) -> String {
        var out: [String] = []
        var i = 0

        // Header: everything above the first section label / chord row.
        var header: [Row] = []
        while i < rows.count, !isLabel(rows[i]), !isChordRow(rows[i]) { header.append(rows[i]); i += 1 }
        out += headerDirectives(header)

        var copyright: [String] = []
        var ccli: String?
        var inCopyright = false

        while i < rows.count {
            let row = rows[i]
            let text = row.text.trimmingCharacters(in: .whitespaces)

            // Footer
            if text.hasPrefix("CCLI Song #") {
                ccli = text.replacingOccurrences(of: "CCLI Song #", with: "").trimmingCharacters(in: .whitespaces)
                inCopyright = false; i += 1; continue
            }
            if text.hasPrefix("©") { inCopyright = true; copyright.append(String(text.dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1; continue }
            if text.hasPrefix("For use solely with") || text.hasPrefix("CCLI License #") || text.hasPrefix("Note: Reproduction") {
                inCopyright = false; i += 1; continue
            }
            if inCopyright { copyright.append(text); i += 1; continue }

            if isLabel(row) {
                if !out.isEmpty && out.last != "" { out.append("") }
                let label = text.hasSuffix(":") ? String(text.dropLast()) : text
                out.append("{comment: \(label.capitalized)}")
                i += 1; continue
            }

            if isChordRow(row) {
                let next = i + 1 < rows.count ? rows[i + 1] : nil
                if let lyric = next, !isChordRow(lyric), !isLabel(lyric),
                   row.midY - lyric.midY < row.size * 1.8,
                   !lyric.text.hasPrefix("CCLI Song #"), !lyric.text.hasPrefix("©") {
                    out.append(merge(chords: chordTokens(row), lyrics: lyric.glyphs))
                    i += 2
                } else {
                    out.append(chordOnlyLine(chordTokens(row)))
                    i += 1
                }
                continue
            }

            out.append(text)   // lyric line without chords
            i += 1
        }

        if let ccli { out.append(""); out.insert("{ccli: \(ccli)}", at: min(out.count, headerEnd(out))) }
        if !copyright.isEmpty {
            out.insert("{copyright: \(copyright.joined(separator: " "))}", at: min(out.count, headerEnd(out)))
        }
        while out.last == "" { out.removeLast() }
        return out.joined(separator: "\n") + "\n"
    }

    /// Index just after the leading block of {directives}.
    static func headerEnd(_ lines: [String]) -> Int {
        var n = 0
        while n < lines.count, lines[n].hasPrefix("{"), !lines[n].hasPrefix("{comment") { n += 1 }
        return n
    }

    static func headerDirectives(_ rows: [Row]) -> [String] {
        var out: [String] = []
        for (n, row) in rows.enumerated() {
            let t = row.text.trimmingCharacters(in: .whitespaces)
            if n == 0 { out.append("{title: \(t)}"); continue }
            if t.contains("Key - ") || t.contains("Tempo - ") || t.contains("Time - ") {
                if let k = capture(#"Key - ([A-G][#b♯♭]?m?)"#, t) { out.append("{key: \(k)}") }
                if let v = capture(#"Tempo - (\d+)"#, t) { out.append("{tempo: \(v)}") }
                if let v = capture(#"Time - (\d+/\d+)"#, t) { out.append("{time: \(v)}") }
                continue
            }
            if t.hasPrefix("(") {
                if let k = capture(#"original key: ([A-G][#b♯♭]?m?)"#, t) { out.append("{x_original_key: \(k)}") }
                out.append("{subtitle: \(t.trimmingCharacters(in: CharacterSet(charactersIn: "()")))}")
                continue
            }
            out.append("{artist: \(t)}")
        }
        out.insert("{x_source: songselect-pdf}", at: min(1, out.count))   // marks charts converted from PDF
        out.append("")
        return out
    }

    static func capture(_ pattern: String, _ s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    /// Inserts [chord] markers into the lyric at the character under each chord's left edge.
    static func merge(chords: [Token], lyrics: [PDFGlyph]) -> String {
        var out = ""
        var ci = 0
        var prev: PDFGlyph?
        for g in lyrics {
            let gap = prev.map { g.rect.minX - $0.rect.maxX } ?? 0
            if prev != nil, gap > (prev?.size ?? 12) * 0.15 { out += " " }
            while ci < chords.count, chords[ci].minX <= g.rect.minX + 1.5 {
                out += "[\(chords[ci].text)]"
                ci += 1
            }
            out.append(g.char)
            prev = g
        }
        while ci < chords.count {      // chords past the end of the lyric
            out += " [\(chords[ci].text)]"
            ci += 1
        }
        return out
    }

    static func chordOnlyLine(_ tokens: [Token]) -> String {
        tokens.map { isChord($0.text) ? "[\($0.text)]" : $0.text }.joined(separator: " ")
    }
}
