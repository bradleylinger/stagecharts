import SwiftUI
import ChordProKit

/// Band viewer: a simpler StageCharts for older iPads (iPadOS 15–17) and bandmates.
/// Song list / set lists, charts, key + capo, notes, swipe, next-up — and follows the leader.
struct ViewerRootView: View {
    @EnvironmentObject var library: SongLibrary
    @EnvironmentObject var band: BandSync
    @EnvironmentObject var midi: MIDIController
    @AppStorage("activeSetID") private var activeSetRaw = ""
    @State private var selection: String?

    private var activeSet: SetList? { UUID(uuidString: activeSetRaw).flatMap { library.setList(id: $0) } }

    /// Ordered rows: (selection id, song, set item).
    private var rows: [(id: String, file: SongFile, item: SetItem?)] {
        if let set = activeSet {
            return set.items.compactMap { item in
                library.song(id: item.songID).map { ("item:" + item.id.uuidString, $0, item) }
            }
        }
        return library.songs.map { ($0.id, $0, nil) }
    }

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Band")) {
                    Toggle(isOn: followBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Follow leader")
                            Text(band.statusText).font(.caption)
                                .foregroundColor(band.role == .follow && !band.peers.isEmpty ? .green : .secondary)
                        }
                    }
                }
                Section {
                    Picker("Show", selection: $activeSetRaw) {
                        Text("Library").tag("")
                        ForEach(library.setLists) { Text($0.name).tag($0.id.uuidString) }
                    }
                }
                Section(header: Text(activeSet?.date.formatted(date: .complete, time: .omitted) ?? "All songs")) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        NavigationLink(tag: row.id, selection: $selection) {
                            ViewerSongView(file: row.file, setID: activeSet?.id, itemID: row.item?.id)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                if activeSet != nil {
                                    Text("\(index + 1).").foregroundColor(.secondary).font(.headline.monospacedDigit())
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack { Text(row.file.song.title).font(.headline); FormatTag(source: row.file.song.source) }
                                    Text(keyText(row.file, row.item) ?? "").font(.caption).foregroundColor(.orange)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(activeSet?.name ?? "Library")

            VStack(spacing: 16) {
                Image(systemName: "music.note.list").font(.system(size: 48)).foregroundColor(.secondary)
                Text("Pick a song from the list").foregroundColor(.secondary)
                Toggle("Follow leader", isOn: followBinding).frame(maxWidth: 260)
                Text(band.statusText).font(.caption)
                    .foregroundColor(band.role == .follow && !band.peers.isEmpty ? .green : .secondary)
            }
            .padding()
        }
        .onAppear {
            // The band viewer follows by default (once; after that the user's choice sticks).
            if !UserDefaults.standard.bool(forKey: "viewerFollowDefaulted") {
                UserDefaults.standard.set(true, forKey: "viewerFollowDefaulted")
                band.role = .follow
            }
            wireBand()
        }
        .onChange(of: midi.command) { cmd in
            guard let cmd else { return }
            switch cmd.action {
            case .nextSong: step(1)
            case .previousSong: step(-1)
            default: break
            }
        }
        .onOpenURL { url in
            if url.pathExtension.lowercased() == "stageset", let id = try? library.importSetBundle(url) {
                activeSetRaw = id.uuidString
            } else {
                library.importFiles([url])
            }
        }
    }

    private var followBinding: Binding<Bool> {
        Binding(get: { band.role == .follow }, set: { band.role = $0 ? .follow : .off })
    }

    private func step(_ delta: Int) {
        let ids = rows.map(\.id)
        guard !ids.isEmpty else { return }
        let current = ids.firstIndex(of: selection ?? "") ?? -delta
        selection = ids[max(0, min(ids.count - 1, current + delta))]
    }

    private func keyText(_ file: SongFile, _ item: SetItem?) -> String? {
        guard let k = file.song.key else { return nil }
        let s = library.settings(for: file.id)
        let capo = item?.capo ?? s.capo
        var parts = [k.transposed(by: item?.semitones ?? s.semitones).description]
        if capo > 0 { parts.append("Capo \(capo)") }
        if let bpm = library.tempo(for: file) { parts.append("\(bpm) BPM") }
        return parts.joined(separator: " · ")
    }

    private func wireBand() {
        band.onSet = { bundle in
            if (try? library.importSetBundle(bundle)) != nil { activeSetRaw = bundle.set.id.uuidString }
        }
        band.onSelect = { position, songID in
            if let position, let set = activeSet, set.items.indices.contains(position - 1) {
                selection = "item:" + set.items[position - 1].id.uuidString
            } else if library.song(id: songID) != nil {
                selection = songID
            }
        }
        band.onScroll = { f in midi.send(.scrollTo(f)) }
    }
}

