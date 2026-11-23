import SwiftUI
#if os(macOS)
import AbletonLink
#endif

/// Ableton Link: shares the song's exact tempo (and optionally Start/Stop) with Ableton Live
/// and other Link apps on the same network. Unlike MIDI clock, peers see the exact BPM.
/// - Mac: Ableton's open-source Link (GPL, Vendor/link) through its C API.
/// - iPhone/iPad: Ableton's LinkKit (tools/fetch-linkkit.sh); per Ableton's guidelines the user turns
///   Link and Start Stop Sync on in LinkKit's own settings screen.
@MainActor
final class LinkSession: ObservableObject {
    /// Link on/off. Mac: our toggle. iOS: mirrors the switch in LinkKit's settings screen.
    @Published var enabled: Bool {
        didSet {
            #if os(macOS)
            UserDefaults.standard.set(enabled, forKey: "linkEnabled"); abl_link_enable(link, enabled)
            #endif
        }
    }
    /// Share Start/Stop with peers that have Start Stop Sync on.
    @Published var startStopSync: Bool {
        didSet {
            #if os(macOS)
            UserDefaults.standard.set(startStopSync, forKey: "linkStartStopSync"); abl_link_enable_start_stop_sync(link, startStopSync)
            #endif
        }
    }
    /// Start the session (from bar 1) whenever a song is picked.
    @Published var startOnSong = UserDefaults.standard.bool(forKey: "linkStartOnSong") {
        didSet { UserDefaults.standard.set(startOnSong, forKey: "linkStartOnSong") }
    }
    @Published private(set) var peers = 0
    @Published private(set) var tempo: Double = 120
    @Published private(set) var isPlaying = false

    /// Beats per bar used to line up Start with peers' bars.
    var quantum: Double = 4

    #if os(macOS)
    nonisolated(unsafe) private let link = abl_link_create(120)
    nonisolated(unsafe) private let state = abl_link_create_session_state()
    #elseif canImport(UIKit)
    nonisolated(unsafe) let link: ABLLinkRef = ABLLinkNew(120)
    #endif

    init() {
        #if os(macOS)
        enabled = UserDefaults.standard.bool(forKey: "linkEnabled")
        startStopSync = UserDefaults.standard.object(forKey: "linkStartStopSync") as? Bool ?? true
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        abl_link_set_num_peers_callback(link, { n, ctx in
            let me = Unmanaged<LinkSession>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { me.peers = Int(n) }
        }, ctx)
        abl_link_set_tempo_callback(link, { t, ctx in
            let me = Unmanaged<LinkSession>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { me.tempo = t }
        }, ctx)
        abl_link_set_start_stop_callback(link, { p, ctx in
            let me = Unmanaged<LinkSession>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { me.isPlaying = p }
        }, ctx)
        abl_link_enable_start_stop_sync(link, startStopSync)
        abl_link_enable(link, enabled)
        #else
        enabled = ABLLinkIsEnabled(link)
        startStopSync = ABLLinkIsStartStopSyncEnabled(link)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        ABLLinkSetIsEnabledCallback(link, { on, ctx in
            let me = Unmanaged<LinkSession>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { me.enabled = on }
        }, ctx)
        ABLLinkSetIsStartStopSyncEnabledCallback(link, { on, ctx in
            let me = Unmanaged<LinkSession>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { me.startStopSync = on }
        }, ctx)
        ABLLinkSetNumPeersCallback(link, { n, ctx in
            let me = Unmanaged<LinkSession>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { me.peers = Int(n) }
        }, ctx)
        ABLLinkSetSessionTempoCallback(link, { t, ctx in
            let me = Unmanaged<LinkSession>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { me.tempo = t }
        }, ctx)
        ABLLinkSetStartStopCallback(link, { p, ctx in
            let me = Unmanaged<LinkSession>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { me.isPlaying = p }
        }, ctx)
        ABLLinkSetActive(link, true)
        #endif
    }

