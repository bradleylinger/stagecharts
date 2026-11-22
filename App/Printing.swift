import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
import ChordProKit
import PDFKit
#if os(iOS)
import UIKit
#else
import AppKit
import PDFKit
#endif

/// A song as it should be shown/printed: transposed to the sounding key, then to capo shapes.
struct RenderedSong {
    let song: ChordProSong
    let soundingKey: Key?
    let originalKey: Key?
    let shapeKey: Key?
    let semitones: Int
    let capo: Int
    /// The BPM we play it at, and the chart's own BPM (for reference when they differ).
    let tempo: Int?
    let chartTempo: Int?
    let pdfURL: URL?        // PDF-only songs print their original pages

    init(file: SongFile, semitones: Int, capo: Int, tempo: Int? = nil) {
        self.semitones = semitones
        self.capo = capo
        chartTempo = file.song.tempo.flatMap { Int($0) }
        pdfURL = file.pdfURL
        self.tempo = tempo ?? chartTempo
        originalKey = file.song.key
        soundingKey = originalKey?.transposed(by: semitones)
        shapeKey = soundingKey?.transposed(by: -capo)
        let shift = semitones - capo
        song = shift % 12 == 0 ? file.song
            : ChordProSong(Transposer.transpose(chordPro: file.raw, by: shift, preferFlats: shapeKey?.prefersFlats))
    }
}

/// Title block: title, writers, "(based on…)", Key | Tempo | Time, capo badge. Used on screen and in print.
struct ChartHeaderView: View {
    let r: RenderedSong
    let size: CGFloat
    let style: ChartStyle
    /// On screen: writers are left out (they're in the footer) and the capo sits beside the title.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.15) {
            HStack(alignment: .top, spacing: size * 0.6) {
                Text(r.song.title)
                    .font(ChartFonts.heading(size * 2.1))
                    .foregroundStyle(style.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if compact && r.capo > 0 { capoBadge(stacked: true).padding(.top, size * 0.35) }
            }
            .padding(.bottom, size * 0.2)
            if !compact {
                ForEach(r.song.artists, id: \.self) { Text($0) }
                    .font(ChartFonts.lyric(size * 0.95))
                    .foregroundStyle(style.text)
                ForEach(r.song.subtitles, id: \.self) { Text("(\($0))") }
                    .font(ChartFonts.lyric(size * 0.95))
                    .foregroundStyle(style.text)
            }
            VStack(alignment: .leading, spacing: size * 0.1) {
                Text(keyTempoLine)
                    .font(ChartFonts.heading(size))
                    .foregroundStyle(style.text)
                    .fixedSize(horizontal: false, vertical: true)
                let notes = [r.semitones != 0 ? r.originalKey.map { "orig. key \($0.description)" } : nil,
                             r.tempo != r.chartTempo ? r.chartTempo.map { "chart: \($0) BPM" } : nil].compactMap { $0 }
                if !notes.isEmpty {
                    Text("(\(notes.joined(separator: ", ")))")
                        .font(ChartFonts.lyric(size * 0.8))
                        .foregroundStyle(style.secondary)
                }
            }
            .padding(.top, size * 0.15)
            if !compact && r.capo > 0 { capoBadge(stacked: false).padding(.top, size * 0.3) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func capoBadge(stacked: Bool) -> some View {
        let badge = Text("CAPO \(r.capo)")
            .font(ChartFonts.heading(size * 0.95))
            .foregroundStyle(.white)
            .padding(.horizontal, size * 0.5)
            .padding(.vertical, size * 0.15)
            .background(Color.red, in: RoundedRectangle(cornerRadius: size * 0.25))
            .fixedSize()
        badge
    }

    private var keyTempoLine: String {
        var parts: [String] = []
        if let k = r.soundingKey { parts.append("Key - \(k.description)") }
        if let t = r.tempo { parts.append("Tempo - \(t)") }
        if let t = r.song.time { parts.append("Time - \(t)") }
        return parts.joined(separator: " | ")
    }
}

struct ChartFooterView: View {
    let song: ChordProSong
    let size: CGFloat
    let style: ChartStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let c = song.ccli { Text("CCLI Song # \(c)") }
            if let c = song.copyright { Text("© \(c)") }
        }
        .font(.system(size: max(7, size * 0.5)))
        .foregroundStyle(style.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - PDF

/// Builds US Letter PDFs in the SongSelect two-column layout, breaking pages between sections.
@available(iOS 16, macOS 13, *)
@MainActor
enum ChartPDF {
    static let page = CGSize(width: 612, height: 792)
    static let margin: CGFloat = 40
    static let gutter: CGFloat = 22
    static let textSize: CGFloat = 11

    static func data(for songs: [RenderedSong], setTitle: String? = nil) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: page)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }

        if let setTitle {
            draw(SetCoverPage(title: setTitle, songs: songs, size: textSize), in: ctx)
        }
        for r in songs {
            if let url = r.pdfURL, let doc = PDFDocument(url: url) {
                for i in 0..<doc.pageCount { if let p = doc.page(at: i) { drawOriginal(p, in: ctx) } }
                continue
            }
            for p in pages(for: r) { draw(p, in: ctx) }
        }
        ctx.closePDF()
        return data as Data
    }

    private static func draw<V: View>(_ view: V, in ctx: CGContext) {
        ctx.beginPDFPage(nil)
        let renderer = ImageRenderer(content: view.frame(width: page.width, height: page.height).background(Color.white))
        renderer.render { _, render in render(ctx) }
        ctx.endPDFPage()
    }

