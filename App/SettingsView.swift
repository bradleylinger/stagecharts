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
    @Environment(\.dismiss) private var dismiss
    @AppStorage("chartStyle") private var styleRaw = ChartStyle.classic.rawValue
    @AppStorage("chartColumns") private var columnsRaw = ChartColumns.auto.rawValue
    var showsDoneButton = true
    @State private var pickingFolder = false
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
                librarySection
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

    private var librarySection: some View {
        Section {
            LabeledContent("Location", value: library.locationName)
            Button(library.usesCustomFolder ? "Choose a different folder…" : "Use a shared folder (Google Drive)…") {
                pickingFolder = true
            }
            if library.usesCustomFolder {
                Button("Refresh from folder") { library.reloadAll() }
                Button("Use this device's storage instead") { library.useDeviceStorage() }
            }
            if let folderError { Text(folderError).foregroundStyle(.red) }
        } header: {
            Text("Library & sync")
        } footer: {
            Text("Keep songs, set lists and notes in a Google Drive folder so every device stays in sync. On iPad: install the Google Drive app, then pick Google Drive › a folder (e.g. “StageCharts”). On the Mac: pick that folder inside Google Drive (Drive for Desktop). Your current library is copied in the first time.")
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
            ForEach(library.songs) { file in
                let trigger = library.settings(for: file.id).midiTrigger
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.song.title)
                        Text(trigger?.label(showChannel: omni) ?? "Not mapped")
                            .font(.caption.monospaced())
                            .foregroundStyle(trigger == nil ? Color.secondary : Color.chord)
                    }
                    Spacer()
                    if trigger != nil {
                        Button { library.setTrigger(nil, for: file.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Clear")
                    }
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
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Choose a message manually")
                    learnButton(.song(id: file.id))
                }
            }
        } header: {
            Text("Songs")
        } footer: {
            Text("Learn: tap, then fire the song's clip in Ableton. Any CC, note or Program Change can select a song (e.g. CC 101 → first song). Songs without their own message can still be picked by Program Change number = position in the list.")
        }
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