/// Chart screen for the band viewer (iPadOS 15-compatible scrolling).
struct ViewerSongView: View {
    @EnvironmentObject var library: SongLibrary
    @EnvironmentObject var midi: MIDIController
    @AppStorage("chartStyle") private var styleRaw = ChartStyle.classic.rawValue
    @AppStorage("chartColumns") private var columnsRaw = ChartColumns.auto.rawValue
    let file: SongFile
    let setID: UUID?
    let itemID: UUID?

    @State private var contentHeight: CGFloat = 1
    @State private var swipeOffset: CGFloat = 0
    @State private var viewingNote: SongNote?

    private var style: ChartStyle { ChartStyle(rawValue: styleRaw) ?? .classic }
    private var columns: ChartColumns { ChartColumns(rawValue: columnsRaw) ?? .auto }
    private var settings: SongSettings { library.settings(for: file.id) }
    private var item: SetItem? { library.setList(id: setID)?.items.first { $0.id == itemID } }
    private var semitones: Int { item?.semitones ?? settings.semitones }
    private var capo: Int { item?.capo ?? settings.capo }
    private var size: CGFloat { 22 * settings.fontScale }
    private var rendered: RenderedSong { RenderedSong(file: file, semitones: semitones, capo: capo, tempo: library.settings(for: file.id).tempo) }

