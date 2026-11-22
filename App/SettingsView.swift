import SwiftUI
import UniformTypeIdentifiers
import StageMIDI
import ChordProKit

/// App settings: MIDI connection, action mapping with MIDI learn, song numbers, monitor, display.
@available(iOS 18, macOS 15, *)
struct SettingsView: View {
    @EnvironmentObject var midi: MIDIController
    @EnvironmentObject var library: SongLibrary
    @EnvironmentObject var band: BandSync
    @EnvironmentObject var googleAuth: GoogleAuth
    @EnvironmentObject var drive: GoogleDriveSync
    @EnvironmentObject var importer: AutoImporter
    @AppStorage("autoImportDownloads") private var autoImport = false
    @AppStorage("songSelectInBrowser") private var songSelectInBrowser = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage("chartStyle") private var styleRaw = ChartStyle.classic.rawValue
    @AppStorage("chartColumns") private var columnsRaw = ChartColumns.auto.rawValue
    var showsDoneButton = true
    @State private var pickingFolder = false
    @State private var pickingSong = false
    @State private var songSearch = ""
    @State private var pendingSongRow: String?
    @State private var folderError: String?

    var body: some View {
        NavigationStack {
            Form {
                if let notice = midi.learnNotice {
                    Section {
                        Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                bandSection
                connectionSection
                listenSection
                actionsSection
                setSlotsSection
                sendSection
                songsSection
                monitorSection
                GoogleDriveSection()
                songSelectSection
                // The folder option is for iCloud Drive / Dropbox users; hidden while Google sync is on.
                if !googleAuth.isSignedIn { librarySection }
                Section("Display") {
                    Picker("Chart style", selection: $styleRaw) {
                        ForEach(ChartStyle.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker("Columns", selection: $columnsRaw) {
                        ForEach(ChartColumns.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { midi.learning = nil; dismiss() }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 680)
        #endif
        .onDisappear { midi.learning = nil }
    }

    // MARK: Sections

    private var songSelectSection: some View {
        Section {
            Button("Open SongSelect…") { afterClosingSettings { importer.browserURL = SongSelect.home } }
            Button("Upgrade queue: \(importer.upgradeCandidates.count) songs need a transposable chart") {
                afterClosingSettings { importer.startQueue() }
            }
                .disabled(importer.upgradeCandidates.isEmpty)
            #if os(macOS)
            Toggle("Import SongSelect downloads automatically", isOn: Binding(get: { autoImport }, set: { autoImport = $0; importer.setWatching($0) }))
            if autoImport {
                LabeledContent("Watching", value: importer.watchFolder.path)
                Button("Choose downloads folder…") {
                    let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                    p.directoryURL = importer.watchFolder
                    if p.runModal() == .OK, let u = p.url { importer.setWatchFolder(u) }
                }
                Toggle("Open SongSelect pages in my web browser (e.g. Chrome)", isOn: $songSelectInBrowser)
            }
            #endif
        } header: {
            Text("SongSelect")
        } footer: {
            Text("Download a chord sheet (PDF or ChordPro) and StageCharts imports it: songs you already have are upgraded in place (set lists, keys, capos, notes and MIDI kept), new ones are added. On the Mac it can also watch your downloads folder for files saved from your web browser.")
        }
    }

    /// On iPad, Settings is a sheet: the SongSelect browser (presented by the main screen) can only
    /// appear once Settings is closed. On the Mac, Settings is its own window, so open straight away.
    private func afterClosingSettings(_ action: @escaping () -> Void) {
        #if os(iOS)
        midi.learning = nil
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: action)
        #else
        action()
        #endif
    }

    private var librarySection: some View {
        Section {
            LabeledContent("Location", value: library.locationName)
            Button(library.usesCustomFolder ? "Choose a different folder…" : "Use a shared folder (iCloud Drive, Dropbox…)…") {
                pickingFolder = true
            }
            if library.usesCustomFolder {
                Button("Refresh from folder") { library.reloadAll() }
                Button("Use this device's storage instead") { library.useDeviceStorage() }
            }
            if let folderError { Text(folderError).foregroundStyle(.red) }
        } header: {
            Text("Library folder (advanced)")
        } footer: {
            Text("Keep the library in a folder synced by another service, such as iCloud Drive or Dropbox. For Google Drive, use “Sign in with Google” above instead.")
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                do { try library.useFolder(url); folderError = nil }
                catch { folderError = "Couldn't use that folder: \(error.localizedDescription)" }
            case .failure(let error):
                folderError = error.localizedDescription
            }
        }
    }

    private var bandSection: some View {
        Section {
            Picker("This device", selection: $band.role) {
                ForEach(BandSync.Role.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            LabeledContent("Status", value: band.statusText)
            if band.role == .lead && !band.peers.isEmpty {
                ForEach(band.peers, id: \.self) { Label($0, systemImage: "ipad") }
            }
        } header: {
            Text("Band follow mode")
        } footer: {
            Text("Lead on your iPad and Follow on the band's iPads (same Wi-Fi, or nearby). Followers receive the set list and charts, then follow your song changes and scrolling. Each person keeps their own text size, columns and theme.")
        }
    }

    private var connectionSection: some View {
        Section {
            LabeledContent("Status", value: midi.status)
            LabeledContent("Network session", value: midi.networkSessionName)
            DisclosureGroup("Inputs (\(midi.sourceNames.count))") {
                ForEach(midi.sourceNames, id: \.self) { Text($0) }
                Button("Rescan") { midi.connectSources() }
            }
        } header: {
            Text("MIDI connection")
        } footer: {
            Text("On the Mac: Audio MIDI Setup → Window → Show MIDI Network Setup → select “\(midi.networkSessionName)” under Directory → Connect. In Ableton, send to “Network Session 1”.")
        }
    }

    private var omni: Bool { midi.mapping.listenChannel == 0 }

    private var listenSection: some View {
        Section {
            Picker("MIDI channel", selection: $midi.mapping.listenChannel) {
                Text("Omni (all)").tag(0)
                ForEach(1...16, id: \.self) { Text("Channel \($0)").tag($0) }
            }
        } header: {
            Text("Listen")
        } footer: {
            Text(omni ? "Omni: each trigger uses the channel it was learned on (shown as “Ch n”)."
                      : "All songs and actions listen on channel \(midi.mapping.listenChannel). Change this to match the channel Ableton sends on.")
        }
    }

    private var actionsSection: some View {
        Section {
            ForEach(StageAction.allCases) { action in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.title)
                        Text(midi.mapping.trigger(for: action)?.label(showChannel: omni) ?? "Not mapped")
                            .font(.caption.monospaced())
                            .foregroundStyle(midi.mapping.trigger(for: action) == nil ? Color.secondary : Color.chord)
                    }
                    Spacer()
                    if midi.mapping.trigger(for: action) != nil {
                        Button { midi.mapping.assign(nil, to: action) } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Clear")
                    }
                    learnButton(.action(action))
                }
            }
            Menu("Load preset…") {
                Button("OnSong-style (note C#-2/C-2 page, Breath CC 2 scroll)") {
                    midi.mapping.bindings = MIDIMapping.onSongPreset
                }
                Button("One CC per action (CC 20–28)") {
                    midi.mapping.bindings = MIDIMapping.ccPreset
                }
            }
        } header: {
            Text("Actions")
        } footer: {
            Text("Tap Learn, then press the pedal/button or play the clip in Ableton. Notes, CCs and Program Changes can be learned. Scroll position must be a CC (its value 0–127 sets the position).")
        }
    }

    private var setSlotsSection: some View {
        Section {
            Toggle("CCs select songs by set position", isOn: $midi.mapping.setSlotsEnabled)
            if midi.mapping.setSlotsEnabled {
                Stepper(value: $midi.mapping.setSlotFirstCC, in: 0...(128 - midi.mapping.setSlotCount)) {
                    LabeledContent("First CC (song 1)", value: "CC \(midi.mapping.setSlotFirstCC)")
                }
                Stepper(value: $midi.mapping.setSlotCount, in: 1...30) {
                    LabeledContent("Number of songs", value: "\(midi.mapping.setSlotCount)")
                }
            }
        } header: {
            Text("Set list positions")
        } footer: {
            let m = midi.mapping
            Text("When a set list is loaded, CC \(m.setSlotFirstCC)–\(min(127, m.setSlotFirstCC + m.setSlotCount - 1)) open songs 1–\(m.setSlotCount) of that set, so Ableton never needs remapping week to week. These take priority over per-song messages below.")
        }
    }

    private var sendSection: some View {
        Section {
            Toggle("Send song changes to Ableton", isOn: $midi.mapping.sendSongChanges)
            if midi.mapping.sendSongChanges {
                Picker("Message", selection: $midi.mapping.sendKind) {
                    Text("Set position CC (CC \(midi.mapping.setSlotFirstCC)+)").tag(MIDIMapping.SendKind.setSlotCC)
                    Text("Program Change (position)").tag(MIDIMapping.SendKind.programChange)
                }
            }
        } header: {
            Text("Two-way MIDI")
        } footer: {
            Text("When you tap a song in the set on this device, StageCharts sends that message (on channel \(max(1, midi.mapping.listenChannel))) over the network session and its “StageCharts” MIDI output. In Ableton: enable Remote for that input, then MIDI-map the CC to the song’s scene. Changes that came from Ableton aren’t sent back.")
        }
    }

    private var songsSection: some View {
        Section {
            Toggle("Program Change selects song by list position", isOn: $midi.mapping.programChangeSelectsSong)
            let mapped = library.songs.filter {
                library.settings(for: $0.id).midiTrigger != nil || midi.learning == .song(id: $0.id) || pendingSongRow == $0.id
            }
            if mapped.isEmpty {
                Text("No songs have their own MIDI message. With set lists, CC \(midi.mapping.setSlotFirstCC)+ usually covers it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(mapped) { file in songMappingRow(file) }
            Button("Assign a song…", systemImage: "plus.circle") { pickingSong = true }
        } header: {
            Text("Songs with their own MIDI message")
        } footer: {
            Text("For songs Ableton or Playback always select with the same message (e.g. a Playback song-start cue). Learn: tap, then fire the cue. Any CC, note or Program Change works.")
        }
        .sheet(isPresented: $pickingSong) { songPicker }
    }

    private func songMappingRow(_ file: SongFile) -> some View {
        let trigger = library.settings(for: file.id).midiTrigger
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.song.title)
                Text(trigger?.label(showChannel: omni) ?? (midi.learning == .song(id: file.id) ? "Waiting for MIDI…" : "Not mapped"))
                    .font(.caption.monospaced())
                    .foregroundStyle(trigger == nil ? Color.secondary : Color.chord)
            }
            Spacer()
            Button { library.setTrigger(nil, for: file.id) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove this song's MIDI message")
            Menu {
                Menu("Control Change") {
                    ForEach(0...127, id: \.self) { n in
                        Button(MIDITrigger(.controlChange, n).description) { setSong(file.id, .controlChange, n) }
                    }
                }
                Menu("Note") {
                    ForEach(0...127, id: \.self) { n in
                        Button("Note \(MIDITrigger.noteName(n))") { setSong(file.id, .note, n) }
                    }
                }
                Menu("Program Change") {
                    ForEach(1...128, id: \.self) { n in
                        Button("Program \(n)") { setSong(file.id, .programChange, n) }
                    }
                }
            } label: { Image(systemName: "slider.horizontal.3") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            learnButton(.song(id: file.id))
        }
    }

    /// Searchable list of all songs; choosing one starts Learn for it.
    private var songPicker: some View {
        NavigationStack {
            List(library.songs.filter { songSearch.isEmpty || $0.song.title.localizedCaseInsensitiveContains(songSearch) }) { file in
                Button {
                    pickingSong = false
                    songSearch = ""
                    midi.startLearning(.song(id: file.id))
                    pendingSongRow = file.id
                } label: {
                    HStack {
                        Text(file.song.title).foregroundStyle(.primary)
                        Spacer()
                        if let t = library.settings(for: file.id).midiTrigger {
                            Text(t.label(showChannel: omni)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $songSearch, prompt: "Search songs")
            .navigationTitle("Assign MIDI to a song")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { pickingSong = false } } }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func setSong(_ id: String, _ kind: MIDITrigger.Kind, _ number: Int) {
        let trigger = MIDITrigger(kind, number)   // no channel: follows the listen channel
        midi.mapping.release(trigger)
        library.setTrigger(trigger, for: id)
    }

    private var monitorSection: some View {
        Section {
            if midi.log.isEmpty {
                Text("No MIDI received yet.").foregroundStyle(.secondary)
            }
            ForEach(midi.log) { entry in
                HStack {
                    Text(entry.message).monospaced()
                    Spacer()
                    Text(entry.result ?? "—")
                        .foregroundStyle(entry.result == nil ? Color.secondary : Color.chord)
                }
                .font(.callout)
            }
        } header: {
            HStack {
                Text("Monitor")
                Spacer()
                Button("Clear") { midi.clearLog() }.font(.caption)
            }
        }
    }

    // MARK: Helpers

    private func learnButton(_ target: LearnTarget) -> some View {
        let active = midi.learning == target
        return Button { midi.startLearning(target) } label: {
            Text(active ? "Listening…" : "Learn")
                .frame(minWidth: 78)
        }
        .buttonStyle(.borderedProminent)
        .tint(active ? .orange : .gray)
    }

}
