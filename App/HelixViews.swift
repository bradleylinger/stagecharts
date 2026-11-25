import SwiftUI
import UniformTypeIdentifiers
import ChordProKit

// MARK: - Settings → Helix

@available(iOS 18, macOS 14, *)
struct HelixSettingsSection: View {
    @EnvironmentObject var library: SongLibrary
    @AppStorage("helixSendSnapshots") private var sendSnapshots = true
    @AppStorage("helixChannel") private var channel = 1
    @AppStorage("helixVolumePedal") private var volumePedal = true
    @AppStorage("helixKnobs") private var knobs = 3
    @AppStorage("helixSwitches") private var switches = 4
    @State private var catalog: HelixCatalog?
    @State private var scanning = false
    @State private var error: String?
    @State private var pickingFolder = false
    @State private var designing = false
    private static let bookmarkKey = "helixPresetsBookmark"

    var body: some View {
        Group {
            Section {
                if let c = catalog {
                    LabeledContent("Learned from", value: "\(c.presetCount) presets · \(c.models.count) models")
                    LabeledContent("Last read", value: c.scanned.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Setting limits", value: c.limits.isEmpty ? "Not found" : "From Helix Native (\(c.limits.count) models)")
                } else {
                    Text("Not set up yet.").foregroundStyle(.secondary)
                }
                Button(catalog == nil ? "Choose presets folder…" : "Choose a different folder…") { chooseFolder() }
                if UserDefaults.standard.data(forKey: Self.bookmarkKey) != nil {
                    Button(scanning ? "Reading…" : "Read presets again") { rescan() }.disabled(scanning)
                }
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
            } header: {
                Text("Your Helix presets")
            } footer: {
                Text("StageCharts learns which amps and effects your Helix Native has, and every setting they take, from presets you've exported. In Helix Native select presets (or the whole factory setlist) and choose Export, into one folder; .hlx and .hls files both work. Include at least one preset saved by Helix Native. On a Mac with Helix Native installed, StageCharts also reads each setting's real limits from Helix Native itself.")
            }

            Section {
                Button("Make a preset from a description…", systemImage: "sparkles") { designing = true }
                    .disabled(catalog == nil)
            } footer: {
                Text("For a whole set, use the set's menu: Helix preset for this set…")
            }

            Section {
                Toggle("Start with my volume pedal on Knob 1", isOn: $volumePedal)
                Stepper("Knobs on my controller: \(knobs)", value: $knobs, in: 0...16)
                Stepper("Switches on my controller: \(switches)", value: $switches, in: 0...16)
            } header: {
                Text("Live controls")
            } footer: {
                Text("Helix Native's automation Knobs and Switches that your MIDI controller reaches (in Ableton, MIDI-map them on the Helix Native device). Each preset assigns them: Knob 1 to your volume pedal, the other knobs to settings worth riding, and the switches to effects worth turning on and off. The preset shows which is which.")
            }

            Section {
                Toggle("Recall the song's snapshot when it opens", isOn: $sendSnapshots)
                Stepper("Helix Native MIDI channel: \(channel)", value: $channel, in: 1...16)
            } header: {
                Text("Snapshots")
            } footer: {
                Text("Sends CC 69 (0 = snapshot 1) on the \"StageCharts\" MIDI output and the network session. In Ableton, use the Helix Native AU (Audio Units). Add a MIDI track with MIDI From: StageCharts, Monitor: In, and MIDI To: the Helix Native track → Helix Native.")
            }
        }
        .onAppear { catalog = HelixCatalog.load(from: library.helixFolder) }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { use(url) }
        }
        .sheet(isPresented: $designing) { HelixPresetView(setID: nil) }
    }

    private func chooseFolder() {
        #if os(macOS)
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        p.message = "Choose the folder with your exported Helix Native presets"
        if p.runModal() == .OK, let u = p.url { use(u) }
        #else
        pickingFolder = true
        #endif
    }

