import SwiftUI
import ChordProKit

/// Wraps a chord on the chart so tapping it shows how to play it (guitar or piano).
struct ChordTapTarget<Label: View>: View {
    let chord: String
    @ViewBuilder let label: () -> Label
    @AppStorage("chordTapHelp") private var enabled = true
    @State private var showing = false

    var body: some View {
        if enabled, ChordSpelling.parse(chord) != nil {
            label()
                .contentShape(Rectangle())
                .onTapGesture { showing = true }
                .popover(isPresented: $showing) {
                    ChordHelpView(chord: chord)
                        .modifier(CompactSheet())
                }
        } else {
            label()
        }
    }
}

/// On iPhone the popover becomes a half-height sheet.
private struct CompactSheet: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, macOS 13.3, *) {
            content.presentationDetents([.medium, .large]).presentationCompactAdaptation(.sheet)
        } else {
            content
        }
    }
}

enum ChordInstrument: String, CaseIterable, Identifiable {
    case guitar, piano
    var id: String { rawValue }
    var title: String { self == .guitar ? "Guitar" : "Piano" }
}

/// The chord's notes and how to play them.
struct ChordHelpView: View {
    let chord: String
    @AppStorage("chordHelpInstrument") private var instrumentRaw = ChordInstrument.guitar.rawValue
    @State private var shape = 0
    @State private var fingerings: [GuitarFingering] = []

