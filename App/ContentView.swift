import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ChordProKit

/// Sidebar shows either the Library (all songs) or one set list (songs for a service, in order).
@available(iOS 18, macOS 14, *)
struct ContentView: View {
    @EnvironmentObject var library: SongLibrary
    @EnvironmentObject var midi: MIDIController
    @EnvironmentObject var band: BandSync
    @EnvironmentObject var importer: AutoImporter
    @ObservedObject private var guitars = GuitarStore.shared
    @State private var showUpgradeQueue = false
    @State private var helixSet: SetList?
    @State private var helixDemo = ProcessInfo.processInfo.arguments.contains("-helixDesigner")   // testing
    @State private var buildingSetFromText = ProcessInfo.processInfo.arguments.contains("-setFromText")   // testing
    @AppStorage("activeSetID") private var activeSetRaw = ""     // "" = Library
    @State private var showSettings = ProcessInfo.processInfo.arguments.contains("-openSettings")   // testing
    @State private var selection: String?          // song id (library) or "item:<uuid>" (set)
    @State private var search = ""
    @State private var formatFilter = FormatFilter.all

    enum FormatFilter: String, CaseIterable { case all = "All", chordPro = "ChordPro", converted = "Converted", documents = "PDF only" }
    @State private var importing = false
    @State private var pickingAIChart = false
    @State private var aiChartURL: URL?
    @State private var scanningChart = false
    @State private var playbackSyncSet: SetList?
    @State private var pickingPhoto = false
    @State private var photoItem: PhotosPickerItem?
    @State private var newSetName = ""
    @State private var showNewSet = false
    @State private var pendingSongForNewSet: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = ProcessInfo.processInfo.arguments.contains("-showSidebar") ? .all : .automatic
    /// Direction of the last next/previous move: the new song slides in from that side (0 = crossfade).
    @State private var songDirection = 0
    @AppStorage(FollowerCapo.storageKey) private var followerCaposRaw = ""
    /// True while applying a selection that came from MIDI or the band leader (don't echo it back).
    @State private var remoteSelection = false

    private var activeSet: SetList? { UUID(uuidString: activeSetRaw).flatMap { library.setList(id: $0) } }

