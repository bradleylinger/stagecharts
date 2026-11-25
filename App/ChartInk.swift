import SwiftUI
import PencilKit

/// Pencil markings on a chart. Each stroke is stored relative to the word (or line or heading) it was drawn on
/// and in units of a 22-point chart, so they stay with their section when the key, text size, columns or
/// device change.
struct ChartInk: Codable, Equatable {
    /// Anchor (see InkAnchorsKey) → PKDrawing data. (Named "sections" because the first version anchored to sections.)
    var sections: [String: Data] = [:]
    var isEmpty: Bool { sections.isEmpty }

    static let referenceSize: CGFloat = 22

}

/// Where a set of markings belongs: the song everywhere, or one song in one set.
enum InkLayer: Hashable {
    case song(String)
    case setItem(UUID)

    var fileName: String {
        switch self {
        case .song(let id): return Self.safe(id) + ".ink"
        case .setItem(let id): return "set-\(id.uuidString).ink"
        }
    }
    private static func safe(_ s: String) -> String {
        String(s.map { "/:\\".contains($0) ? "_" : $0 })
    }
}

extension SongLibrary {
    var inkFolder: URL { base.appendingPathComponent("Ink", isDirectory: true) }

    func ink(_ layer: InkLayer) -> ChartInk {
        if let cached = inkCache.value[layer] { return cached }
        let url = inkFolder.appendingPathComponent(layer.fileName)
        let ink = Self.coordinatedData(url).flatMap { try? JSONDecoder().decode(ChartInk.self, from: $0) } ?? ChartInk()
        inkCache.value[layer] = ink
        return ink
    }

    func setInk(_ ink: ChartInk, for layer: InkLayer) {
        guard ink != self.ink(layer) else { return }
        inkCache.value[layer] = ink
        let url = inkFolder.appendingPathComponent(layer.fileName)
        if ink.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? FileManager.default.createDirectory(at: inkFolder, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(ink) { Self.coordinatedWrite(data, to: url) }
        }
        inkRevision += 1
        onLocalChange?()
    }
}

/// Holds loaded markings without publishing (reads happen during view updates).
final class InkCache {
    var value: [InkLayer: ChartInk] = [:]
}

#if os(iOS)
typealias PlatformColor = UIColor
#else
typealias PlatformColor = NSColor
#endif

// MARK: - Anchors

/// Where each heading, line and word is on the chart: "3" (section's lyric column), "3.h" (heading),
/// "3.5" (line 5) and "3.5.2" (word 2 of line 5). Markings are stored relative to one of these.
struct InkAnchorsKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { a, _ in a }
    }
}

extension View {
    func inkAnchor(_ key: String?) -> some View {
        anchorPreference(key: InkAnchorsKey.self, value: .bounds) { a in key.map { [$0: a] } ?? [:] }
    }
}

/// Latest anchor frames, read when starting to draw and when saving (not observed).
final class InkFrames {
    var value: [String: CGRect] = [:]
}

// MARK: - Placing strokes

enum InkGeometry {
    /// Chart points per stored unit.
    static func scale(_ size: CGFloat) -> CGFloat { size / ChartInk.referenceSize }

    /// Stored drawing → chart coordinates (relative to its anchor's top-left).
    static func place(_ d: PKDrawing, at anchor: CGPoint, size: CGFloat) -> PKDrawing {
        let k = scale(size)
        return d.transformed(using: CGAffineTransform(scaleX: k, y: k).concatenating(.init(translationX: anchor.x, y: anchor.y)))
    }

    /// Splits a drawing in chart coordinates by anchor: each stroke goes with the word (or line or heading)
    /// it's on or nearest to, stored relative to that word's top-left, so it moves with the word when lines re-wrap.
    static func split(_ drawing: PKDrawing, frames: [String: CGRect], size: CGFloat) -> ChartInk {
        let specific = frames.filter { $0.key.contains(".") }
        let candidates = specific.isEmpty ? frames : specific
        guard !candidates.isEmpty else { return ChartInk() }
        var byAnchor: [String: [PKStroke]] = [:]
        for stroke in drawing.strokes {
            let c = CGPoint(x: stroke.renderBounds.midX, y: stroke.renderBounds.midY)
            let containing = candidates.filter { $0.value.contains(c) }
            let key = containing.isEmpty
                ? candidates.min { distance(c, $0.value) < distance(c, $1.value) }!.key
                : containing.min { area($0.value) < area($1.value) }!.key
            byAnchor[key, default: []].append(stroke)
        }
        let k = scale(size)
        var ink = ChartInk()
        for (key, strokes) in byAnchor {
            let a = frames[key]!.origin
            let back = CGAffineTransform(translationX: -a.x, y: -a.y).concatenating(.init(scaleX: 1 / k, y: 1 / k))
            ink.sections[key] = PKDrawing(strokes: strokes).transformed(using: back).dataRepresentation()
        }
        return ink
    }

    #if DEBUG
    /// Test strokes: underline words 2–5 of the first line of section 1, circle word 1 of section 2's first line.
    static func demo(frames: [String: CGRect]) -> PKDrawing {
        func stroke(_ pts: [CGPoint], _ color: PlatformColor) -> PKStroke {
            let p = pts.enumerated().map { i, pt in
                PKStrokePoint(location: pt, timeOffset: Double(i) * 0.01, size: CGSize(width: 4, height: 4),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: p, creationDate: Date()))
        }
        var strokes: [PKStroke] = []
        for w in 2...5 {
            if let f = frames["1.0.\(w)"] {
                strokes.append(stroke([CGPoint(x: f.minX, y: f.maxY + 2), CGPoint(x: f.maxX, y: f.maxY + 2)], .systemRed))
            }
        }
        if let f = frames["2.0.1"] {
            let c = CGPoint(x: f.midX, y: f.midY)
            let rx: CGFloat = f.width / 2 + 8, ry: CGFloat = f.height / 2 + 6
            var pts: [CGPoint] = []
            for i in 0...40 {
                let t = CGFloat(i) / 40 * 2 * .pi
                pts.append(CGPoint(x: c.x + rx * cos(t), y: c.y + ry * sin(t)))
            }
            strokes.append(stroke(pts, .systemBlue))
        }
        return PKDrawing(strokes: strokes)
    }
    #endif

