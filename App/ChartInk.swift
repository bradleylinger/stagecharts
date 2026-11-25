import SwiftUI
import PencilKit

/// Pencil markings on a chart. Strokes are stored per section, relative to the section's lyric column
/// and in units of a 22-point chart, so they stay with their section when the key, text size, columns or
/// device change.
struct ChartInk: Codable, Equatable {
    /// Section id → PKDrawing data.
    var sections: [String: Data] = [:]
    var isEmpty: Bool { sections.isEmpty }

    static let referenceSize: CGFloat = 22

    func drawing(section: Int) -> PKDrawing? {
        sections[String(section)].flatMap { try? PKDrawing(data: $0) }
    }
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

// MARK: - Placing strokes

enum InkGeometry {
    /// Chart points per stored unit.
    static func scale(_ size: CGFloat) -> CGFloat { size / ChartInk.referenceSize }

    /// Stored section drawing → chart coordinates (anchor = the section's lyric column top-left).
    static func place(_ d: PKDrawing, at anchor: CGPoint, size: CGFloat) -> PKDrawing {
        let k = scale(size)
        return d.transformed(using: CGAffineTransform(scaleX: k, y: k).concatenating(.init(translationX: anchor.x, y: anchor.y)))
    }

    /// Splits a drawing in chart coordinates into sections: each stroke goes with the section it's on
    /// (or the nearest one), stored relative to that section's anchor.
    static func split(_ drawing: PKDrawing, frames: [Int: CGRect], anchors: [Int: CGPoint], size: CGFloat) -> ChartInk {
        guard !frames.isEmpty else { return ChartInk() }
        var bySection: [Int: [PKStroke]] = [:]
        for stroke in drawing.strokes {
            let c = CGPoint(x: stroke.renderBounds.midX, y: stroke.renderBounds.midY)
            let id = frames.min { distance(c, $0.value) < distance(c, $1.value) }!.key
            bySection[id, default: []].append(stroke)
        }
        let k = scale(size)
        var ink = ChartInk()
        for (id, strokes) in bySection {
            let a = anchors[id] ?? frames[id]!.origin
            let back = CGAffineTransform(translationX: -a.x, y: -a.y).concatenating(.init(scaleX: 1 / k, y: 1 / k))
            ink.sections[String(id)] = PKDrawing(strokes: strokes).transformed(using: back).dataRepresentation()
        }
        return ink
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }
}

// MARK: - Showing markings

/// A section's markings drawn on top of it (not interactive). Strokes may reach outside the section.
struct InkOverlay: View {
    let drawings: [PKDrawing]      // stored units, relative to the anchor
    let size: CGFloat
    let dark: Bool
    var anchorX: CGFloat = 0
    @Environment(\.displayScale) private var displayScale
    @State private var rendered: (image: Image, rect: CGRect)?

    private var key: String {
        drawings.map { "\($0.strokes.count):\($0.bounds):\($0.dataRepresentation().hashValue)" }.joined(separator: ",") + "|\(size)|\(dark)|\(displayScale)"
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let r = rendered {
                r.image.resizable()
                    .frame(width: r.rect.width, height: r.rect.height)
                    .offset(x: anchorX + r.rect.minX, y: r.rect.minY)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
