import SwiftUI
import WebKit
import ChordProKit

// Getting charts from SongSelect with as little effort as possible — while a person still clicks
// "Download" for each song (SongSelect offers no API to new apps, and its terms don't allow bots):
//  • a built-in SongSelect browser whose downloads go straight into the library,
//  • on the Mac, a watcher that imports SongSelect files arriving in the Downloads folder,
//  • an upgrade queue that opens each song needing a better chart, one after another.

enum SongSelect {
    static let home = URL(string: "https://songselect.ccli.com/")!
    /// Opens a song's chord sheet directly by CCLI number.
    static func chordSheet(ccli: String) -> URL? {
        URL(string: "https://songselect.ccli.com/songs/\(ccli)/x/viewchordsheet")
    }
}

/// Imports SongSelect downloads, tracks the upgrade queue and shows a short notice afterwards.
@MainActor
final class AutoImporter: ObservableObject {
    @Published var toast: String?
    @Published var queue: [String] = []          // song ids still to fetch
    @Published var queueTotal = 0
    @Published var browserURL: URL?              // non-nil = show the SongSelect browser
    @Published private(set) var watcherStatus = "Off"

    private let library: SongLibrary
    private var toastTask: Task<Void, Never>?
    #if os(macOS)
    private var watchTimer: Timer?
    private var seen: [String: Int] = [:]         // file path → size at last check (wait until stable)
    private var processed = Set<String>()
    #endif

    init(library: SongLibrary) {
        self.library = library
        #if os(macOS)
        if UserDefaults.standard.bool(forKey: "autoImportDownloads") { startWatching() }
        #endif
    }

    /// Songs that would gain from a fresh SongSelect download: shown as the original document
    /// (can't transpose), with a CCLI number to look them up by.
    var upgradeCandidates: [SongFile] {
        library.songs.filter { $0.song.source == .pdfDocument && ($0.song.ccli ?? "").isEmpty == false }
    }

    var currentQueueSong: SongFile? { queue.first.flatMap { library.song(id: $0) } }

    // MARK: Import

    /// Imports one downloaded chart; returns true if it added or upgraded a song.
    @discardableResult
    func importDownloaded(_ url: URL) -> Bool {
        let before = library.songs.map(\.raw)
        let summary = library.importFiles([url], silent: true)
        let changed = library.songs.map(\.raw) != before
        show(summary ?? (changed ? "Imported \(url.lastPathComponent)" : "\(url.deletingPathExtension().lastPathComponent): already in your library"))
        advanceQueue()
        return changed
    }

    private func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: Upgrade queue

    func startQueue() {
        queue = upgradeCandidates.map(\.id)
        queueTotal = queue.count
        openCurrent()
    }

    func open(song: SongFile) {
        queue = [song.id]; queueTotal = 1
        openCurrent()
    }

    func skip() {
        guard !queue.isEmpty else { return }
        queue.removeFirst()
        openCurrent()
    }

    func stopQueue() { queue = []; queueTotal = 0 }

    /// After an import, drop songs that no longer need upgrading and open the next one.
    private func advanceQueue() {
        guard !queue.isEmpty else { return }
        let before = queue.first
        queue.removeAll { id in library.song(id: id).map { $0.song.source != .pdfDocument } ?? true }
        if queue.first != before { openCurrent() }
    }

    private func openCurrent() {
        guard let song = currentQueueSong, let ccli = song.song.ccli, let url = SongSelect.chordSheet(ccli: ccli) else {
            if queueTotal > 0 { show("Upgrade queue finished") }
            queue = []; queueTotal = 0
            return
        }
        #if os(macOS)
        if UserDefaults.standard.bool(forKey: "songSelectInBrowser") { NSWorkspace.shared.open(url); return }
        #endif
        browserURL = url
    }

    // MARK: Mac Downloads watcher

