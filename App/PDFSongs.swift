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