    /// Draws an original PDF page scaled to fit US Letter.
    private static func drawOriginal(_ page: PDFPage, in ctx: CGContext) {
        let b = page.bounds(for: .mediaBox)
        let scale = min(Self.page.width / b.width, Self.page.height / b.height)
        ctx.beginPDFPage(nil)
        ctx.saveGState()
        ctx.translateBy(x: (Self.page.width - b.width * scale) / 2, y: (Self.page.height - b.height * scale) / 2)
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()
        ctx.endPDFPage()
    }

    private static func height<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        let renderer = ImageRenderer(content: view.frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        var h: CGFloat = 0
        renderer.render { size, _ in h = size.height }
        return h
    }

    /// Lays sections into two columns per page.
    private static func pages(for r: RenderedSong) -> [AnyView] {
        let style = ChartStyle.classic
        let contentWidth = page.width - margin * 2
        // Two columns like SongSelect, unless the song has lines too long to fit without wrapping.
        let twoColumns = longestLine(r.song) <= 44
        let colWidth = twoColumns ? (contentWidth - gutter) / 2 : contentWidth
        let sectionSpacing = textSize * 1.2

        let header = ChartHeaderView(r: r, size: textSize, style: style)
        let footer = ChartFooterView(song: r.song, size: textSize, style: style)
        let headerH = height(header, width: contentWidth) + textSize * 1.2
        let footerH = height(footer, width: contentWidth) + 6
        let runningH = textSize * 2

        let sectionHeights = r.song.sections.map {
            height(SectionView(section: $0, size: textSize, style: style), width: colWidth)
        }

        var pages: [[[SongSection]]] = []      // page → columns → sections
        var columns: [[SongSection]] = [[], []]
        var col = 0
        var used: CGFloat = 0
        func available(_ pageIndex: Int) -> CGFloat {
            page.height - margin * 2 - footerH - (pageIndex == 0 ? headerH : runningH)
        }
        for (i, section) in r.song.sections.enumerated() {
            let h = sectionHeights[i]
            if used > 0 && used + h > available(pages.count) {
                if col == 0 && twoColumns { col = 1 } else { pages.append(columns); columns = [[], []]; col = 0 }
                used = 0
            }
            columns[col].append(section)
            used += h + sectionSpacing
        }
        pages.append(columns)

        return pages.enumerated().map { index, cols in
            AnyView(
                VStack(alignment: .leading, spacing: 0) {
                    if index == 0 {
                        header.padding(.bottom, textSize * 1.2)
                    } else {
                        Text("\(r.song.title) - \(index + 1)")
                            .font(ChartFonts.heading(textSize * 0.9))
                            .foregroundStyle(.black)
                            .frame(height: runningH, alignment: .topLeading)
                    }
                    HStack(alignment: .top, spacing: gutter) {
                        ForEach(0..<(twoColumns ? 2 : 1), id: \.self) { c in
                            VStack(alignment: .leading, spacing: sectionSpacing) {
                                ForEach(cols[c]) { SectionView(section: $0, size: textSize, style: style) }
                            }
                            .frame(width: colWidth, alignment: .topLeading)
                        }
                    }
                    Spacer(minLength: 0)
                    if index == pages.count - 1 { footer }
                }
                .padding(margin)
                .environment(\.colorScheme, .light)
            )
        }
    }

    /// Character count of the longest lyric line (chords add width where they overhang).
    private static func longestLine(_ song: ChordProSong) -> Int {
        song.sections.flatMap(\.lines).map { line -> Int in
            guard case .lyrics(let segs) = line else { return 0 }
            return segs.reduce(0) { $0 + max($1.lyric.count, ($1.chord?.count ?? 0) + 1) }
        }.max() ?? 0
    }

    /// Writes a PDF to a temporary file with a friendly name (for sharing / printing).
    static func file(for songs: [RenderedSong], name: String, setTitle: String? = nil) -> URL {
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).pdf")
        try? data(for: songs, setTitle: setTitle).write(to: url, options: .atomic)
        return url
    }

    /// Shows the system print dialog for a PDF.
    static func print(_ url: URL, jobName: String) {
        #if os(iOS)
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = jobName
        controller.printInfo = info
        controller.printingItem = url
        controller.present(animated: true)
        #else
        guard let doc = PDFDocument(url: url),
              let op = doc.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleToFit, autoRotate: false) else { return }
        op.jobTitle = jobName
        op.run()
        #endif
    }
}

/// First page of a printed set: the running order with keys and capos.
@available(iOS 16, macOS 13, *)
private struct SetCoverPage: View {
    let title: String
    let songs: [RenderedSong]
    let size: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.9) {
            Text(title).font(ChartFonts.heading(size * 2.4)).padding(.bottom, size)
            ForEach(Array(songs.enumerated()), id: \.offset) { i, r in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(i + 1).").font(ChartFonts.heading(size * 1.4)).frame(width: size * 2.6, alignment: .leading)
                    Text(r.song.title).font(ChartFonts.heading(size * 1.4))
                    Spacer()
                    Text(r.soundingKey?.description ?? "").font(ChartFonts.heading(size * 1.4))
                    if r.capo > 0 {
                        Text("Capo \(r.capo)").font(ChartFonts.heading(size * 1.1)).foregroundStyle(.red)
                    }
                }
            }
            Spacer()
        }
        .foregroundStyle(.black)
        .padding(56)
        .environment(\.colorScheme, .light)
    }
}

/// Lazily-generated PDF for ShareLink (AirDrop, Mail, Files…).
@available(iOS 16, macOS 13, *)
struct SharedPDF: Transferable {
    let name: String
    let make: @MainActor () -> URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { item in
            SentTransferredFile(await MainActor.run { item.make() })
        }
    }
}