    #if os(macOS)
    static var defaultDownloads: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }
    var watchFolder: URL {
        UserDefaults.standard.string(forKey: "autoImportFolder").map { URL(fileURLWithPath: $0) } ?? Self.defaultDownloads
    }

    func setWatchFolder(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: "autoImportFolder")
        if watchTimer != nil { startWatching() }
    }

    func setWatching(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "autoImportDownloads")
        on ? startWatching() : stopWatching()
    }

    private func startWatching() {
        stopWatching()
        // Only files that arrive from now on (never your existing Downloads).
        let since = Date()
        UserDefaults.standard.set(since, forKey: "autoImportSince")
        seen = [:]
        watcherStatus = "Watching \(watchFolder.lastPathComponent)"
        watchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
    }

    private func stopWatching() {
        watchTimer?.invalidate(); watchTimer = nil
        watcherStatus = "Off"
    }

    private func scan() {
        let fm = FileManager.default
        let since = (UserDefaults.standard.object(forKey: "autoImportSince") as? Date) ?? Date()
        let exts: Set<String> = ["pdf", "chordpro", "cho", "chopro", "pro", "txt"]
        guard let items = try? fm.contentsOfDirectory(at: watchFolder, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]) else { return }
        for url in items where exts.contains(url.pathExtension.lowercased()) && !processed.contains(url.path) {
            let v = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
            guard let created = v?.creationDate, created > since, let size = v?.fileSize, size > 0 else { continue }
            // Wait until the size stops changing (download finished).
            if seen[url.path] != size { seen[url.path] = size; continue }
            processed.insert(url.path)
            if Self.looksLikeSongSelect(url) { importDownloaded(url) }
        }
    }

    /// SongSelect files carry a CCLI song number (PDF footer / ChordPro {ccli}).
    private static func looksLikeSongSelect(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "pdf" {
            guard let text = try? PDFChordSheetImporter.chordPro(fromPDF: url) else { return false }
            return ChordProSong(text).ccli != nil
        }
        return SongLibrary.readText(url).map { ChordProSong($0).ccli != nil } ?? false
    }
    #endif
}

// MARK: - Built-in SongSelect browser

/// SongSelect in a web view: you sign in once and click Download; files go straight into the library.
struct SongSelectBrowser: View {
    @EnvironmentObject var importer: AutoImporter
    @Environment(\.dismiss) private var dismiss
    let start: URL

    var body: some View {
        SheetNavigation {
            VStack(spacing: 0) {
                if let song = importer.currentQueueSong, importer.queueTotal > 1 {
                    HStack {
                        Text("Upgrade \(importer.queueTotal - importer.queue.count + 1) of \(importer.queueTotal): ") + Text(song.song.title).bold()
                        Spacer()
                        Button("Skip") { importer.skip() }
                        Button("Stop") { importer.stopQueue() }
                    }
                    .font(.callout)
                    .padding(8)
                    .background(Color.accentColor.opacity(0.12))
                }
                Text("Open the Chords tab → Download → PDF (or ChordPro). It's imported automatically.")
                    .font(.caption).foregroundColor(.secondary).padding(4)
                WebView(url: importer.browserURL ?? start) { file in importer.importDownloaded(file) }
            }
            .navigationTitle("SongSelect")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { importer.stopQueue(); importer.browserURL = nil; dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 1000, minHeight: 760)
        #endif
        .overlay(alignment: .bottom) { ToastView() }
    }
}

/// WKWebView wrapper that turns downloads (incl. SongSelect's in-page PDF/ChordPro) into files.
struct WebView {
    let url: URL
    let onDownload: (URL) -> Void

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
        var onDownload: (URL) -> Void
        var lastURL: URL?
        private var destinations: [ObjectIdentifier: URL] = [:]
        init(onDownload: @escaping (URL) -> Void) { self.onDownload = onDownload }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let u = action.request.url, Self.grabInPage(u, in: webView, name: nil, coordinator: self) {
                decisionHandler(.cancel); return
            }
            decisionHandler(action.shouldPerformDownload ? .download : .allow)
        }

