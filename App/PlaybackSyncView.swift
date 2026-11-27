#if os(macOS)
import SwiftUI
import ChordProKit

extension SongLibrary {
    /// The set's songs as Playback should play them: sounding key (no capo), tempo, time signature.
    func playbackSongs(_ set: SetList) -> [PlaybackSync.Song] {
        set.items.compactMap { item in
            guard let f = song(id: item.songID) else { return nil }
            let s = settings(for: f.id)
            let r = RenderedSong(file: f, semitones: item.semitones ?? s.semitones, capo: 0, tempo: s.tempo)
            return PlaybackSync.Song(title: f.song.title, keyRoot: r.soundingKey?.root, keyMinor: r.soundingKey?.isMinor ?? false,
                                     keyName: r.soundingKey?.description, bpm: r.tempo, time: f.song.time,
                                     pad: item.playbackPad, itemID: item.id)
        }
    }
}

/// Set list → the setlist loaded in Playback on this Mac.
struct PlaybackSyncSheet: View {
    let set: SetList
    @State private var pads: [PlaybackSync.Pad] = []
    @State private var defaultPad: Int?
    @EnvironmentObject var library: SongLibrary
    @Environment(\.dismiss) private var dismiss
    @AppStorage("playbackSetTimeSignatures") private var setTimeSignatures = true