    private static func area(_ r: CGRect) -> CGFloat { r.width * r.height }
    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }
}

// MARK: - Showing markings

/// All markings on the chart, each drawn at its anchor's current place.
struct InkLayerView: View {
    let ink: [String: [PKDrawing]]
    let frames: [String: CGRect]
    let size: CGFloat
    let dark: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(ink.keys.sorted(), id: \.self) { key in
                if let f = frames[key] {
                    InkStrokes(drawings: ink[key]!, size: size, dark: dark).offset(x: f.minX, y: f.minY)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One anchor's strokes as an image (re-rendered only when the strokes, size or colours change).
private struct InkStrokes: View {
    let drawings: [PKDrawing]      // stored units, relative to the anchor
    let size: CGFloat
    let dark: Bool
    @Environment(\.displayScale) private var displayScale
    @State private var rendered: (image: Image, rect: CGRect)?

    private var key: String {
        drawings.map { "\($0.strokes.count):\($0.bounds):\($0.dataRepresentation().hashValue)" }.joined(separator: ",")
            + "|\(size)|\(dark)|\(displayScale)"
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let r = rendered {
                r.image.resizable()
                    .frame(width: r.rect.width, height: r.rect.height)
                    .offset(x: r.rect.minX, y: r.rect.minY)
            }
        }
        .frame(width: 0, height: 0, alignment: .topLeading)
        .task(id: key) { rendered = render() }
    }

    private func render() -> (Image, CGRect)? {
        var all = PKDrawing()
        for d in drawings { all.append(InkGeometry.place(d, at: .zero, size: size)) }
        let b = all.bounds.integral
        guard !b.isEmpty else { return nil }
        #if os(iOS)
        var img = UIImage()
        UITraitCollection(userInterfaceStyle: dark ? .dark : .light).performAsCurrent {
            img = all.image(from: b, scale: displayScale)
        }
        return (Image(uiImage: img), b)
        #else
        var img = NSImage()
        (NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            img = all.image(from: b, scale: displayScale)
        }
        return (Image(nsImage: img), b)
        #endif
    }
}

// MARK: - Drawing (iPhone / iPad)

#if os(iOS)
/// A transparent PencilKit canvas laid over the whole chart while marking up.
struct InkCanvas: UIViewRepresentable {
    let seed: PKDrawing
    let seedID: UUID
    let dark: Bool
    let fingerDraws: Bool
    let handMode: Bool
    let onChange: (PKDrawing) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeUIView(context: Context) -> ChartCanvasView {
        let v = ChartCanvasView()
        v.backgroundColor = .clear
        v.isOpaque = false
        v.isScrollEnabled = false
        v.contentInsetAdjustmentBehavior = .never
        v.delegate = context.coordinator
        v.tool = PKInkingTool(.pen, color: .black, width: 3)
        context.coordinator.seedID = seedID
        v.drawing = seed
        context.coordinator.picker.addObserver(v)
        v.picker = context.coordinator.picker
        update(v)
        return v
    }

    func updateUIView(_ v: ChartCanvasView, context: Context) {
        context.coordinator.onChange = onChange
        if context.coordinator.seedID != seedID {
            context.coordinator.seedID = seedID
            context.coordinator.loading = true
            v.drawing = seed
            context.coordinator.loading = false
        }
        update(v)
    }

    private func update(_ v: ChartCanvasView) {
        v.overrideUserInterfaceStyle = dark ? .dark : .light
        v.picker?.colorUserInterfaceStyle = dark ? .dark : .light
        v.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
        v.isUserInteractionEnabled = !handMode
    }

    static func dismantleUIView(_ v: ChartCanvasView, coordinator: Coordinator) {
        coordinator.picker.setVisible(false, forFirstResponder: v)
        coordinator.picker.removeObserver(v)
        v.resignFirstResponder()
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var onChange: (PKDrawing) -> Void
        var seedID = UUID()
        var loading = false
        let picker = PKToolPicker()
        init(onChange: @escaping (PKDrawing) -> Void) { self.onChange = onChange }
        func canvasViewDrawingDidChange(_ v: PKCanvasView) {
            if !loading { onChange(v.drawing) }
        }
    }
}

/// Shows the tool picker once on screen, and keeps the chart's scroll view from scrolling under the pencil
/// (fingers still scroll it).
final class ChartCanvasView: PKCanvasView {
    var picker: PKToolPicker?
    private weak var outer: UIScrollView?
    private var savedTypes: [NSNumber]?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            var s = superview
            while let v = s, !(v is UIScrollView) { s = v.superview }
            if let sv = s as? UIScrollView {
                outer = sv
                savedTypes = sv.panGestureRecognizer.allowedTouchTypes
                sv.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.picker?.setVisible(true, forFirstResponder: self)
                self.becomeFirstResponder()
            }
        } else if let sv = outer {
            if let savedTypes { sv.panGestureRecognizer.allowedTouchTypes = savedTypes }
            outer = nil
        }
    }
}
#endif