    private var spelling: ChordSpelling? { ChordSpelling.parse(chord) }
    private var instrument: ChordInstrument { ChordInstrument(rawValue: instrumentRaw) ?? .guitar }

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                ChordLabel.text(chord, size: 30, color: .primary)
                Spacer()
                if let s = spelling {
                    Text(s.noteNames.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                }
            }
            Picker("Instrument", selection: $instrumentRaw) {
                ForEach(ChordInstrument.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let s = spelling {
                switch instrument {
                case .guitar: guitar
                case .piano: PianoDiagram(notes: Piano.notes(for: s), spelling: s).frame(height: 130)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
        .task(id: chord) {
            shape = 0
            if let s = spelling { fingerings = Guitar.fingerings(for: s) }
        }
    }

    @ViewBuilder private var guitar: some View {
        if fingerings.isEmpty {
            Text("No guitar shape found for this chord.").foregroundStyle(.secondary).frame(height: 220)
        } else {
            let f = fingerings[min(shape, fingerings.count - 1)]
            VStack(spacing: 8) {
                GuitarDiagram(fingering: f).frame(width: 200, height: 230)
                HStack {
                    Button { shape = (shape + fingerings.count - 1) % fingerings.count } label: {
                        Image(systemName: "chevron.left")
                    }
                    Text("Shape \(shape + 1) of \(fingerings.count)").font(.callout.monospacedDigit())
                        .frame(minWidth: 110)
                    Button { shape = (shape + 1) % fingerings.count } label: {
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.bordered)
                Text(f.tab.map(String.init).joined(separator: " ").uppercased())
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }
}

/// A chord box: strings low E (left) to high E (right), the nut or a fret number, dots, barre, x/o markers.
struct GuitarDiagram: View {
    let fingering: GuitarFingering
    private let fretsShown = 5

    var body: some View {
        Canvas { ctx, size in
            let f = fingering.frets
            let top: CGFloat = 30, left: CGFloat = 34, right: CGFloat = 14, bottom: CGFloat = 6
            let w = size.width - left - right, h = size.height - top - bottom
            let sx = w / 5, fy = h / CGFloat(fretsShown)
            let first = fingering.highestFret <= fretsShown ? 1 : fingering.lowestFret
            let line = GraphicsContext.Shading.color(.primary)

            // Strings and frets
            for s in 0..<6 {
                var p = Path(); p.move(to: .init(x: left + CGFloat(s) * sx, y: top)); p.addLine(to: .init(x: left + CGFloat(s) * sx, y: top + h))
                ctx.stroke(p, with: line, lineWidth: 1)
            }
            for i in 0...fretsShown {
                var p = Path(); let y = top + CGFloat(i) * fy
                p.move(to: .init(x: left, y: y)); p.addLine(to: .init(x: left + w, y: y))
                ctx.stroke(p, with: line, lineWidth: i == 0 && first == 1 ? 5 : 1)
            }
            if first > 1 {
                ctx.draw(Text("\(first)fr").font(.system(size: 13, weight: .semibold)),
                         at: .init(x: left - 18, y: top + fy / 2))
            }
            // x / o above the nut
            for s in 0..<6 where f[s] <= 0 {
                ctx.draw(Text(f[s] < 0 ? "×" : "○").font(.system(size: 15, weight: .medium)),
                         at: .init(x: left + CGFloat(s) * sx, y: top - 13))
            }
            let dot = min(sx, fy) * 0.62
            func center(_ s: Int, _ fret: Int) -> CGPoint {
                .init(x: left + CGFloat(s) * sx, y: top + (CGFloat(fret - first) + 0.5) * fy)
            }
            if let b = fingering.barre {
                let a = center(b.from, b.fret), z = center(b.to, b.fret)
                let r = CGRect(x: a.x - dot / 2, y: a.y - dot / 2, width: z.x - a.x + dot, height: dot)
                ctx.fill(Path(roundedRect: r, cornerRadius: dot / 2), with: .color(.accentColor))
            }
            for s in 0..<6 where f[s] > 0 && !(fingering.barre.map { $0.fret == f[s] && (s >= $0.from && s <= $0.to) } ?? false) {
                let c = center(s, f[s])
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - dot / 2, y: c.y - dot / 2, width: dot, height: dot)),
                         with: .color(.accentColor))
            }
        }
        .accessibilityLabel("Guitar chord \(fingering.tab)")
    }
}

/// A keyboard spanning the chord's notes with the chord tones highlighted and named.
struct PianoDiagram: View {
    let notes: [Int]          // MIDI note numbers
    let spelling: ChordSpelling

    var body: some View {
        Canvas { ctx, size in
            let lo = ((notes.min() ?? 60) / 12) * 12            // C below the lowest note
            let hi = max(((notes.max() ?? 60) / 12) * 12 + 11, lo + 23)   // at least two octaves
            let whites = (lo...hi).filter { !Self.isBlack($0) }
            let ww = size.width / CGFloat(whites.count), hgt = size.height
            let on = Set(notes)
            var xOf: [Int: CGFloat] = [:]
            for (i, n) in whites.enumerated() {
                let r = CGRect(x: CGFloat(i) * ww, y: 0, width: ww, height: hgt)
                xOf[n] = r.minX
                ctx.fill(Path(r), with: .color(on.contains(n) ? .accentColor : .white))
                ctx.stroke(Path(r), with: .color(.gray), lineWidth: 1)
                if on.contains(n) {
                    ctx.draw(Text(spelling.name(n % 12)).font(.system(size: 12, weight: .bold)).foregroundColor(.white),
                             at: .init(x: r.midX, y: hgt - 14))
                }
                if n % 12 == 0 {
                    ctx.draw(Text("C\(n / 12 - 1)").font(.system(size: 9)).foregroundColor(.gray),
                             at: .init(x: r.midX, y: hgt * 0.62))
                }
            }
            for n in lo...hi where Self.isBlack(n) {
                guard let x = xOf[n - 1] else { continue }
                let bw = ww * 0.62
                let r = CGRect(x: x + ww - bw / 2, y: 0, width: bw, height: hgt * 0.6)
                ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(on.contains(n) ? .accentColor : .black))
                if on.contains(n) {
                    ctx.draw(Text(spelling.name(n % 12)).font(.system(size: 10, weight: .bold)).foregroundColor(.white),
                             at: .init(x: r.midX, y: r.maxY - 11))
                }
            }
        }
        .accessibilityLabel("Piano notes " + spelling.noteNames.joined(separator: ", "))
    }

    static func isBlack(_ n: Int) -> Bool { [1, 3, 6, 8, 10].contains(n % 12) }
}
