import SwiftUI

/// Visual theme for charts.
enum ChartStyle: String, CaseIterable, Identifiable {
    case classic    // SongSelect look: black on white
    case stage      // classic inverted: white on black

    var id: String { rawValue }
    var title: String { self == .classic ? "Classic (black on white)" : "Dark (white on black)" }
    var colorScheme: ColorScheme { self == .classic ? .light : .dark }
    var background: Color { self == .classic ? .white : .black }
    var text: Color { self == .classic ? .black : .white }
    var chord: Color { self == .classic ? .black : .white }
    var secondary: Color { self == .classic ? Color(white: 0.3) : Color(white: 0.65) }
}

/// Column setting: auto picks two columns when the chart area is wide enough.
enum ChartColumns: String, CaseIterable, Identifiable {
    case auto, one, two
    var id: String { rawValue }
    var title: String {
        switch self { case .auto: return "Auto"; case .one: return "1 column"; case .two: return "2 columns" }
    }
    func count(forWidth width: CGFloat, textSize: CGFloat) -> Int {
        switch self {
        case .one: return 1
        case .two: return 2
        case .auto: return width >= textSize * 40 ? 2 : 1   // ~880pt at default size
        }
    }
}

enum ChartFonts {
    /// SongSelect titles/headings use Verdana Bold; fall back to the system font if missing.
    static func heading(_ size: CGFloat) -> Font { .custom("Verdana-Bold", size: size) }
    static func lyric(_ size: CGFloat) -> Font { .system(size: size) }
    static func chord(_ size: CGFloat) -> Font { .system(size: size, weight: .bold) }
}

/// Formats a chord SongSelect-style: root (+ "m") on the line, extensions raised and smaller,
/// slash bass on the line — e.g. A²⁽ⁿᵒ³⁾, F#⁷ˢᵘˢ, Bm⁷, E/G#.
enum ChordLabel {
    static func text(_ chord: String, size: CGFloat, color: Color) -> Text {
        guard let first = chord.first, "ABCDEFG".contains(first) else {
            // Annotations like "(1.)", "(To Tag)", "x2"
            return Text(chord).font(.system(size: size * 0.8, weight: .semibold)).foregroundColor(color)
        }
        var rest = Substring(chord.dropFirst())
        var base = String(first)
        if let acc = rest.first, "#b♯♭".contains(acc) { base.append(acc); rest = rest.dropFirst() }

        var bass = ""
        if let slash = rest.lastIndex(of: "/") {
            let after = rest[rest.index(after: slash)...]
            if let n = after.first, "ABCDEFG".contains(n), after.count <= 2 {
                bass = "/" + after
                rest = rest[..<slash]
            }
        }
        if rest.hasPrefix("m") && !rest.hasPrefix("maj") { base.append("m"); rest = rest.dropFirst() }

        var t = Text(base).font(ChartFonts.chord(size))
        if !rest.isEmpty {
            t = t + Text(String(rest)).font(ChartFonts.chord(size * 0.62)).baselineOffset(size * 0.42)
        }
        if !bass.isEmpty { t = t + Text(bass).font(ChartFonts.chord(size)) }
        return t.foregroundColor(color)
    }
}

extension Color {
    /// Accent for chords in dark stage mode and for highlights in settings.
    static let chord = Color(red: 1.0, green: 0.62, blue: 0.2)
}