    enum Stage { case loading, ready(PlaybackSync.Plan), working(String), done(PlaybackSync.Result), failed(String) }
    @State private var stage: Stage = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sync “\(set.name)” to Playback").font(.title2.bold())
            content
            Spacer(minLength: 0)
            HStack {
                if PlaybackSync.latestBackup != nil && !isWorking {
                    Button("Undo last sync…") { undo() }
                        .help("Quit Playback and put back its library from before the last sync")
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                if case .ready(let plan) = stage {
                    Button(PlaybackSync.isRunning ? "Quit Playback & Sync" : "Sync") { apply(plan) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!plan.canApply)
                }
            }
        }
        .padding(22)
        .frame(minWidth: 720, minHeight: 560)
        .onAppear(perform: load)
    }

    @ViewBuilder private var content: some View {
        switch stage {
        case .loading:
            ProgressView("Reading Playback's current setlist…")
        case .working(let s):
            ProgressView(s)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Button("Try again", action: load)
        case .done(let r):
            VStack(alignment: .leading, spacing: 10) {
                Label("Synced \(r.changedRows) item\(r.changedRows == 1 ? "" : "s"). Playback is reopening.", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green).font(.headline)
                Text("In Playback:").font(.headline)
                if !r.needsUpdate.isEmpty {
                    Text("1. Select each of these songs and click **Update** so Playback renders the new key: \(r.needsUpdate.joined(separator: ", ")).")
                }
                Text("\(r.needsUpdate.isEmpty ? "1" : "2"). Open the setlist menu (red dot) and press **Save** to upload the changes to MultiTracks and your other devices.")
                Text("A backup of Playback's library was saved first – use Undo last sync if anything looks wrong.")
                    .font(.caption).foregroundColor(.secondary)
            }
        case .ready(let plan):
            VStack(alignment: .leading, spacing: 8) {
                Text("Playback setlist: **\(plan.setlist.title)** · \(plan.setlist.items.count) items")
                ForEach(plan.problems, id: \.self) { Label($0, systemImage: "xmark.octagon.fill").foregroundColor(.red) }
                ForEach(plan.warnings, id: \.self) { Label($0, systemImage: "info.circle").foregroundColor(.secondary) }
                Toggle("Set time signatures on click items", isOn: $setTimeSignatures)
                    .onChange(of: setTimeSignatures) { _, _ in load() }
                Table(plan.changes) {
                    TableColumn("#") { Text("\($0.newOrder)") }.width(28)
                    TableColumn("StageCharts") { Text($0.song?.title ?? "–").foregroundColor($0.song == nil ? .secondary : .primary) }
                    TableColumn("Playback item") { c in
                        Text(c.item.displayName + (c.item.isClick ? " (click)" : ""))
                    }
                    TableColumn("Pad") { c in padPicker(c) }.width(min: 150, ideal: 190)
                    TableColumn("Changes") { c in Text(describe(c)).foregroundColor(c.touchesRow ? .primary : .secondary) }
                }
                Text("Playback will be quit (like ⌘Q) and reopened. Unsupported by MultiTracks: StageCharts edits Playback's library directly, after a backup. It can't add items – make the Playback setlist with a click item per song first.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    /// The pad this song plays in Playback for this set; saved on the set item, written by Sync.
    @ViewBuilder private func padPicker(_ c: PlaybackSync.Change) -> some View {
        if let itemID = c.song?.itemID, !pads.isEmpty {
            let current = currentSet.items.first(where: { $0.id == itemID })?.playbackPad
            let defaultName = pads.first(where: { $0.contentID == defaultPad })?.title
            Picker("Pad", selection: Binding<Int?>(
                get: { current },
                set: { new in
                    library.updateItem(set: set.id, item: itemID) { $0.playbackPad = new }
                    load()
                })) {
                Text("Leave as is").tag(Int?.none)
                Text("Playback's default" + (defaultName.map { " (\($0))" } ?? "")).tag(Int?.some(0))
                Divider()
                ForEach(pads.filter(\.downloaded)) { p in Text(p.title).tag(Int?.some(p.contentID)) }
            }
            .labelsHidden()
        } else {
            Text("–").foregroundColor(.secondary)
        }
    }

    /// The set as it is now (the sheet was opened with a copy; pad picks change it).
    private var currentSet: SetList { library.setLists.first(where: { $0.id == set.id }) ?? set }

    private var isWorking: Bool { if case .working = stage { return true }; return false }

    private func describe(_ c: PlaybackSync.Change) -> String {
        var parts: [String] = []
        if let n = c.name { parts.append("name → \(n)") }
        if let k = c.keyTitle { parts.append("key → \(k)" + (c.needsUpdate ? " (click Update)" : "")) }
        if let b = c.bpm { parts.append("\(b) BPM") }
        if let t = c.time { parts.append(t.title) }
        if let p = c.pad { parts.append(p.useDefault ? "pad → default" : "pad → \(p.pad?.title ?? "?")") }
        parts += c.notes
        return parts.isEmpty ? "no change" : parts.joined(separator: " · ")
    }

    private func load() {
        stage = .loading
        Task.detached {
            do {
                let lib = try PlaybackSync.read()
                let songs = await MainActor.run { library.playbackSongs(currentSet) }
                let ts = await MainActor.run { setTimeSignatures }
                let plan = PlaybackSync.plan(songs, library: lib, setTimeSignatures: ts)
                await MainActor.run { pads = lib.pads; defaultPad = lib.defaultPad; stage = .ready(plan) }
            } catch {
                await MainActor.run { stage = .failed(error.localizedDescription) }
            }
        }
    }

    private func apply(_ old: PlaybackSync.Plan) {
        Task {
            if PlaybackSync.isRunning {
                stage = .working("Quitting Playback…")
                guard await PlaybackSync.quitPlayback() else {
                    stage = .failed("Playback didn't quit – it may be asking something. Quit it yourself (⌘Q), then try again.")
                    return
                }
            }
            stage = .working("Updating Playback's setlist…")
            do {
                // Re-read after quitting: Playback may have saved changes on the way out.
                let lib = try PlaybackSync.read()
                let plan = PlaybackSync.plan(library.playbackSongs(currentSet), library: lib,
                                             setTimeSignatures: setTimeSignatures)
                guard plan.canApply else { stage = .ready(plan); return }
                let r = try PlaybackSync.apply(plan)
                PlaybackSync.openPlayback()
                stage = .done(r)
            } catch {
                stage = .failed(error.localizedDescription)
                PlaybackSync.openPlayback()
            }
        }
    }

    private func undo() {
        guard let backup = PlaybackSync.latestBackup else { return }
        Task {
            stage = .working("Quitting Playback…")
            guard await PlaybackSync.quitPlayback() else {
                stage = .failed("Playback didn't quit. Quit it yourself (⌘Q), then try again."); return
            }
            do {
                try PlaybackSync.restore(backup)
                try? FileManager.default.removeItem(at: backup)
                PlaybackSync.openPlayback()
                stage = .failed("Restored Playback's library from before the last sync. Playback is reopening.")
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }
}
#endif
