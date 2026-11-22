import Foundation
import ChordProKit

// Usage:
//   chordpro <file> [--to <Key> | --by <semitones>] [--render]
// Prints transposed ChordPro (or chords-over-lyrics text with --render).

var args = Array(CommandLine.arguments.dropFirst())
func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}
guard let path = args.first else {
    fail("usage: chordpro <file.cho> [--to <Key> | --by <semitones>] [--render]")
}
args.removeFirst()

var text: String
if path.lowercased().hasSuffix(".pdf") {
    do { text = try PDFChordSheetImporter.chordPro(fromPDF: URL(fileURLWithPath: path)) }
    catch { fail("\(error)") }
} else {
    guard let data = FileManager.default.contents(atPath: path),
          let t = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
        fail("could not read \(path)")
    }
    text = t
}
text = text.replacingOccurrences(of: "\r\n", with: "\n")

var render = false
var i = 0
while i < args.count {
    switch args[i] {
    case "--to":
        guard i + 1 < args.count, let k = Key(args[i + 1]) else { fail("--to needs a key like A, Bb, F#m") }
        do { text = try Transposer.transpose(chordPro: text, toKey: k) } catch { fail("\(error)") }
        i += 2
    case "--by":
        guard i + 1 < args.count, let n = Int(args[i + 1]) else { fail("--by needs an integer") }
        text = Transposer.transpose(chordPro: text, by: n)
        i += 2
    case "--render":
        render = true
        i += 1
    default:
        fail("unknown argument \(args[i])")
    }
}

let output = render ? ChordProDocument(text).renderPlainText() : text
print(output, terminator: output.hasSuffix("\n") ? "" : "\n")
