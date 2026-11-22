import SwiftUI

@main
struct StageChartsApp: App {
    @StateObject private var library = SongLibrary()
    @StateObject private var midi = MIDIController()
    @StateObject private var band = BandSync()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("chartStyle") private var styleRaw = ChartStyle.classic.rawValue

    var body: some Scene {
        WindowGroup {
            root
                .environmentObject(library)
                .environmentObject(midi)
                .environmentObject(band)
                #if os(iOS)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }   // keep screen on stage
                #endif
                .preferredColorScheme((ChartStyle(rawValue: styleRaw) ?? .classic).colorScheme)
                .onAppear { wireLearning(); exportForTesting() }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])   // open files in this window
                .onChange(of: scenePhase) { phase in
                    if phase == .active, library.usesCustomFolder { library.reloadAll() }   // pick up synced changes
                }
        }
        #if os(macOS)
        Settings {          // ⌘, on the Mac
            SettingsView(showsDoneButton: false)
                .environmentObject(library)
                .environmentObject(midi)
                .environmentObject(band)
                .preferredColorScheme((ChartStyle(rawValue: styleRaw) ?? .classic).colorScheme)
        }
        #endif
    }

    /// Full app on iPadOS 18+ / macOS; the band viewer on older iPads (or when chosen in Settings).
    @ViewBuilder private var root: some View {
        if #available(iOS 18, macOS 15, *), !UserDefaults.standard.bool(forKey: "bandViewerMode") {
            ContentView()
        } else {
            ViewerRootView()
        }
    }

    /// Developer hook: STAGECHARTS_EXPORT_PDF=/path.pdf exports the active set as a PDF, then quits.
    private func exportForTesting() {
        if let files = ProcessInfo.processInfo.environment["STAGECHARTS_IMPORT"] {
            library.importFiles(files.split(separator: "|").map { URL(fileURLWithPath: String($0)) })
            print("IMPORT RESULT:", library.lastError ?? "ok")
            exit(0)
        }
        if let folder = ProcessInfo.processInfo.environment["STAGECHARTS_LIBRARY_FOLDER"] {
            if folder == "device" { library.useDeviceStorage() } else { try? library.useFolder(URL(fileURLWithPath: folder)) }
            exit(0)
        }
        guard let out = ProcessInfo.processInfo.environment["STAGECHARTS_EXPORT_PDF"],
              let set = UUID(uuidString: UserDefaults.standard.string(forKey: "activeSetID") ?? "").flatMap({ library.setList(id: $0) })
        else { return }
        let songs = set.items.compactMap { item -> RenderedSong? in
            guard let f = library.song(id: item.songID) else { return nil }
            let s = library.settings(for: f.id)
            return RenderedSong(file: f, semitones: item.semitones ?? s.semitones, capo: item.capo ?? s.capo, tempo: library.settings(for: f.id).tempo)
        }
        if out.hasSuffix(".stageset"), let url = try? library.exportSetBundle(set) {
            try? FileManager.default.removeItem(atPath: out)
            try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: out))
        } else if #available(iOS 16, macOS 13, *) {
            try? ChartPDF.data(for: songs, setTitle: set.name).write(to: URL(fileURLWithPath: out))
        }
        exit(0)
    }

    /// Connects MIDI learning/lookup to the song library.
    private func wireLearning() {
        midi.songTriggers = { [library] in library.songTriggers }
        midi.songTitle = { [library] id in library.song(id: id)?.song.title ?? id }
        midi.activeSetLength = { [library] in
            UUID(uuidString: UserDefaults.standard.string(forKey: "activeSetID") ?? "")
                .flatMap { library.setList(id: $0)?.items.count }
        }
        midi.onLearnSongTrigger = { [library] id, trigger in library.setTrigger(trigger, for: id) }
        midi.onActionClaimedTrigger = { [library] trigger in library.releaseTrigger(trigger) }
    }
}
