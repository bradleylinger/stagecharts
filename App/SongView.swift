import SwiftUI
import ChordProKit

/// Full-screen chord chart with live key changes, section navigation, and 1- or 2-column layout.
@available(iOS 18, macOS 15, *)
struct SongView: View {
    @EnvironmentObject var library: SongLibrary
    @EnvironmentObject var midi: MIDIController
    @EnvironmentObject var band: BandSync
    @EnvironmentObject var importer: AutoImporter
    @AppStorage("chartStyle") private var styleRaw = ChartStyle.classic.rawValue
    @AppStorage("chartColumns") private var columnsRaw = ChartColumns.auto.rawValue
    let file: SongFile
    var setID: UUID? = nil          // when opened from a set list, key/capo come from the set item
    var itemID: UUID? = nil

    @State private var currentSection = -1
    @State private var position = ScrollPosition(edge: .top)
    @State private var metrics = ScrollMetrics()
    @State private var editingNote: EditingNote?
    @State private var swipeOffset: CGFloat = 0
    @State private var chromeHidden = ProcessInfo.processInfo.arguments.contains("-chromeHidden")   // testing
    @State private var showOriginal = false
    @State private var showAIConvert = false
    @State private var showTransition = false     // iOS: tap the chart to hide / show the top bar
    @State private var editingInfo = false

    struct EditingNote: Identifiable {
        let id = UUID()
        var note: SongNote
        var isNew: Bool
    }

    struct ScrollMetrics: Equatable {
        var offset: CGFloat = 0
        var content: CGFloat = 0
        var container: CGFloat = 0
        /// Top inset the scroll view already adds by itself (safe area it still honours).
        var insetTop: CGFloat = 0
        var maxOffset: CGFloat { max(0, content - container) }
    }

    private var style: ChartStyle { ChartStyle(rawValue: styleRaw) ?? .classic }
    private var columns: ChartColumns { ChartColumns(rawValue: columnsRaw) ?? .auto }
    private var settings: SongSettings { library.settings(for: file.id) }
    private var item: SetItem? { library.setList(id: setID)?.items.first { $0.id == itemID } }
    private var semitones: Int { item?.semitones ?? settings.semitones }
    @AppStorage(FollowerCapo.storageKey) private var followerCaposRaw = ""
    private var following: Bool { band.role == .follow }
    /// Following: this device's own capo (the leader's isn't applied). Otherwise the set item's / song's.
    private var capo: Int { following ? FollowerCapo.capo(for: file.id, in: followerCaposRaw) : (item?.capo ?? settings.capo) }
    private var originalKey: Key? { file.song.key }
    /// The key the band hears.
    private var currentKey: Key? { originalKey?.transposed(by: semitones) }
    /// The chord shapes played with the capo on (e.g. key E, capo 2 → D shapes).
    private var shapeKey: Key? { currentKey?.transposed(by: -capo) }

    /// Song re-parsed with chords shifted to the sounding key, then down by the capo.
    private var displayed: ChordProSong {
        let shift = semitones - capo
        guard shift % 12 != 0 else { return file.song }
        return ChordProSong(Transposer.transpose(chordPro: file.raw, by: shift, preferFlats: shapeKey?.prefersFlats))
    }

    private func setSemitones(_ v: Int) {
        if let setID, let itemID { library.updateItem(set: setID, item: itemID) { $0.semitones = v } }
        else { library.update(file.id) { $0.semitones = v } }
    }

    private func setCapo(_ v: Int) {
        if following { followerCaposRaw = FollowerCapo.setting(v, for: file.id, in: followerCaposRaw); return }
        if let setID, let itemID { library.updateItem(set: setID, item: itemID) { $0.capo = v } }
        else { library.update(file.id) { $0.capo = v } }
    }

