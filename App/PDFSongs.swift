import SwiftUI
import PDFKit
import ChordProKit

// PDF-only songs: a small ChordPro "stub" (title, key, CCLI… plus {x_pdf: file.pdf}) whose original
// document lives in Songs/PDF/. They work in set lists, MIDI, notes and band sync, but can't change key.

extension SongFile {
    /// The original document for PDF-only songs.
    var pdfURL: URL? {
        song.pdfFile.map { url.deletingLastPathComponent().appendingPathComponent("PDF", isDirectory: true).appendingPathComponent($0) }
    }
    /// The document a converted chart was made from, if it was kept.
    var originalURL: URL? {
        song.originalFile.map { url.deletingLastPathComponent().appendingPathComponent("PDF", isDirectory: true).appendingPathComponent($0) }
    }

    /// Where the chart came from, in words (shown under the chart).
    var sourceDescription: String {
        let s = song
        switch s.meta["x_source"] {
        case "ai":
            let kind = s.originalKind.map { $0 == "Image" ? "a photo" : "a \($0) document" } ?? "a document"
            return "Chart: converted with AI from \(kind)"
        case "songselect-pdf": return "Chart: converted from a SongSelect PDF"
        case "chord-chart": return "Chart: converted from a PDF chord chart"
        case "onsong-songselect": return "Chart: from OnSong's SongSelect import"
        default:
            switch s.source {
            case .songSelectChordPro: return "Chart: SongSelect ChordPro"
            case .otherChordPro: return "Chart: ChordPro"
            case .convertedPDF, .onSongSongSelect: return "Chart: converted from a PDF"
            case .pdfDocument: return "Chart: original \(s.documentKind ?? "PDF")"
            }
        }
    }
}

/// Shows a chart's original document (PDF or photo) as-is.
struct OriginalDocumentSheet: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetNavigation {
            Group {
                if url.pathExtension.lowercased() == "pdf" {
                    PDFKitView(url: url, command: nil)
                } else if let data = SongLibrary.coordinatedData(url), let image = platformImage(data) {
                    ScrollView { image.resizable().scaledToFit().padding() }
                } else {
                    Text("The original file isn't available on this device.").foregroundColor(.secondary).padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
            .navigationTitle("Original – \(title)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 700, minHeight: 800)
        #endif
    }

    private func platformImage(_ data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map { Image(nsImage: $0) }
        #else
        UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }
}

/// PDFKit view that also follows page / scroll / section commands (MIDI, pedals, band leader).
struct PDFKitView {
    let url: URL
    let command: MIDIController.Command?

    final class Coordinator { var lastSeq = -1 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    private func configure(_ v: PDFView) {
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        if v.document?.documentURL != url {
            // Cloud folders may not have the file locally yet: a coordinated read downloads it.
            v.document = PDFDocument(url: url) ?? SongLibrary.coordinatedData(url).flatMap { PDFDocument(data: $0) }
        }
    }

    private func apply(_ v: PDFView, _ c: Coordinator) {
        guard let command, command.seq != c.lastSeq, let doc = v.document, doc.pageCount > 0 else { return }
        c.lastSeq = command.seq
        func go(_ i: Int) { if let p = doc.page(at: max(0, min(doc.pageCount - 1, i))) { v.go(to: p) } }
        let current = v.currentPage.map { doc.index(for: $0) } ?? 0
        switch command.action {
        case .pageDown, .nextSection: go(current + 1)
        case .pageUp, .previousSection: go(current - 1)
        case .scrollTo(let f): go(Int((Double(doc.pageCount - 1) * f).rounded()))
        case .goToSection(let n): go(n - 1)
        default: break
        }
    }
}

#if os(iOS)
extension PDFKitView: UIViewRepresentable {
    func makeUIView(context: Context) -> PDFView { let v = PDFView(); configure(v); return v }
    func updateUIView(_ v: PDFView, context: Context) { configure(v); apply(v, context.coordinator) }
}
#else
extension PDFKitView: NSViewRepresentable {
    func makeNSView(context: Context) -> PDFView { let v = PDFView(); configure(v); return v }
    func updateNSView(_ v: PDFView, context: Context) { configure(v); apply(v, context.coordinator) }
}
#endif

/// Compact title bar shown above a PDF-only song (the PDF has its own header).
struct PDFSongBar: View {
    let file: SongFile
    let key: Key?
    let tempo: Int?
    let capo: Int
    let notes: [SongNote]
    var onTapNote: (SongNote) -> Void = { _ in }
    var onGetFromSongSelect: (() -> Void)? = nil
    var onConvertWithAI: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(file.song.title).font(.headline)
                if let key { Text("Key \(key.description)").font(.subheadline.bold()) }
                if let tempo { Text("\(tempo) BPM").font(.subheadline).foregroundColor(.secondary) }
                if capo > 0 {
                    Text("CAPO \(capo)").font(.caption.bold()).foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 4))
                }
                FormatTag(song: file.song)
                Spacer()
                if let onConvertWithAI {
                    Button(action: onConvertWithAI) { Label("Convert with AI", systemImage: "sparkles") }
                        .font(.caption)
                        .help("Have Claude turn this document into a transposable chart")
                }
                if let onGetFromSongSelect, file.song.ccli != nil {
                    Button(action: onGetFromSongSelect) { Label("Get transposable version from SongSelect", systemImage: "arrow.up.circle") }
                        .font(.caption)
                } else {
                    Text("Original document – key can't be changed").font(.caption).foregroundColor(.secondary)
                }
            }
            if !notes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(notes) { n in StickyNoteView(note: n, size: 15) { onTapNote(n) } }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