    var filtered: [SongFile] {
        let byFormat = library.songs.filter {
            switch formatFilter {
            case .all: return true
            case .chordPro: return $0.song.source.isChordPro
            case .converted: return $0.song.source == .convertedPDF || $0.song.source == .onSongSongSelect
            case .documents: return $0.song.source == .pdfDocument
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
        NavigationSplitView(columnVisibility: Binding(
            get: { columnVisibility },
            set: { v in withAnimation(.smooth(duration: 0.3)) { columnVisibility = v } })) {
            VStack(spacing: 0) {
                sourcePicker
                if let set = activeSet { setListView(set) } else { libraryView }
            }
            .fileImporter(isPresented: $pickingAIChart, allowedContentTypes: [.pdf, .image]) { result in
                if case .success(let url) = result { aiChartURL = url }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $scanningChart) {
                ChartScanner { url in
                    scanningChart = false
                    if let url { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { aiChartURL = url } }
                }
                .ignoresSafeArea()
            }
            .photosPicker(isPresented: $pickingPhoto, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                photoItem = nil
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data),
                          let url = ChartCapture.pdf(from: [img], name: "Chart photo") else { return }
                    try? await Task.sleep(for: .milliseconds(600))
                    await MainActor.run { aiChartURL = url }
                }
            }
            #endif
            #if os(macOS)
            .sheet(item: $playbackSyncSet) { PlaybackSyncSheet(set: $0) }
            #endif
            .sheet(item: $aiChartURL) { url in
                AIConvertSheet(source: .file(url)) { id in activeSetRaw = ""; selection = id }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
            .navigationTitle(activeSet?.name ?? "Library")
            .toolbar {
                ToolbarItem {
                    Menu {
                        Button("Import songs…", systemImage: "square.and.arrow.down") { importing = true }
                        Button("Get songs from SongSelect…", systemImage: "globe") { importer.browserURL = SongSelect.home }
                        #if os(iOS)
                        Menu {
                            if ChartScanner.isAvailable {
                                Button("Scan with camera…", systemImage: "doc.viewfinder") { scanningChart = true }
                            }
                            Button("Choose a photo…", systemImage: "photo") { pickingPhoto = true }
                            Button("Choose a file…", systemImage: "folder") { pickingAIChart = true }
                        } label: {
                            Label("Convert a chart with AI", systemImage: "sparkles")
                        }
                        #else
                        Button("Convert a chart with AI…", systemImage: "sparkles") { pickingAIChart = true }
                        #endif
                        Button("Upgrade from SongSelect (\(importer.upgradeCandidates.count))…", systemImage: "arrow.up.circle") {
                            showUpgradeQueue = true
                        }
                        Button("New set list…", systemImage: "music.note.list") { pendingSongForNewSet = nil; startNewSet() }
                        Button("New set list from text…", systemImage: "sparkles") { buildingSetFromText = true }
                        if let set = activeSet {
                            Divider()
                            ShareLink(item: SharedSetFile(name: set.name) { try library.exportSetBundle(set) },
                                      preview: SharePreview("\(set.name) – set list")) {
                                Label("Send set list…", systemImage: "ipad.and.arrow.forward")
                            }
                            Button("Copy for Playback", systemImage: "doc.on.doc") {
                                let text = library.playbackText(set)
                                #if os(iOS)
                                UIPasteboard.general.string = text
                                #else
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                                #endif
                            }
                            #if os(macOS)
                            Button("Sync to Playback…", systemImage: "arrow.triangle.2.circlepath") { playbackSyncSet = set }
                            #endif
                            Button("Helix preset for this set…", systemImage: "guitars") { helixSet = set }
                            Picker("Guitar for this set", systemImage: "guitars.fill", selection: Binding(
                                get: { set.guitar },
                                set: { new in library.updateSet(set.id) { $0.guitar = new }; resendGuitar() })) {
                                Text("My usual guitar").tag(UUID?.none)
                                ForEach(guitars.guitars) { Text($0.name).tag(UUID?.some($0.id)) }
                            }
                            .pickerStyle(.menu)
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
            ZStack {
                if let (file, setID, itemID) = resolveSelection() {
                    Group {
                        if #available(iOS 18, macOS 15, *) {
                            SongView(file: file, setID: setID, itemID: itemID)
                        } else {
                            ViewerSongView(file: file, setID: setID, itemID: itemID)   // macOS 14: simpler song view
                        }
                    }
                    .id(selection)
                    .transition(songTransition)
                } else {
                    ContentUnavailableView("Pick a song", systemImage: "music.note")
                }
            }
            .clipped()
            .animation(.smooth(duration: 0.35), value: selection)
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
        .sheet(isPresented: $showSettings) {
            SettingsView()
                #if os(iOS)
                .presentationSizing(.page)
                #endif
        }
        .sheet(isPresented: $showUpgradeQueue) { UpgradeQueueView() }
        .sheet(item: $helixSet) { set in
            if #available(iOS 18, macOS 14, *) { HelixPresetView(setID: set.id) }
        }
        .sheet(isPresented: $helixDemo) {
            if #available(iOS 18, macOS 14, *) { HelixPresetView(setID: library.setLists.first?.id) }
        }
        .sheet(isPresented: $buildingSetFromText) {
            AISetBuilderView { id in activeSetRaw = id.uuidString }
        }
        .sheet(isPresented: Binding(get: { importer.browserURL != nil && !UserDefaults.standard.bool(forKey: "songSelectInBrowser") },
                                    set: { if !$0 { importer.browserURL = nil; importer.stopQueue() } })) {
            SongSelectBrowser(start: importer.browserURL ?? SongSelect.home)
        }
        .overlay(alignment: .bottom) { ToastView().animation(.easeInOut, value: importer.toast) }
        .onReceive(midi.$command.compactMap { $0 }) { handleMIDI($0) }   // also while a sheet is open
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
                let converted = library.songs.filter { !$0.song.source.isChordPro && $0.song.source.isTransposable }.count
                let docs = library.songs.filter { $0.song.source == .pdfDocument }.count
                Text("\(library.songs.count) songs: \(converted) converted from PDFs, \(docs) shown as the original document (can't transpose). Importing SongSelect ChordPro files upgrades them in place.")
            }
            ForEach(filtered) { file in
                HStack(alignment: .firstTextBaseline) {
                    songRow(title: file.song.title, key: keyText(file, item: nil), subtitle: file.song.artists.first)
                    Spacer(minLength: 4)
                    FormatTag(song: file.song)
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
        let snapshotNames = library.helixSnapshotNames(set)
        return List(selection: $selection) {
            Section {
                ForEach(Array(set.items.enumerated()), id: \.element.id) { index, item in
                    if let file = library.song(id: item.songID) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1).").font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                            songRow(title: file.song.title, key: keyText(file, item: item), subtitle: file.song.artists.first)
                            Spacer(minLength: 4)
                            guitarPicker(set, item)
                            snapshotPicker(set, item, names: snapshotNames)
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

    /// The guitar for this song in this set; shown only when it differs from the set's.
    private func guitarPicker(_ set: SetList, _ item: SetItem) -> some View {
        let setGuitar = guitars.guitar(set.guitar) ?? guitars.guitar(guitars.defaultID)
        return Menu {
            Picker("Guitar", selection: Binding(
                get: { item.guitar },
                set: { new in
                    library.updateItem(set: set.id, item: item.id) { $0.guitar = new }
                    if selection == "item:" + item.id.uuidString { resendGuitar() }
                })) {
                Text("Set's guitar" + (setGuitar.map { " (\($0.name))" } ?? "")).tag(UUID?.none)
                ForEach(guitars.guitars) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            .pickerStyle(.inline)
        } label: {
            if let g = guitars.guitar(item.guitar) {
                Label(Self.shortName(g.name), systemImage: "guitars")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.18), in: Capsule())
            } else {
                Image(systemName: "guitars").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Guitar for this song in this set (sets the Helix guitar block)")
    }

    /// "Fender Player Stratocaster" → "Stratocaster".
    static func shortName(_ name: String) -> String { MyGuitar.shortName(name) }

    /// Sends the open song's guitar again after a change.
    private func resendGuitar() {
        guard let sel = selection, sel.hasPrefix("item:"), let set = activeSet,
              let item = set.items.first(where: { "item:" + $0.id.uuidString == sel }),
              let g = guitars.guitar(for: item, in: set) else { return }
        midi.sendHelixGuitar(g)
    }

    /// The Helix Native snapshot this song recalls in this set only (not stored with the song).
    private func snapshotPicker(_ set: SetList, _ item: SetItem, names: [String]) -> some View {
        let label: (Int) -> String = { i in
            names.indices.contains(i) ? "\(i + 1) · \(names[i])" : "Snapshot \(i + 1)"
        }
        return Menu {
            Picker("Helix snapshot", selection: Binding(
                get: { item.helixSnapshot },
                set: { new in
                    library.updateItem(set: set.id, item: item.id) { $0.helixSnapshot = new }
                    // Already open: recall it now, as opening the song would.
                    if let new, selection == "item:" + item.id.uuidString { midi.sendHelixSnapshot(new) }
                })) {
                Text("None").tag(Int?.none)
                ForEach(0..<8, id: \.self) { i in Text(label(i)).tag(Int?.some(i)) }
            }
            .pickerStyle(.inline)
        } label: {
            if let n = item.helixSnapshot {
                Label(label(n), systemImage: "camera.filters")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            } else {
                Image(systemName: "camera.filters").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Helix Native snapshot recalled when this song opens in this set")
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
        if let snap = set.items[i].helixSnapshot { midi.sendHelixSnapshot(snap) }
        if let g = guitars.guitar(for: set.items[i], in: set) { midi.sendHelixGuitar(g) }
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
        guard let m = currentSelectMessage else { return }
        if activeSet == nil, let (file, _, _) = resolveSelection() { band.send(.song(library.sharedSong(file))) }
        band.send(m)
    }

    private func leadSendSet() {
        if let set = activeSet { band.send(.set(library.makeSetBundle(set))) }
    }

    private func wireBand() {
        band.snapshot = {
            var msgs: [BandMessage] = []
            if let set = activeSet { msgs.append(.set(library.makeSetBundle(set))) }
            if activeSet == nil, let (file, _, _) = resolveSelection() { msgs.append(.song(library.sharedSong(file))) }
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
        band.onSong = { s in
            try? library.importShared(s)
            library.reload()
            if activeSetRaw != "" { activeSetRaw = "" }       // leader is in the library, not a set
        }
    }

    private func step(_ delta: Int, remote: Bool = false) {
        let list = orderedSelections
        guard !list.isEmpty else { return }
        let current = list.firstIndex(of: selection ?? "") ?? -delta
        let target = list[max(0, min(list.count - 1, current + delta))]
        guard target != selection else { return }
        // Set the direction first (so the outgoing song gets the matching exit), then switch.
        songDirection = delta > 0 ? 1 : -1
        DispatchQueue.main.async {
            if remote { selectRemotely(target) } else { selection = target }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { songDirection = 0 }
        }
    }

    private var songTransition: AnyTransition {
        switch songDirection {
        case 1:  return .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity))
        case -1: return .asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                    removal: .move(edge: .trailing).combined(with: .opacity))
        default: return .opacity
        }
    }

    private func keyText(_ file: SongFile, item: SetItem?) -> String? {
        guard let k = file.song.key else { return nil }
        let s = library.settings(for: file.id)
        let semis = item?.semitones ?? s.semitones
        let capo = band.role == .follow ? FollowerCapo.capo(for: file.id, in: followerCaposRaw) : (item?.capo ?? s.capo)
        var parts = [k.transposed(by: semis).description]
        if capo > 0 { parts.append("Capo \(capo)") }
        if item != nil, let bpm = library.tempo(for: file) { parts.append("\(bpm) BPM") }
        return parts.joined(separator: " · ")
    }
}