    private struct ContentHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 1
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    var body: some View {
        let r = rendered
        GeometryReader { outer in
            let padding = max(24, outer.size.width * 0.05)
            let twoCols = columns.count(forWidth: outer.size.width - padding * 2, textSize: size) == 2
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: size * 1.4) {
                        ChartHeaderView(r: r, size: size, style: style)
                        ForEach(settings.notes.filter { $0.section == nil }) { n in
                            StickyNoteView(note: n, size: size) { viewingNote = n }
                        }
                        if twoCols {
                            let (left, right) = Self.split(r.song.sections)
                            HStack(alignment: .top, spacing: size * 2) { column(left); column(right) }
                        } else {
                            column(r.song.sections)
                        }
                        ChartFooterView(song: r.song, size: size, style: style)
                    }
                    .padding(.horizontal, padding)
                    .padding(.vertical, size * 1.2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
                    })
                    // 200 invisible markers let us scroll to any fraction of the chart on iPadOS 15.
                    .overlay(alignment: .top) {
                        VStack(spacing: 0) {
                            ForEach(0..<200, id: \.self) { i in
                                Color.clear.frame(height: max(1, contentHeight / 200)).id("m\(i)")
                            }
                        }
                        .allowsHitTesting(false)
                    }
                }
                .onPreferenceChange(ContentHeightKey.self) { contentHeight = max(1, $0) }
                .onChange(of: midi.command) { cmd in
                    guard let cmd else { return }
                    let maxOffset = max(0, contentHeight - outer.size.height)
                    let page = outer.size.height * 0.8
                    func go(_ y: CGFloat) {
                        let marker = Int((min(max(0, y), maxOffset) / contentHeight * 200).rounded(.down))
                        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo("m\(min(199, marker))", anchor: .top) }
                    }
                    switch cmd.action {
                    case .goToSection(let n):
                        let ids = r.song.sections.map(\.id)
                        if ids.indices.contains(n - 1) {
                            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(ids[n - 1], anchor: .top) }
                        }
                    case .scrollTo(let f): go(maxOffset * f)
                    case .pageDown: go(page)       // approximate on iPadOS 15 (no offset tracking)
                    default: break
                    }
                }
            }
        }
        .background(style.background.ignoresSafeArea())
        .offset(x: swipeOffset)
        .simultaneousGesture(swipe)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let next = nextUp {
                NextUpBar(position: next.0, total: next.1, next: next.2, size: size, style: style) {
                    midi.sendLocal(.nextSong)
                }
            }
        }
        .navigationTitle(r.song.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { ToolbarItemGroup(placement: .primaryAction) { keyControls; displayMenu } }
        .alert(item: $viewingNote) { n in Alert(title: Text("Note"), message: Text(n.text), dismissButton: .default(Text("OK"))) }
        .preferredColorScheme(style.colorScheme)
    }

    private func column(_ sections: [SongSection]) -> some View {
        VStack(alignment: .leading, spacing: size * 1.4) {
            ForEach(sections) { section in
                SectionView(section: section, size: size, style: style,
                            notes: settings.notes.filter { $0.section == section.id },
                            onEditNote: { viewingNote = $0 })
                    .id(section.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    static func split(_ sections: [SongSection]) -> ([SongSection], [SongSection]) {
        let weights = sections.map { s in s.lines.count + 2 }
        let total = weights.reduce(0, +)
        var best = sections.count, bestDiff = Int.max, running = 0
        for i in 0...sections.count {
            let diff = abs(running - (total - running))
            if diff < bestDiff { best = i; bestDiff = diff }
            if i < sections.count { running += weights[i] }
        }
        return (Array(sections[..<best]), Array(sections[best...]))
    }

    private var nextUp: (Int, Int, RenderedSong)? {
        guard let set = library.setList(id: setID), let i = set.items.firstIndex(where: { $0.id == itemID }),
              i + 1 < set.items.count, let f = library.song(id: set.items[i + 1].songID) else { return nil }
        let it = set.items[i + 1], s = library.settings(for: f.id)
        return (i + 2, set.items.count, RenderedSong(file: f, semitones: it.semitones ?? s.semitones, capo: it.capo ?? s.capo, tempo: library.settings(for: f.id).tempo))
    }

    // MARK: Key / capo / display

    private func setSemitones(_ v: Int) {
        if let setID, let itemID { library.updateItem(set: setID, item: itemID) { $0.semitones = v } }
        else { library.update(file.id) { $0.semitones = v } }
    }

    private func setCapo(_ v: Int) {
        if let setID, let itemID { library.updateItem(set: setID, item: itemID) { $0.capo = v } }
        else { library.update(file.id) { $0.capo = v } }
    }

    private var keyControls: some View {
        Menu {
            if let original = file.song.key {
                Section("Key") {
                    ForEach(0..<12, id: \.self) { pc in
                        let k = Key(root: pc, isMinor: original.isMinor)
                        Button(k.description + (k == original ? "  (original)" : "")) { setSemitones(original.semitones(to: k)) }
                    }
                }
            }
            Section("Capo") {
                Button("No capo") { setCapo(0) }
                ForEach(1...9, id: \.self) { n in Button("Capo \(n)") { setCapo(n) } }
            }
        } label: {
            Text([rendered.soundingKey.map { "Key: \($0.description)" }, capo > 0 ? "Capo \(capo)" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                .foregroundColor(capo > 0 ? .red : .accentColor)
        }
    }

    private var displayMenu: some View {
        Menu {
            Button("Larger text") { library.update(file.id) { $0.fontScale = min(3, $0.fontScale + 0.1) } }
            Button("Smaller text") { library.update(file.id) { $0.fontScale = max(0.5, $0.fontScale - 0.1) } }
            Picker("Columns", selection: $columnsRaw) {
                ForEach(ChartColumns.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("Style", selection: $styleRaw) {
                ForEach(ChartStyle.allCases) { Text($0.title).tag($0.rawValue) }
            }
        } label: {
            Image(systemName: "textformat.size")
        }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { v in
                guard v.startLocation.x > 30, abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
                swipeOffset = v.translation.width * 0.35
            }
            .onEnded { v in
                let dx = v.translation.width
                let horizontal = v.startLocation.x > 30 && abs(dx) > abs(v.translation.height) * 1.5
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { swipeOffset = 0 }
                guard horizontal, abs(dx) > 70 || abs(v.predictedEndTranslation.width) > 160 else { return }
                midi.sendLocal(dx < 0 ? .nextSong : .previousSong)
            }
    }
}
