import SwiftUI
import UniformTypeIdentifiers
import ChordProKit

/// Sidebar shows either the Library (all songs) or one set list (songs for a service, in order).
@available(iOS 18, macOS 15, *)
struct ContentView: View {
    @EnvironmentObject var library: SongLibrary
    @EnvironmentObject var midi: MIDIController
    @EnvironmentObject var band: BandSync
    @AppStorage("activeSetID") private var activeSetRaw = ""     // "" = Library
    @State private var showSettings = false
    @State private var selection: String?          // song id (library) or "item:<uuid>" (set)
    @State private var search = ""
    @State private var formatFilter = FormatFilter.all

    enum FormatFilter: String, CaseIterable { case all = "All", pdf = "From PDF", chordPro = "ChordPro" }
    @State private var importing = false
    @State private var newSetName = ""
    @State private var showNewSet = false
    @State private var pendingSongForNewSet: String?
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    /// True while applying a selection that came from MIDI or the band leader (don't echo it back).
    @State private var remoteSelection = false

    private var activeSet: SetList? { UUID(uuidString: activeSetRaw).flatMap { library.setList(id: $0) } }

    var filtered: [SongFile] {
        let byFormat = library.songs.filter {
            switch formatFilter {
            case .all: return true
            case .pdf: return !$0.song.source.isChordPro
            case .chordPro: return $0.song.source.isChordPro
            }
        }
        guard !search.isEmpty else { return byFormat }
        return byFormat.filter {
            $0.song.title.localizedCaseInsensitiveContains(search)
                || $0.song.artists.joined(separator: " ").localizedCaseInsensitiveContains(search)
                || ($0.song.ccli ?? "") == search
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                sourcePicker
                if let set = activeSet { setListView(set) } else { libraryView }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
            .navigationTitle(activeSet?.name ?? "Library")
            .toolbar {
                ToolbarItem {
                    Menu {
                        Button("Import songs…", systemImage: "square.and.arrow.down") { importing = true }
                        Button("New set list…", systemImage: "music.note.list") { pendingSongForNewSet = nil; startNewSet() }
                        if let set = activeSet {
                            Divider()
                            ShareLink(item: SharedSetFile(name: set.name) { try library.exportSetBundle(set) },
                                      preview: SharePreview("\(set.name) – set list")) {
                                Label("Send set list…", systemImage: "ipad.and.arrow.forward")
                            }
                            Button("Print set list…", systemImage: "printer") {
                                ChartPDF.print(ChartPDF.file(for: rendered(set), name: set.name, setTitle: set.name),
                                               jobName: set.name)
                            }
                            ShareLink(item: SharedPDF(name: set.name) { [set] in
                                ChartPDF.file(for: rendered(set), name: set.name, setTitle: set.name)
                            }, preview: SharePreview("\(set.name).pdf")) {
                                Label("Share set PDF…", systemImage: "doc.richtext")
                            }
                            Divider()
                            Button("Delete “\(set.name)”", systemImage: "trash", role: .destructive) {
                                library.deleteSet(set.id); activeSetRaw = ""
                            }
                        }
                    } label: { Label("Add", systemImage: "plus") }
                }
            }
        } detail: {
            Group {
                if let (file, setID, itemID) = resolveSelection() {
                    SongView(file: file, setID: setID, itemID: itemID).id(selection)
                } else {
                    ContentUnavailableView("Pick a song", systemImage: "music.note")
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                        .help("Settings: MIDI mapping, monitor, display")
                }
                if band.role != .off {
                    ToolbarItem(placement: .navigation) {
                        Button { showSettings = true } label: {
                            Label(band.statusText, systemImage: band.role == .lead ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right")
                                .labelStyle(.titleAndIcon)
                                .font(.caption)
                                .foregroundStyle(band.peers.isEmpty ? Color.secondary : Color.green)
                        }
                        .help("Band follow mode")
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onChange(of: midi.command) { _, cmd in handleMIDI(cmd) }
        .onChange(of: activeSetRaw) { _, _ in selectFirst(); leadSendSet() }
        .onChange(of: selection) { _, new in selectionChanged(new) }
        .onChange(of: library.setLists) { _, _ in leadSendSet() }
        .onChange(of: band.peers) { _, _ in }
        .onAppear { wireBand() }
        .background {
            Button("Import…") { importing = true }
                .keyboardShortcut("o", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { library.importFiles(urls) }
        }
        .alert("Import", isPresented: Binding(get: { library.lastError != nil },
                                                      set: { if !$0 { library.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(library.lastError ?? "") }
        .alert("New set list", isPresented: $showNewSet) {
            TextField("Name", text: $newSetName)
            Button("Create") { createSet() }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { if selection == nil { selectFirst() } }
        .onOpenURL { url in openReceived(url) }
    }

    // MARK: Sidebar

    private var sourcePicker: some View {
        Picker("Show", selection: $activeSetRaw) {
            Label("Library", systemImage: "books.vertical").tag("")
            if !library.setLists.isEmpty {
                Section("Set lists") {
                    ForEach(library.setLists) { set in
                        Text("\(set.name)").tag(set.id.uuidString)
                    }
                }
            }
        }
        .pickerStyle(.menu)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var libraryView: some View {
        List(selection: $selection) {
            Section {
                Picker("Format", selection: $formatFilter) {
                    ForEach(FormatFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } footer: {
                let pdfCount = library.songs.filter { !$0.song.source.isChordPro }.count
                Text(pdfCount == 0 ? "All songs are ChordPro." :
                     "\(pdfCount) of \(library.songs.count) songs came from PDFs. Import their SongSelect ChordPro files to upgrade them in place.")
            }
            ForEach(filtered) { file in
                HStack(alignment: .firstTextBaseline) {
                    songRow(title: file.song.title, key: keyText(file, item: nil), subtitle: file.song.artists.first)
                    Spacer(minLength: 4)
                    FormatTag(source: file.song.source)
                }
                    .tag(file.id)
                    .contextMenu { addToSetMenu(file.id) }
            }
            .onDelete { idx in library.delete(idx.map { filtered[$0].id }) }
        }
        .searchable(text: $search, prompt: "Title, author, or CCLI #")
        .overlay {
            if library.songs.isEmpty {
                ContentUnavailableView("No songs yet", systemImage: "music.note.list",
                                       description: Text("Import SongSelect chord sheet PDFs or ChordPro files."))
            }
        }
    }

    private func setListView(_ set: SetList) -> some View {
        List(selection: $selection) {
            Section {
                ForEach(Array(set.items.enumerated()), id: \.element.id) { index, item in
                    if let file = library.song(id: item.songID) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1).").font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                            songRow(title: file.song.title, key: keyText(file, item: item), subtitle: file.song.artists.first)
                            Spacer(minLength: 4)
                            if let cc = midi.mapping.setSlotCC(forPosition: index + 1) {
                                Text("CC \(cc)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .help("MIDI CC \(cc) opens this song")
                            }
                        }
                        .tag("item:" + item.id.uuidString)
                    } else {
                        Text("Missing song: \(item.songID)").foregroundStyle(.red)
                    }
                }
                .onMove { from, to in library.updateSet(set.id) { $0.items.move(fromOffsets: from, toOffset: to) } }
                .onDelete { idx in library.updateSet(set.id) { $0.items.remove(atOffsets: idx) } }
            } header: {
                Text(set.date.formatted(date: .complete, time: .omitted))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if midi.mapping.setSlotsEnabled {
                        Text(slotFooter)
                    }
                    Text("Add songs from the Library (long-press a song → Add to set). Drag to reorder.")
                }
            }
        }
    }

    private var slotFooter: String {
        let m = midi.mapping
        let last = min(127, m.setSlotFirstCC + m.setSlotCount - 1)
        let ch = m.listenChannel == 0 ? "any channel" : "ch \(m.listenChannel)"
        return "MIDI: CC \(m.setSlotFirstCC)–\(last) → songs 1–\(m.setSlotCount) (\(ch))"
    }

    private func songRow(title: String, key: String?, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            HStack(spacing: 8) {
                if let key { Text(key).foregroundStyle(key.contains("Capo") ? Color.red : Color.orange) }
                if let subtitle { Text(subtitle).lineLimit(1) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func addToSetMenu(_ songID: String) -> some View {
        ForEach(library.setLists) { set in
            Button("Add to “\(set.name)”") {
                library.updateSet(set.id) { $0.items.append(SetItem(songID: songID)) }
            }
        }
        Button("New set list with this song…") { pendingSongForNewSet = songID; startNewSet() }
    }

    private func startNewSet() {
        newSetName = "Sunday – " + Date().formatted(.dateTime.month(.abbreviated).day())
        showNewSet = true
    }

    private func createSet() {
        let set = library.createSet(name: newSetName.isEmpty ? "New set" : newSetName,
                                    songIDs: pendingSongForNewSet.map { [$0] } ?? [])
        pendingSongForNewSet = nil
        activeSetRaw = set.id.uuidString
    }

    /// Songs of a set, rendered in that set's keys/capos (for printing).
    private func rendered(_ set: SetList) -> [RenderedSong] {
        set.items.compactMap { item in
            guard let f = library.song(id: item.songID) else { return nil }
            let s = library.settings(for: f.id)
            return RenderedSong(file: f, semitones: item.semitones ?? s.semitones, capo: item.capo ?? s.capo, tempo: library.settings(for: f.id).tempo)
        }
    }

    /// A file opened from AirDrop / Files / Mail: a .stageset loads the set; charts/PDFs import as songs.
    private func openReceived(_ url: URL) {
        if url.pathExtension.lowercased() == "stageset" {
            do {
                let id = try library.importSetBundle(url)
                activeSetRaw = id.uuidString
                selectFirst()
            } catch {
                library.lastError = "Couldn't open set list: \(error.localizedDescription)"
            }
        } else {
            library.importFiles([url])
        }
    }

    // MARK: Selection

    private func resolveSelection() -> (SongFile, UUID?, UUID?)? {
        guard let selection else { return nil }
        if selection.hasPrefix("item:"), let set = activeSet,
           let itemID = UUID(uuidString: String(selection.dropFirst(5))),
           let item = set.items.first(where: { $0.id == itemID }),
           let file = library.song(id: item.songID) {
            return (file, set.id, itemID)
        }
        return library.song(id: selection).map { ($0, nil, nil) }
    }

    /// Ordered selectable ids for the current sidebar (set order, or library order).
    private var orderedSelections: [String] {
        if let set = activeSet { return set.items.map { "item:" + $0.id.uuidString } }
        return library.songs.map(\.id)
    }

    private func selectFirst() { selection = orderedSelections.first }

    private func handleMIDI(_ cmd: MIDIController.Command?) {
        guard let cmd else { return }
        switch cmd.action {
        case .selectProgram(let n):          // position in the set (or library)
            let list = orderedSelections
            if list.indices.contains(n - 1) { selectRemotely(list[n - 1]) }
        case .selectSong(let id):            // the song's own trigger; prefer its entry in the active set
            if let item = activeSet?.items.first(where: { $0.songID == id }) {
                selectRemotely("item:" + item.id.uuidString)
            } else {
                selectRemotely(id)
            }
        case .selectSetPosition(let n):      // CC 101-110 → songs 1-10 of the loaded set
            if let items = activeSet?.items, items.indices.contains(n - 1) {
                selectRemotely("item:" + items[n - 1].id.uuidString)
            }
        case .nextSong: step(1, remote: !cmd.local)
        case .previousSong: step(-1, remote: !cmd.local)
        default: break      // handled by SongView
        }
    }

    /// Selection from MIDI / band follow: mark it so it isn't announced back out.
    private func selectRemotely(_ id: String?) {
        guard id != selection else { return }
        remoteSelection = true
        selection = id
    }

    private func selectionChanged(_ new: String?) {
        let fromRemote = remoteSelection
        remoteSelection = false
        leadSendSelection()
        guard let new, let set = activeSet,
              let i = set.items.firstIndex(where: { "item:" + $0.id.uuidString == new }) else { return }
        if !fromRemote { midi.announceSongPicked(position: i + 1) }
    }

    // MARK: Band follow mode

    private var currentSelectMessage: BandMessage? {
        guard let selection else { return nil }
        if let (file, _, itemID) = resolveSelection() {
            let pos = activeSet?.items.firstIndex { $0.id == itemID }.map { $0 + 1 }
            return .select(position: pos, songID: file.id)
        }
        return nil
    }

    private func leadSendSelection() {
        if let m = currentSelectMessage { band.send(m) }
    }

    private func leadSendSet() {
        if let set = activeSet { band.send(.set(library.makeSetBundle(set))) }
    }

    private func wireBand() {
        band.snapshot = {
            var msgs: [BandMessage] = []
            if let set = activeSet { msgs.append(.set(library.makeSetBundle(set))) }
            if let m = currentSelectMessage { msgs.append(m) }
            return msgs
        }
        band.onSet = { bundle in
            if (try? library.importSetBundle(bundle)) != nil, activeSetRaw != bundle.set.id.uuidString {
                activeSetRaw = bundle.set.id.uuidString
            }
        }
        band.onSelect = { position, songID in
            if let position, let items = activeSet?.items, items.indices.contains(position - 1) {
                selectRemotely("item:" + items[position - 1].id.uuidString)
            } else if library.song(id: songID) != nil {
                selectRemotely(songID)
            }
        }
        band.onScroll = { f in midi.send(.scrollTo(f)) }
    }

    private func step(_ delta: Int, remote: Bool = false) {
        let list = orderedSelections
        guard !list.isEmpty else { return }
        let current = list.firstIndex(of: selection ?? "") ?? -delta
        let target = list[max(0, min(list.count - 1, current + delta))]
        if remote { selectRemotely(target) } else { selection = target }
    }

    private func keyText(_ file: SongFile, item: SetItem?) -> String? {
        guard let k = file.song.key else { return nil }
        let s = library.settings(for: file.id)
        let semis = item?.semitones ?? s.semitones
        let capo = item?.capo ?? s.capo
        var parts = [k.transposed(by: semis).description]
        if capo > 0 { parts.append("Capo \(capo)") }
        if item != nil, let bpm = library.tempo(for: file) { parts.append("\(bpm) BPM") }
        return parts.joined(separator: " · ")
    }
}