    private func use(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        if let b = try? url.bookmarkData() { UserDefaults.standard.set(b, forKey: Self.bookmarkKey) }
        scan(url) { if scoped { url.stopAccessingSecurityScopedResource() } }
    }

    private func rescan() {
        guard let d = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: d, bookmarkDataIsStale: &stale) else {
            error = "That folder can't be found any more. Choose it again."; return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        scan(url) { if scoped { url.stopAccessingSecurityScopedResource() } }
    }

    private func scan(_ url: URL, done: @escaping () -> Void) {
        scanning = true; error = nil
        let dest = library.helixFolder
        Task.detached {
            let result = Result {
                var c = try HelixCatalog.scan(url)
                c.info = HelixCatalog.readInfo(in: dest)   // model descriptions live in the library's Helix folder
                HelixCatalog.shared = c
                return c
            }
            if case .success(let c) = result { try? c.save(in: dest) }
            await MainActor.run {
                switch result {
                case .success(let c): catalog = c
                case .failure(let e): error = e.localizedDescription
                }
                scanning = false
                done()
                library.onLocalChange?()
            }
        }
    }
}

// MARK: - Designing a preset

@available(iOS 18, macOS 14, *)
struct HelixPresetView: View {
    let setID: UUID?
    @EnvironmentObject var library: SongLibrary
    @Environment(\.dismiss) private var dismiss
    @AppStorage("helixLastDescription") private var request = "A big crunchy tone with a dotted-eighth delay and a boost for leads"
    @State private var notes: [UUID: String] = [:]
    @State private var working = false
    @State private var error: String?
    @State private var design: HelixDesign?
    @State private var built: HelixBuilder.Result?
    @State private var saved: URL?
    @AppStorage("helixResearch") private var researchOnline = true
    @AppStorage("helixModel") private var model = Claude.model
    @AppStorage("helixEffort") private var effort = "high"
    @State private var stage = ""
    @State private var research: String?

    private static let efforts: [(String, String)] = [
        ("low", "Low"), ("medium", "Medium"), ("high", "High"), ("xhigh", "Extra high"), ("max", "Max"),
    ]

    private var set: SetList? { library.setList(id: setID) }
    private var catalog: HelixCatalog? { HelixCatalog.load(from: library.helixFolder) }