    /// The current song's tempo becomes the session tempo.
    func songTempoChanged(_ bpm: Int?) {
        guard enabled, let bpm, bpm >= 20, bpm <= 999 else { return }
        let t = Double(bpm)
        #if os(macOS)
        edit { s, now in abl_link_set_tempo(s, t, now) }
        #else
        edit { s, now in ABLLinkSetTempo(s, t, now) }
        #endif
        tempo = t
        if startOnSong { start() }
    }

    func start() {
        guard enabled else { return }
        let q = quantum
        #if os(macOS)
        edit { s, now in abl_link_set_is_playing_and_request_beat_at_time(s, true, now, 0, q) }
        #else
        edit { s, now in ABLLinkSetIsPlayingAndRequestBeatAtTime(s, true, now, 0, q) }
        #endif
        isPlaying = true
    }

    func stop() {
        guard enabled else { return }
        #if os(macOS)
        edit { s, now in abl_link_set_is_playing(s, false, now) }
        #else
        edit { s, now in ABLLinkSetIsPlaying(s, false, now) }
        #endif
        isPlaying = false
    }

    #if os(macOS)
    private func edit(_ change: (abl_link_session_state, Int64) -> Void) {
        abl_link_capture_app_session_state(link, state)
        change(state, abl_link_clock_micros(link))
        abl_link_commit_app_session_state(link, state)
    }
    #else
    /// LinkKit times are host times (mach_absolute_time).
    private func edit(_ change: (ABLLinkSessionStateRef, UInt64) -> Void) {
        guard let s = ABLLinkCaptureAppSessionState(link) else { return }
        change(s, mach_absolute_time())
        ABLLinkCommitAppSessionState(link, s)
    }
    #endif
}

#if canImport(UIKit)
/// LinkKit's own settings screen (where the user turns Link and Start Stop Sync on).
struct LinkKitSettingsView: UIViewControllerRepresentable {
    let link: ABLLinkRef
    func makeUIViewController(context: Context) -> UIViewController {
        let vc = ABLLinkSettingsViewController.instance(link)!
        return UINavigationController(rootViewController: vc)
    }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}
}
#endif

/// Settings → Ableton Link.
struct LinkSettingsSection: View {
    @ObservedObject var link: LinkSession
    @State private var showLinkKit = false

    var body: some View {
        Section {
            #if os(macOS)
            Toggle("Ableton Link", isOn: $link.enabled)
            #else
            Button(link.enabled ? "Ableton Link: On" : "Ableton Link: Off") { showLinkKit = true }
                .sheet(isPresented: $showLinkKit) {
                    LinkKitSettingsView(link: link.link)
                }
            #endif
            if link.enabled {
                HStack {
                    Text(String(format: "%.2f BPM", link.tempo)).font(.body.monospacedDigit())
                    Text(link.isPlaying ? "Playing" : "Stopped").foregroundColor(.secondary)
                    Text(link.peers == 0 ? "· no other Link apps found" : "· \(link.peers) connected")
                        .foregroundColor(link.peers == 0 ? .orange : .secondary)
                    Spacer()
                    Button("Start") { link.start() }
                    Button("Stop") { link.stop() }
                }
                .buttonStyle(.bordered)
                #if os(macOS)
                Toggle("Share Start / Stop", isOn: $link.startStopSync)
                #endif
                Toggle("Start when a song is picked", isOn: $link.startOnSong)
                    .disabled(!link.startStopSync)
            }
        } header: {
            Text("Ableton Link")
        } footer: {
            #if os(macOS)
            Text("Shares the exact tempo of the song you pick with Ableton Live and other Link apps on the same network (Wi‑Fi or cable). In Ableton, click the Link button at the top left; for Start / Stop also turn on Start Stop Sync in Settings → Link, Tempo & MIDI. Use Link or MIDI clock with Ableton, not both.")
            #else
            Text("Shares the exact tempo of the song you pick with Ableton Live and other Link apps on the same Wi‑Fi. Tap above to turn Link (and Start Stop Sync) on. In Ableton, click the Link button at the top left. Use Link or MIDI clock with Ableton, not both.")
            #endif
        }
    }
}
