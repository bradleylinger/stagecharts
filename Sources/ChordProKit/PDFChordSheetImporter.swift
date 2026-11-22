#if canImport(PDFKit)
import Foundation
import PDFKit
#if os(macOS)
import AppKit
private typealias PlatformFont = NSFont
#else
import UIKit
private typealias PlatformFont = UIFont
#endif

/// Converts a SongSelect-style PDF chord sheet into ChordPro text.
public enum PDFChordSheetImporter {
    public enum ImportError: Error, CustomStringConvertible {
        case unreadable, noText
        public var description: String {
            switch self {
            case .unreadable: return "Couldn't open the PDF."
            case .noText: return "This PDF has no text layer (it may be a scan), so it can't be converted."
            }
        }
    }

    public static func chordPro(fromPDF url: URL) throws -> String {
        guard let doc = PDFDocument(url: url) else { throw ImportError.unreadable }
        return try chordPro(from: doc)
    }

    public static func chordPro(from doc: PDFDocument, relaxed: Bool = false) throws -> String {
        var pages: [[PDFGlyph]] = []
        var width: CGFloat = 612
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            width = page.bounds(for: .mediaBox).width
            pages.append(glyphs(on: page))
        }
        guard pages.contains(where: { !$0.isEmpty }) else { throw ImportError.noText }
        return resolveLigatures(ChordSheetLayout.chordPro(pages: pages, pageWidth: width, relaxed: relaxed))
    }

    static let ligaturePlaceholder: Character = "\u{FFFD}"

    /// Replaces ligature placeholders with whichever of fi/fl/ff/ffi/ffl makes a real word.
    static func resolveLigatures(_ text: String) -> String {
        guard text.contains(ligaturePlaceholder) else { return text }
        let options = ["fi", "fl", "ff", "ffi", "ffl"]
        // Include syllable continuations ("af?ec - tion") and chord markers inside the word, so the
        // spell check sees the whole word ("affection").
        let regex = try! NSRegularExpression(pattern: "[\\p{L}\u{FFFD}'’]*\u{FFFD}[\\p{L}\u{FFFD}'’]*(?:\\s+-\\s+(?:\\[[^\\]]*\\])?[\\p{L}'’]+)*")
        var result = text
        let ns = text as NSString
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let word = ns.substring(with: m.range)
            let whole = word.replacingOccurrences(of: #"\s+-\s+|\[[^\]]*\]"#, with: "", options: .regularExpression)
            let choice = options.first { isWord(whole.replacingOccurrences(of: "\u{FFFD}", with: $0)) } ?? "fi"
            let fixed = word.replacingOccurrences(of: "\u{FFFD}", with: choice)
            result = (result as NSString).replacingCharacters(in: m.range, with: fixed)
        }
        return result
    }

    static func isWord(_ word: String) -> Bool {
        let w = word.trimmingCharacters(in: CharacterSet(charactersIn: "'’"))
        #if os(macOS)
        let r = NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: "en", wrap: false,
                                                    inSpellDocumentWithTag: 0, wordCount: nil)
        return r.location == NSNotFound
        #else
        let r = UITextChecker().rangeOfMisspelledWord(in: w, range: NSRange(location: 0, length: (w as NSString).length),
                                                      startingAt: 0, wrap: false, language: "en")
        return r.location == NSNotFound
        #endif
    }

    static func glyphs(on page: PDFPage) -> [PDFGlyph] {
        guard let text = page.string else { return [] }
        let ns = text as NSString
        let attr = page.attributedString
        let fontsAligned = attr?.length == ns.length
        var result: [PDFGlyph] = []
        result.reserveCapacity(ns.length)
        for i in 0..<ns.length {
            let piece = ns.substring(with: NSRange(location: i, length: 1))
            guard var ch = piece.first, !ch.isWhitespace else { continue }
            // SongSelect PDFs map the "fi"/"fl" ligature glyph to U+0000. Keep a placeholder
            // and resolve the spelling afterwards; drop any other control characters.
            if ch == "\u{0}" { ch = ligaturePlaceholder }
            else if ch.unicodeScalars.first.map({ CharacterSet.controlCharacters.contains($0) }) ?? true { continue }
            // Note: page.characterBounds(at:) drifts by one index after each line break,
            // so use a one-character selection, which is accurate.
            guard let rect = page.selection(for: NSRange(location: i, length: 1))?.bounds(for: page) else { continue }
            guard rect.width > 0, rect.height > 0 else { continue }
            var bold = false
            var size = rect.height
            if fontsAligned, let font = attr?.attribute(.font, at: i, effectiveRange: nil) as? PlatformFont {
                let name = font.fontName.lowercased()
                bold = name.contains("bold") || name.contains("black") || name.contains("heavy")
                size = font.pointSize
            }
            result.append(PDFGlyph(char: ch, rect: rect, bold: bold, size: size))
        }
        return result
    }
}
#endif