    var body: some View {
        NavigationStack {
            Form {
                if catalog == nil {
                    Section {
                        Label("Choose your Helix presets folder in Settings → Helix first, so StageCharts knows which amps and effects you have.",
                              systemImage: "exclamationmark.triangle")
                    }
                }
                Section {
                    TextEditor(text: $request).frame(minHeight: 90)
                } header: {
                    Text("Describe the tones")
                } footer: {
                    Text("E.g. \"big crunchy tone with a dotted-eighth delay and a boost\", \"ambient swells for the slow songs\", \"match the electric guitar on Gratitude by Brandon Lake\".")
                }
                Section {
                    Toggle("Research the recordings' guitar tones online", isOn: $researchOnline)
                    Picker("Model", selection: $model) {
                        ForEach(Claude.choices, id: \.id) { c in Text("\(c.name) – \(c.note)").tag(c.id) }
                    }
                    Picker("Effort", selection: $effort) {
                        ForEach(Self.efforts, id: \.0) { Text($0.1).tag($0.0) }
                    }
                } header: {
                    Text("AI")
                } footer: {
                    Text("Research: Claude first searches the web for rig rundowns and tone guides for the songs in this set and any recording you name, then builds the preset from what it finds. It adds a minute or two and a little cost (web searches are billed per search). Higher effort thinks longer: better on complicated sets, slower and costlier. High suits most presets.")
                }
                if let set {
                    Section {
                        ForEach(set.items) { item in
                            if let f = library.song(id: item.songID) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(f.song.title).font(.headline)
                                        Spacer()
                                        Text(songFacts(item, f)).font(.caption).foregroundStyle(.secondary)
                                        if let n = built?.songSnapshots[index(of: item)], let names = built?.snapshotNames,
                                           names.indices.contains(n) {
                                            Text(names[n]).font(.caption.weight(.semibold))
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                        }
                                    }
                                    TextField("Notes for this song (optional), e.g. \"swells in the verse\"",
                                              text: Binding(get: { notes[item.id] ?? "" }, set: { notes[item.id] = $0 }))
                                        .font(.callout)
                                }
                            }
                        }
                    } header: {
                        Text("Songs in \(set.name) – one snapshot each (up to 8)")
                    }
                }
                Section {
                    Button {
                        Task { await run() }
                    } label: {
                        if working { HStack { ProgressView(); Text(stage) } }
                        else { Label(built == nil ? "Design preset" : "Design again", systemImage: "sparkles") }
                    }
                    .disabled(working || catalog == nil || request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let error { Text(error).foregroundStyle(.red).font(.callout) }
                } footer: {
                    Text("Your description, the song titles/keys/tempos and the list of your Helix models are sent to Anthropic with your API key."
                         + (researchOnline ? " The song titles and your description are also used for web searches." : ""))
                }
                if let design, let built { result(design, built) }
            }
            .formStyle(.grouped)
            #if DEBUG
            .task { if ProcessInfo.processInfo.arguments.contains("-mockHelix") { await run() } }
            #endif
            .navigationTitle(set == nil ? "Helix preset" : "Helix preset for this set")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 640)
        #endif
    }

    @ViewBuilder private func result(_ d: HelixDesign, _ b: HelixBuilder.Result) -> some View {
        Section {
            Text(HelixBuilder.clean(d.name, max: 16)).font(.title3.weight(.semibold))
            Text(d.summary).font(.callout)
            ForEach(Array(b.blocks.enumerated()), id: \.offset) { i, name in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 18)
                    Text(name)
                    if let why = d.blocks.first(where: { HelixCatalog.describe($0.model) == name })?.why {
                        Text(why).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        } header: {
            Text("Preset")
        }
        Section("Snapshots") {
            ForEach(Array(b.snapshotNames.enumerated()), id: \.offset) { i, name in
                let songs = (set?.items ?? []).enumerated().filter { b.songSnapshots[$0.offset] == i }
                    .compactMap { library.song(id: $0.element.songID)?.song.title }
                LabeledContent("\(i + 1). \(name)", value: songs.isEmpty ? "–" : songs.joined(separator: ", "))
            }
        }
        if let research, !research.isEmpty {
            Section {
                DisclosureGroup("What Claude found about the recordings") {
                    Text(research).font(.callout).textSelection(.enabled)
                }
            }
        }
        if !b.controls.isEmpty {
            Section {
                ForEach(b.controls, id: \.self) { Text($0) }
            } header: {
                Text("Live controls")
            } footer: {
                Text("Already assigned in the preset: your controller's knobs and switches work as soon as it loads.")
            }
        }
        if !b.warnings.isEmpty {
            Section("Notes") { ForEach(b.warnings, id: \.self) { Text($0).font(.caption) } }
        }
        Section {
            if let saved {
                Label("Saved as \(saved.lastPathComponent)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                #if os(macOS)
                Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                #endif
                ShareLink(item: saved) { Label("Share or save the .hlx…", systemImage: "square.and.arrow.up") }
            } else {
                Button(set == nil ? "Save preset" : "Save preset and use it for this set", systemImage: "square.and.arrow.down") { save(d, b) }
                    .buttonStyle(.borderedProminent)
            }
        } footer: {
            Text("Then in Helix Native: Import (or drag the .hlx onto the preset list) and pick it. "
                 + (set == nil ? "" : "Opening a song in this set recalls its snapshot."))
        }
    }

    private func index(of item: SetItem) -> Int { set?.items.firstIndex { $0.id == item.id } ?? -1 }

    private func songFacts(_ item: SetItem, _ f: SongFile) -> String {
        let r = RenderedSong(file: f, semitones: item.semitones ?? library.settings(for: f.id).semitones, capo: 0,
                             tempo: library.settings(for: f.id).tempo)
        return [r.soundingKey?.description, library.tempo(for: f).map { "\($0) BPM" }].compactMap { $0 }.joined(separator: " · ")
    }

    private var songs: [HelixSong] {
        (set?.items ?? []).compactMap { item in
            guard let f = library.song(id: item.songID) else { return nil }
            let r = RenderedSong(file: f, semitones: item.semitones ?? library.settings(for: f.id).semitones, capo: 0,
                                 tempo: library.settings(for: f.id).tempo)
            return HelixSong(title: f.song.title, artist: f.song.artists.first, key: r.soundingKey?.description,
                             bpm: library.tempo(for: f), time: f.song.time, note: notes[item.id] ?? "")
        }
    }

    /// Settings → Helix → Live controls.
    static var liveControls: (Bool, Int, Int) {
        let u = UserDefaults.standard
        return (u.object(forKey: "helixVolumePedal") as? Bool ?? true, u.object(forKey: "helixKnobs") as? Int ?? 3,
                u.object(forKey: "helixSwitches") as? Int ?? 4)
    }

    private func run() async {
        guard let catalog else { return }
        working = true; error = nil; saved = nil
        defer { working = false }
        do {
            let s = songs
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-mockHelix") {      // screenshots without calling Claude
                let d = HelixDesign.mock(catalog: catalog, songs: s.count)
                let (pedal, knobs, switches) = Self.liveControls
                built = try HelixBuilder.build(d, catalog: catalog, songCount: s.count, volumePedal: pedal,
                                               knobs: knobs, switches: switches)
                design = d; return
            }
            #endif
            let (pedal, knobs, switches) = Self.liveControls
            research = nil
            if researchOnline {
                stage = "Researching the recordings… (a minute or two)"
                research = try await HelixDesigner.research(description: request, songs: s, model: model, effort: effort)
            }
            stage = "Designing… (about a minute)"
            let d = try await HelixDesigner.design(description: request, songs: s, catalog: catalog, volumePedal: pedal,
                                                   knobs: knobs, switches: switches, research: research,
                                                   model: model, effort: effort)
            built = try HelixBuilder.build(d, catalog: catalog, songCount: s.count, volumePedal: pedal,
                                           knobs: knobs, switches: switches)
            design = d
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save(_ d: HelixDesign, _ b: HelixBuilder.Result) {
        do {
            let url = try HelixBuilder.save(b.preset, name: d.name, in: library.helixFolder)
            saved = url
            if let set {
                library.updateSet(set.id) { s in
                    s.helixPreset = url.lastPathComponent
                    s.helixSnapshotNames = b.snapshotNames
                    for i in s.items.indices { s.items[i].helixSnapshot = b.songSnapshots[i] }
                }
            } else {
                library.onLocalChange?()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

#if DEBUG
extension HelixDesign {
    static func mock(catalog: HelixCatalog, songs: Int) -> HelixDesign {
        func pick(_ p: String) -> String { catalog.models.keys.sorted().first { $0.hasPrefix(p) } ?? catalog.models.keys.sorted()[0] }
        let blocks = [pick("HD2_DistKinky"), pick("HD2_AmpPlacater"), pick("HD2_CabMicIr"), pick("HD2_DelaySimple"), pick("HD2_ReverbPlate")]
        return HelixDesign(name: "Sunday Crunch", blocks: blocks.map { .init(model: $0, settings: [], why: "Mock block") },
                           snapshots: [.init(name: "Crunch", tempo: 72, enabled: [false, true, true, true, true], settings: []),
                                       .init(name: "Lead", tempo: 130, enabled: [true, true, true, true, true], settings: [])],
                           songs: (0..<songs).map { .init(song: $0, snapshot: $0 % 2) },
                           summary: "Mock design for screenshots: a crunchy amp with a boost for leads and a dotted-eighth delay.")
    }
}
#endif