    /// Phones get a smaller base size, margins and indent so lines don't wrap.
    private var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }
    private var size: CGFloat { (isPhone ? 15 : 22) * settings.fontScale }

    var body: some View {
        Group {
            if let pdf = file.pdfURL { pdfBody(pdf) } else { textBody }
        }
        .sheet(isPresented: $showAIConvert) { AIConvertSheet(source: .song(file)) }
        .sheet(isPresented: $showTransition) {
            if let (a, b) = transitionPair { TransitionSheet(from: a, to: b, capo: capo) }
        }
    }

    /// This song and the next one in the set, both in the sounding key (no capo), for transition ideas.
    private var transitionPair: (RenderedSong, RenderedSong)? {
        guard let set = library.setList(id: setID),
              let i = set.items.firstIndex(where: { $0.id == itemID }), i + 1 < set.items.count else { return nil }
        let item = set.items[i + 1]
        guard let f = library.song(id: item.songID), file.song.source.isTransposable, f.song.source.isTransposable else { return nil }
        let s = library.settings(for: f.id)
        return (RenderedSong(file: file, semitones: semitones, capo: 0, tempo: library.settings(for: file.id).tempo),
                RenderedSong(file: f, semitones: item.semitones ?? s.semitones, capo: 0, tempo: s.tempo))
    }

    /// PDF-only songs: the original document, with a compact title bar.
    private func pdfBody(_ url: URL) -> some View {
        VStack(spacing: 0) {
            PDFSongBar(file: file, key: currentKey, tempo: library.tempo(for: file), capo: capo,
                       notes: settings.notes, onTapNote: { editingNote = EditingNote(note: $0, isNew: false) },
                       onGetFromSongSelect: { importer.open(song: file) },
                       onConvertWithAI: file.pdfURL.map { u in ["pdf", "jpg", "jpeg", "png", "heic", "gif", "webp", "tif", "tiff"]
                           .contains(u.pathExtension.lowercased()) } == true ? { showAIConvert = true } : nil)
            Divider()
            PDFKitView(url: url, command: midi.command)
        }
        .offset(x: swipeOffset)
        .simultaneousGesture(songSwipe)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let next = nextUp {
                NextUpBar(position: next.position, total: next.total, next: next.song, size: size, style: style,
                          onTap: { midi.sendLocal(.nextSong) },
                          onTransition: transitionPair == nil ? nil : { showTransition = true })
            }
        }
        .sheet(item: $editingNote) { e in
            NoteEditor(note: e.note, sectionName: nil, onSave: { saveNote($0) },
                       onDelete: e.isNew ? nil : { deleteNote(e.note) })
        }
        .sheet(isPresented: $showOriginal) {
            if let u = file.originalURL { OriginalDocumentSheet(url: u, title: file.song.title) }
        }
        .sheet(isPresented: $editingInfo) {
            TempoEditor(tempo: library.tempo(for: file) ?? 0, chartTempo: file.song.tempo.flatMap { Int($0) },
                        time: file.song.time ?? "4/4") { bpm, time in
                let chart = file.song.tempo.flatMap { Int($0) }
                library.setTempoAndTime(file.id, ourTempo: (bpm == 0 || bpm == chart) ? nil : bpm, time: time)
            }
        }
        .toolbar { toolbar(sectionCount: 0) }
        .navigationTitle(file.song.title)
    }

    private var textBody: some View {
        let song = displayed
        return GeometryReader { geo in
            let horizontalPadding = isPhone ? 8 : max(16, geo.size.width * 0.03)
            let usable = geo.size.width - horizontalPadding * 2
            let columnCount = columns.count(forWidth: usable, textSize: size)
            ScrollView {
                VStack(alignment: .leading, spacing: size * 1.4) {
                    header(song).id(-1)
                    let topNotes = settings.notes.filter { $0.section == nil }
                    if !topNotes.isEmpty {
                        VStack(alignment: .leading, spacing: size * 0.5) {
                            ForEach(topNotes) { n in
                                StickyNoteView(note: n, size: size) { editingNote = EditingNote(note: n, isNew: false) }
                            }
                        }
                    }
                    if columnCount == 2 {
                        let (left, right) = Self.split(song.sections)
                        HStack(alignment: .top, spacing: size * 2) {
                            column(left)
                            column(right)
                        }
                    } else {
                        column(song.sections)
                    }
                    footer(song)
                }
                .scrollTargetLayout()
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, size * 1.2)
                .padding(.top, (chromeHidden ? size * 0.4 : size * 1.2) + max(0, geo.safeAreaInsets.top - metrics.insetTop))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(style.background)
            #if os(iOS)
            .ignoresSafeArea(.container, edges: .top)        // the top bar overlays the chart instead of pushing it
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() } }
            #endif
            .scrollPosition($position)
            .onScrollGeometryChange(for: ScrollMetrics.self) { g in
                ScrollMetrics(offset: g.contentOffset.y + g.contentInsets.top,
                              content: g.contentSize.height + g.contentInsets.top + g.contentInsets.bottom,
                              container: g.containerSize.height, insetTop: g.contentInsets.top)
            } action: { _, new in
                metrics = new
                if new.maxOffset > 0 { band.sendScroll(Double(min(1, max(0, new.offset / new.maxOffset)))) }
            }
        }
        .background(style.background.ignoresSafeArea())
        .offset(x: swipeOffset)
        .simultaneousGesture(songSwipe)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let next = nextUp {
                NextUpBar(position: next.position, total: next.total, next: next.song, size: size, style: style,
                          onTap: { midi.sendLocal(.nextSong) },
                          onTransition: transitionPair == nil ? nil : { showTransition = true })
            }
        }
        .sheet(isPresented: $editingInfo) {
            TempoEditor(tempo: library.tempo(for: file) ?? 0,
                        chartTempo: file.song.tempo.flatMap { Int($0) },
                        time: file.song.time ?? "4/4") { bpm, time in
                let chart = file.song.tempo.flatMap { Int($0) }
                library.setTempoAndTime(file.id, ourTempo: (bpm == 0 || bpm == chart) ? nil : bpm, time: time)
            }
        }
        .sheet(item: $editingNote) { e in
            NoteEditor(note: e.note,
                       sectionName: e.note.section.flatMap { id in song.sections.first { $0.id == id }?.label },
                       onSave: { saveNote($0) },
                       onDelete: e.isNew ? nil : { deleteNote(e.note) })
        }
        .onChange(of: midi.command) { _, cmd in
            if let cmd { perform(cmd.action, sectionCount: song.sections.count) }
        }
        .toolbar { toolbar(sectionCount: song.sections.count) }
        .navigationTitle(song.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(chromeHidden ? .hidden : .visible, for: .navigationBar)
        .statusBarHidden(chromeHidden)
        .onChange(of: file.id) { _, _ in if !ProcessInfo.processInfo.arguments.contains("-chromeHidden") { chromeHidden = false } }
        #endif
    }

    private func column(_ sections: [SongSection]) -> some View {
        VStack(alignment: .leading, spacing: size * 1.4) {
            ForEach(sections) { section in
                SectionView(section: section, size: size, style: style, indent: isPhone ? size * 0.8 : nil,
                            notes: settings.notes.filter { $0.section == section.id },
                            onAddNote: { editingNote = EditingNote(note: SongNote(section: section.id, text: ""), isNew: true) },
                            onEditNote: { editingNote = EditingNote(note: $0, isNew: false) })
                    .id(section.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Splits sections into two columns of roughly equal height (sections are never broken).
    static func split(_ sections: [SongSection]) -> ([SongSection], [SongSection]) {
        func weight(_ s: SongSection) -> Int {
            s.lines.reduce(2) { total, line in
                if case .lyrics(let segs) = line, segs.contains(where: { $0.chord != nil }) { return total + 2 }
                return total + 1
            }
        }
        let weights = sections.map(weight)
        let total = weights.reduce(0, +)
        var best = sections.count, bestDiff = Int.max, running = 0
        for i in 0...sections.count {
            let diff = abs(running - (total - running))
            if diff < bestDiff { best = i; bestDiff = diff }
            if i < sections.count { running += weights[i] }
        }
        return (Array(sections[..<best]), Array(sections[best...]))
    }

    // MARK: Swipe left/right = next/previous song

    private var songSwipe: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onChanged { v in
                let dx = v.translation.width, dy = v.translation.height
                // Horizontal only, and not from the far-left edge (iPadOS uses that for the sidebar).
                guard v.startLocation.x > 30, abs(dx) > abs(dy) * 1.5 else { return }
                swipeOffset = dx * 0.35
            }
            .onEnded { v in
                let dx = v.translation.width, dy = v.translation.height
                let predicted = v.predictedEndTranslation.width
                let horizontal = v.startLocation.x > 30 && abs(dx) > abs(dy) * 1.5
                let switching = horizontal && (abs(dx) > 70 || abs(predicted) > 160)
                if !switching { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { swipeOffset = 0 } }
                guard switching else { return }
                midi.sendLocal(dx < 0 ? .nextSong : .previousSong)
            }
    }

    private var tempoLabel: String {
        [library.tempo(for: file).map { "\($0) BPM" }, file.song.time].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Notes

    private func saveNote(_ note: SongNote) {
        library.update(file.id) { s in
            if let i = s.notes.firstIndex(where: { $0.id == note.id }) { s.notes[i] = note } else { s.notes.append(note) }
        }
    }

    private func deleteNote(_ note: SongNote) {
        library.update(file.id) { $0.notes.removeAll { $0.id == note.id } }
    }

    // MARK: Next up (set lists only)

    private var nextUp: (position: Int, total: Int, song: RenderedSong)? {
        guard let set = library.setList(id: setID),
              let i = set.items.firstIndex(where: { $0.id == itemID }), i + 1 < set.items.count else { return nil }
        let item = set.items[i + 1]
        guard let f = library.song(id: item.songID) else { return nil }
        let s = library.settings(for: f.id)
        return (i + 2, set.items.count, RenderedSong(file: f, semitones: item.semitones ?? s.semitones,
                                                       capo: following ? FollowerCapo.capo(for: f.id, in: followerCaposRaw) : (item.capo ?? s.capo), tempo: library.settings(for: f.id).tempo))
    }

    // MARK: Actions (shared by MIDI, keyboard and toolbar)

    private func perform(_ action: MIDIAction, sectionCount: Int) {
        switch action {
        case .pageDown: scroll(toY: metrics.offset + metrics.container * 0.8)
        case .pageUp: scroll(toY: metrics.offset - metrics.container * 0.8)
        case .scrollTo(let f): scroll(toY: metrics.maxOffset * f, duration: 0.15)
        case .nextSection: goToSection(min(sectionCount - 1, currentSection + 1))
        case .previousSection: goToSection(max(-1, currentSection - 1))
        case .goToSection(let n): goToSection(min(sectionCount - 1, max(0, n - 1)))
        case .keyUp: shift(1)
        case .keyDown: shift(-1)
        case .selectProgram, .selectSong, .selectSetPosition, .nextSong, .previousSong: break   // ContentView
        }
    }

    private func scroll(toY y: CGFloat, duration: Double = 0.45) {
        withAnimation(.smooth(duration: duration)) {
            position.scrollTo(y: min(max(0, y), metrics.maxOffset))
        }
    }

    private func goToSection(_ index: Int) {
        currentSection = index
        withAnimation(.smooth(duration: 0.45)) {
            position.scrollTo(id: index < 0 ? -1 : index, anchor: .top)
        }
    }

    // MARK: Header / footer (SongSelect layout, shared with printing)

    private var rendered: RenderedSong { RenderedSong(file: file, semitones: semitones, capo: capo, tempo: library.settings(for: file.id).tempo) }

    private func header(_ song: ChordProSong) -> some View {
        ChartHeaderView(r: rendered, size: size, style: style, compact: true)
    }

    private func footer(_ song: ChordProSong) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ChartFooterView(song: song, size: size, style: style)
            HStack(spacing: 10) {
                Text(file.sourceDescription)
                    .font(.system(size: max(9, size * 0.45)))
                    .foregroundStyle(style.secondary)
                if file.originalURL != nil {
                    Button { showOriginal = true } label: {
                        Label("Show original", systemImage: "doc.text.magnifyingglass")
                            .font(.system(size: max(11, size * 0.55), weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.top, size)
    }

    // MARK: Print / share

    private var printMenu: some View {
        Menu {
            Button("Print…", systemImage: "printer") {
                let url = ChartPDF.file(for: [rendered], name: rendered.song.title)
                ChartPDF.print(url, jobName: rendered.song.title)
            }
            ShareLink(item: SharedPDF(name: rendered.song.title) { [rendered] in
                ChartPDF.file(for: [rendered], name: rendered.song.title)
            }, preview: SharePreview("\(rendered.song.title).pdf")) {
                Label("Share PDF…", systemImage: "square.and.arrow.up")
            }
        } label: {
            Label("Print or share", systemImage: "printer")
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(sectionCount: Int) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // Page-turner pedals send arrow keys: kept as hidden shortcuts, no toolbar buttons.
            Button { perform(.previousSection, sectionCount: sectionCount) } label: { EmptyView() }
                .keyboardShortcut(.upArrow, modifiers: []).frame(width: 0).opacity(0)
            Button { perform(.nextSection, sectionCount: sectionCount) } label: { EmptyView() }
                .keyboardShortcut(.downArrow, modifiers: []).frame(width: 0).opacity(0)
            Button { perform(.pageDown, sectionCount: sectionCount) } label: { EmptyView() }
                .keyboardShortcut(.pageDown, modifiers: []).frame(width: 0).opacity(0)
            Button { perform(.pageUp, sectionCount: sectionCount) } label: { EmptyView() }
                .keyboardShortcut(.pageUp, modifiers: []).frame(width: 0).opacity(0)

            if file.song.source.isTransposable {
                keyMenu
                // Half-step keys stay available on a keyboard ([ and ]) without toolbar buttons.
                Button { shift(-1) } label: { EmptyView() }
                    .keyboardShortcut("[", modifiers: []).frame(width: 0).opacity(0)
                Button { shift(1) } label: { EmptyView() }
                    .keyboardShortcut("]", modifiers: []).frame(width: 0).opacity(0)
            }

            Menu {
                // Frets listed directly (no nested "Capo" submenu); a checkmark shows the current one.
                Button { setCapo(0) } label: {
                    if capo == 0 { Label("No capo", systemImage: "checkmark") } else { Text("No capo") }
                }
                ForEach(1...9, id: \.self) { n in
                    let name = "Capo \(n)" + (currentKey?.transposed(by: -n).description).map { "  (\($0) shapes)" }.orEmpty
                    Button { setCapo(n) } label: {
                        if capo == n { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
            } label: {
                Text(capo == 0 ? "Capo" : "Capo \(capo)")
                    .font(.headline)
                    .foregroundStyle(capo == 0 ? Color.accentColor : Color.red)
            }
            .help("Capo: chords show the shapes to play; the key stays the sounding key")

            printMenu

            Button { editingInfo = true } label: {
                Label(tempoLabel, systemImage: "metronome")
                    .labelStyle(.titleAndIcon)
            }
            .help("Tempo (BPM) and time signature")

            Button { editingNote = EditingNote(note: SongNote(section: nil, text: ""), isNew: true) } label: {
                Label("Add sticky note", systemImage: "note.text.badge.plus")
            }
            .help("Add a sticky note (long-press a section heading to note that section)")

            Menu {
                Button("Larger text", systemImage: "textformat.size.larger") {
                    library.update(file.id) { $0.fontScale = min(3, $0.fontScale + 0.1) }
                }
                Button("Smaller text", systemImage: "textformat.size.smaller") {
                    library.update(file.id) { $0.fontScale = max(0.5, $0.fontScale - 0.1) }
                }
                Divider()
                Picker("Columns", selection: $columnsRaw) {
                    ForEach(ChartColumns.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Style", selection: $styleRaw) {
                    ForEach(ChartStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if file.originalURL != nil {
                    Divider()
                    Button("Show original", systemImage: "doc.text.magnifyingglass") { showOriginal = true }
                }
            } label: {
                Label("Display", systemImage: "textformat.size")
            }
        }
    }

    private var keyMenu: some View {
        Menu {
            if let original = originalKey {
                ForEach(0..<12, id: \.self) { pc in
                    let k = Key(root: pc, isMinor: original.isMinor)
                    Button {
                        setSemitones(original.semitones(to: k))
                    } label: {
                        let name = k.description + (k == original ? "  (original)" : "")
                        if k == currentKey { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
            } else {
                ForEach(-6...6, id: \.self) { n in
                    Button(n == 0 ? "Original" : String(format: "%+d semitones", n)) {
                        setSemitones(n)
                    }
                }
            }
        } label: {
            Text(currentKey.map { "Key: \($0.description)" } ?? "Key")
                .font(.headline)
                .foregroundStyle(Color.accentColor)
        }
    }

    private func shift(_ n: Int) {
        var v = semitones + n
        if v > 6 { v -= 12 }
        if v < -5 { v += 12 }
        setSemitones(v)
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

// MARK: - Section rendering

struct SectionView: View {
    let section: SongSection
    let size: CGFloat
    let style: ChartStyle
    var indent: CGFloat? = nil          // lyric indent under headings (default 2.4 × text size)
    var notes: [SongNote] = []
    var onAddNote: (() -> Void)? = nil
    var onEditNote: ((SongNote) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.25) {
            if let label = section.label {
                Text(label.uppercased())
                    .font(ChartFonts.heading(size * 1.1))
                    .foregroundStyle(style.text)
                    .padding(.bottom, size * 0.3)
                    .contextMenu {
                        if let onAddNote { Button("Add sticky note", systemImage: "note.text.badge.plus", action: onAddNote) }
                    }
            }
            ForEach(notes) { note in
                StickyNoteView(note: note, size: size) { onEditNote?(note) }
                    .padding(.leading, section.label == nil ? 0 : (indent ?? size * 2.4))
                    .padding(.bottom, size * 0.3)
            }
            VStack(alignment: .leading, spacing: size * 0.25) {
                ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                    switch line {
                    case .lyrics(let segs) where Self.isBarLine(segs):
                        // "| [Eb] . . [Gm] | [Fsus] |" → one inline row
                        segs.reduce(Text("")) { acc, s in
                            acc + (s.chord.map { ChordLabel.text($0 + " ", size: size, color: style.chord) } ?? Text(""))
                                + Text(s.lyric).font(ChartFonts.lyric(size)).foregroundColor(style.text)
                        }
                    case .lyrics(let segs):
                        ChordLyricLine(segments: segs, size: size, style: style)
                    case .comment(let c):
                        Text(c).italic().font(ChartFonts.lyric(size * 0.85)).foregroundStyle(style.secondary)
                    case .label(let l):
                        Text(l.uppercased()).font(ChartFonts.heading(size)).foregroundStyle(style.text)
                    case .blank:
                        Spacer().frame(height: size * 0.4)
                    }
                }
            }
            .padding(.leading, section.label == nil ? 0 : (indent ?? size * 2.4))   // lyrics indented under the heading
        }
    }

    /// True when the lyric parts are only bar/beat symbols (intro/turnaround chord charts).
    static func isBarLine(_ segs: [Segment]) -> Bool {
        let lyric = segs.map(\.lyric).joined()
        return segs.contains { $0.chord != nil }
            && lyric.contains("|")
            && lyric.allSatisfy { " |./%:x0123456789()".contains($0) }
    }
}

/// One line: chords above lyrics, wrapping by word when the column is narrow.
struct ChordLyricLine: View {
    let segments: [Segment]
    let size: CGFloat
    let style: ChartStyle

    private struct Chunk: Hashable { let chord: String?; let text: String }

    private var hasChords: Bool { segments.contains { $0.chord != nil } }

    /// Break segments into words so long lines can wrap; the chord stays on its first word.
    private var chunks: [Chunk] {
        var out: [Chunk] = []
        let regex = try! NSRegularExpression(pattern: #"\S+\s*|\s+"#)
        for seg in segments {
            let text = seg.lyric
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            if matches.isEmpty {
                out.append(Chunk(chord: seg.chord, text: ""))
                continue
            }
            for (i, m) in matches.enumerated() {
                let word = String(text[Range(m.range, in: text)!])
                out.append(Chunk(chord: i == 0 ? seg.chord : nil, text: word))
            }
        }
        return out
    }

    var body: some View {
        let chunks = self.chunks
        if #available(iOS 16, macOS 13, *) {
            FlowLayout(lineSpacing: size * 0.2) {
                ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in chunkView(chunk) }
            }
        } else {
            LegacyFlow(count: chunks.count, lineSpacing: size * 0.2) { chunkView(chunks[$0]) }
        }
    }

    private func chunkView(_ chunk: Chunk) -> some View {
                VStack(alignment: .leading, spacing: -size * 0.1) {
                    if hasChords {
                        // Fixed-height chord slot (room for raised extensions) keeps lyrics on one baseline.
                        Group {
                            if let chord = chunk.chord {
                                ChordLabel.text(chord, size: size, color: style.chord)
                                    .padding(.trailing, size * 0.45)
                            } else {
                                Text(" ").font(ChartFonts.chord(size))
                            }
                        }
                        .frame(height: size * 1.6, alignment: .bottomLeading)
                    }
                    Text(chunk.text.isEmpty ? " " : chunk.text)
                        .font(ChartFonts.lyric(size * 1.05))
                        .foregroundStyle(style.text)
                }
                .fixedSize()
    }
}

private struct LegacyFlowHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Word-wrapping flow for iPadOS 15 (no Layout protocol): positions items with alignment guides.
struct LegacyFlow<Content: View>: View {
    let count: Int
    let lineSpacing: CGFloat
    let content: (Int) -> Content
    @State private var height: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
            ZStack(alignment: .topLeading) {
                ForEach(0..<count, id: \.self) { i in
                    content(i)
                        .alignmentGuide(.leading) { d in
                            if i == 0 { x = 0; y = 0; rowHeight = 0 }
                            if x + d.width > geo.size.width && x > 0 {
                                x = 0; y += rowHeight + lineSpacing; rowHeight = 0
                            }
                            let left = x
                            x += d.width
                            rowHeight = max(rowHeight, d.height)
                            return -left
                        }
                        .alignmentGuide(.top) { _ in -y }
                }
            }
            .background(GeometryReader { g in Color.clear.preference(key: LegacyFlowHeightKey.self, value: g.size.height) })
        }
        .frame(height: height)
        .onPreferenceChange(LegacyFlowHeightKey.self) { height = $0 }
    }
}

/// Simple left-to-right wrapping layout.
@available(iOS 16, macOS 13, *)
struct FlowLayout: Layout {
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
                x += s.width
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            if !row.indices.isEmpty && row.width + s.width > width {
                rows.append(row)
                row = Row()
            }
            row.indices.append(i)
            row.width += s.width
            row.height = max(row.height, s.height)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