        /// window.open(…) of a generated file: import it instead of opening a new window.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let u = action.request.url, !Self.grabInPage(u, in: webView, name: nil, coordinator: self),
               u.scheme?.hasPrefix("http") == true {
                webView.load(action.request)          // other popups: open in the same view
            }
            return nil
        }

        /// blob:/data: URLs are SongSelect's generated files. Returns true if handled.
        static func grabInPage(_ u: URL, in webView: WKWebView, name: String?, coordinator: Coordinator) -> Bool {
            switch u.scheme {
            case "data":
                coordinator.log("navigate data: \(u.absoluteString.prefix(40))")
                coordinator.save(dataURL: u.absoluteString, name: name)
                return true
            case "blob":
                coordinator.log("navigate blob: \(u.absoluteString)")
                let js = "window.__stagechartsSend && window.__stagechartsSend(\(Self.jsString(u.absoluteString)), null)"
                webView.evaluateJavaScript(js) { _, err in if let err { coordinator.log("blob eval error \(err)") } }
                return true
            default: return false
            }
        }
        static func jsString(_ s: String) -> String {
            String(data: (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8), encoding: .utf8)!
                .dropFirst().dropLast().description
        }

        /// Diagnostics: tmp/songselect-downloads/log.txt
        func log(_ line: String) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("songselect-downloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = dir.appendingPathComponent("log.txt")
            if let size = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 100_000 { try? FileManager.default.removeItem(at: f) }
            let entry = Data("\(Date()) \(line)\n".utf8)
            if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(entry); try? h.close() }
            else { try? entry.write(to: f) }
        }
        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            decisionHandler(response.canShowMIMEType ? .allow : .download)
        }
        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                      completionHandler: @escaping (URL?) -> Void) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("songselect-downloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(UUID().uuidString.prefix(6) + "-" + suggestedFilename)
            destinations[ObjectIdentifier(download)] = dest
            completionHandler(dest)
        }
        /// SongSelect builds files in the page (blob: links); the injected script sends them here.
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "stagechartsLog" { log("js: \(message.body)"); return }
            guard let body = message.body as? [String: Any], let dataURL = body["data"] as? String else { return }
            log("received \(body["name"] ?? "?") \(dataURL.count) chars")
            save(dataURL: dataURL, name: body["name"] as? String)
        }

        func save(dataURL: String, name: String?) {
            guard let comma = dataURL.firstIndex(of: ",") else { return }
            let header = dataURL[..<comma]
            let payload = String(dataURL[dataURL.index(after: comma)...])
            let data = header.hasSuffix(";base64") ? Data(base64Encoded: payload)
                                                   : payload.removingPercentEncoding.map { Data($0.utf8) }
            guard let data else { log("could not decode"); return }
            let isPDF = data.starts(with: Data("%PDF".utf8))
            let raw = name ?? (isPDF ? "SongSelect.pdf" : "SongSelect.chordpro")
            let name = raw.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("songselect-downloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(UUID().uuidString.prefix(6) + "-" + name)
            guard (try? data.write(to: dest)) != nil else { return }
            log("saved \(dest.lastPathComponent)")
            DispatchQueue.main.async { self.onDownload(dest) }
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { log("download failed \(error)") }

        func downloadDidFinish(_ download: WKDownload) {
            log("download finished")
            guard let dest = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
            DispatchQueue.main.async { self.onDownload(dest) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onDownload: onDownload) }

    private func make(_ c: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()                                      // default store: stays signed in
        if let js = Bundle.main.url(forResource: "songselect-download", withExtension: "js").flatMap({ try? String(contentsOf: $0) }) {
            config.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            config.userContentController.add(c, name: "stagechartsDownload")
            config.userContentController.add(c, name: "stagechartsLog")
        }
        // Say "Safari": SongSelect's download code takes a web-view-hostile path for unknown browsers.
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        let v = WKWebView(frame: .zero, configuration: config)
        v.navigationDelegate = c
        v.uiDelegate = c
        if #available(iOS 16.4, macOS 13.3, *) { v.isInspectable = true }
        v.load(URLRequest(url: url)); c.lastURL = url
        return v
    }
    private func update(_ v: WKWebView, _ c: Coordinator) {
        c.onDownload = onDownload
        if c.lastURL != url { c.lastURL = url; v.load(URLRequest(url: url)) }     // queue moved to the next song
    }
}

#if os(iOS)
extension WebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { make(context.coordinator) }
    func updateUIView(_ v: WKWebView, context: Context) { update(v, context.coordinator) }
}
#else
extension WebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { make(context.coordinator) }
    func updateNSView(_ v: WKWebView, context: Context) { update(v, context.coordinator) }
}
#endif

/// Small notice for automatic imports.
struct ToastView: View {
    @EnvironmentObject var importer: AutoImporter
    var body: some View {
        if let t = importer.toast {
            Text(t)
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .shadow(radius: 4)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { importer.toast = nil }
        }
    }
}

/// The list of songs to re-download, with a Start button.
struct UpgradeQueueView: View {
    @EnvironmentObject var importer: AutoImporter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let songs = importer.upgradeCandidates
        return SheetNavigation {
            List {
                Section(footer: Text("These songs are shown as the original document and can't change key. Re-downloading each from SongSelect (PDF is fine) makes it transposable; set lists, keys, capos, notes and MIDI are kept.")) {
                    Button("Start (\(songs.count) songs)") { importer.startQueue(); dismiss() }
                        .disabled(songs.isEmpty)
                }
                Section(header: Text("Waiting for a better chart")) {
                    ForEach(songs) { s in
                        Button { importer.open(song: s); dismiss() } label: {
                            HStack { Text(s.song.title); Spacer(); Text("CCLI \(s.song.ccli ?? "")").font(.caption).foregroundColor(.secondary) }
                        }
                    }
                }
            }
            .navigationTitle("Upgrade from SongSelect")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }
}

/// A navigation container for sheets. On the Mac, NavigationView makes a sidebar + empty detail
/// (squeezing the content into a narrow column), so use a single-column stack there.
struct SheetNavigation<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        #if os(macOS)
        NavigationStack { content }
        #else
        NavigationView { content }.navigationViewStyle(.stack)
        #endif
    }
}
