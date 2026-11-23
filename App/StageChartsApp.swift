import SwiftUI
#if os(macOS)
import Sparkle

/// Sparkle auto-updater (Mac only): checks the GitHub releases appcast daily.
final class AppUpdater {
    let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
}
#endif

@main
struct StageChartsApp: App {
    @StateObject private var library: SongLibrary
    @StateObject private var googleAuth: GoogleAuth
    @StateObject private var drive: GoogleDriveSync
    @StateObject private var importer: AutoImporter

    init() {
        let lib = SongLibrary(), auth = GoogleAuth()
        _library = StateObject(wrappedValue: lib)
        _googleAuth = StateObject(wrappedValue: auth)
        _drive = StateObject(wrappedValue: GoogleDriveSync(auth: auth, library: lib))
        _importer = StateObject(wrappedValue: AutoImporter(library: lib))
    }
    @StateObject private var midi = MIDIController()
    @StateObject private var band = BandSync()
    #if os(macOS)
    private let updater = AppUpdater()
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("chartStyle") private var styleRaw = ChartStyle.classic.rawValue

    var body: some Scene {
        WindowGroup {
            root
                .environmentObject(library)
                .environmentObject(midi)
                .environmentObject(band)
                .environmentObject(googleAuth)
                .environmentObject(drive)
                .environmentObject(importer)
                #if os(iOS)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }   // keep screen on stage
                #endif
                .preferredColorScheme((ChartStyle(rawValue: styleRaw) ?? .classic).colorScheme)
                .onAppear { wireLearning(); exportForTesting() }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])   // open files in this window
                .onChange(of: scenePhase) { phase in
                    guard phase == .active else { return }
                    if library.usesCustomFolder { library.reloadAll() }   // pick up synced changes
                    drive.scheduleSync(after: 0)
                }
                .onAppear { drive.scheduleSync(after: 0) }
        }
        #if os(macOS)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.controller.checkForUpdates(nil) }
            }
            CommandGroup(after: .importExport) {
                Button("Import OnSong Backup…") { importOnSongBackup() }
            }
        }
        #endif
        #if os(macOS)
        Settings {          // ⌘, on the Mac
            SettingsView(showsDoneButton: false)
                .onAppear { exportForTesting() }      // dev hooks also run if only Settings reopens
                .environmentObject(library)
                .environmentObject(googleAuth)
                .environmentObject(drive)
                .environmentObject(importer)
                .environmentObject(midi)
                .environmentObject(band)
                .preferredColorScheme((ChartStyle(rawValue: styleRaw) ?? .classic).colorScheme)
        }
        #endif
    }

    /// Full app on iPadOS 18+ / macOS; the band viewer on older iPads (or when chosen in Settings).
    @ViewBuilder private var root: some View {
        if #available(iOS 18, macOS 14, *), !UserDefaults.standard.bool(forKey: "bandViewerMode") {
            ContentView()
        } else {
            ViewerRootView()
        }
    }

    #if os(macOS)
    /// File › Import OnSong Backup…: pick a .backup file, import, then show the summary.
    private func importOnSongBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose an OnSong backup (OnSong › Utilities › Backup & Restore › Back Up Library)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        do {
            let report = try OnSongImporter.importBackup(url, into: library)
            alert.messageText = "OnSong import finished"
            alert.informativeText = report.summary
        } catch {
            alert.messageText = "OnSong import failed"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }
    #endif

    /// Developer hook: STAGECHARTS_EXPORT_PDF=/path.pdf exports the active set as a PDF, then quits.
    private func exportForTesting() {
        #if os(macOS)
        if let backup = ProcessInfo.processInfo.environment["STAGECHARTS_IMPORT_ONSONG"] {
            do {
                let r = try OnSongImporter.importBackup(URL(fileURLWithPath: backup), into: library)
                print("ONSONG RESULT:\n" + r.summary)
                print("ONSONG LISTS: pdfOnly=\(r.pdfOnly) documents=\(r.documents) failed=\(r.failed)")
            } catch { print("ONSONG ERROR:", error.localizedDescription) }
            UserDefaults.standard.synchronize()
            exit(0)
        }
        #endif
        if let files = ProcessInfo.processInfo.environment["STAGECHARTS_IMPORT"] {
            library.importFiles(files.split(separator: "|").map { URL(fileURLWithPath: String($0)) })
            print("IMPORT RESULT:", library.lastError ?? "ok")
            UserDefaults.standard.synchronize()
            exit(0)
        }
        if let folder = ProcessInfo.processInfo.environment["STAGECHARTS_LIBRARY_FOLDER"] {
            if folder == "device" { library.useDeviceStorage() } else { try? library.useFolder(URL(fileURLWithPath: folder)) }
            UserDefaults.standard.synchronize()
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
