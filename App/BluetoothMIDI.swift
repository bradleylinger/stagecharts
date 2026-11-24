import SwiftUI
#if canImport(CoreAudioKit) && os(iOS)
import CoreAudioKit

/// Apple's Bluetooth MIDI pairing screen. On iPhone/iPad, Bluetooth MIDI devices (pedals, WIDI, etc.)
/// are connected from inside an app; once connected, StageCharts receives from them like any other input.
struct BluetoothMIDIPairingView: UIViewControllerRepresentable {
    var onDone: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let vc = CABTMIDICentralViewController()
        vc.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: context.coordinator,
                                                               action: #selector(Coordinator.done))
        return UINavigationController(rootViewController: vc)
    }
    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject {
        let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }
        @objc func done() { onDone() }
    }
}
#endif

/// Settings row: pair Bluetooth MIDI devices (iOS: Apple's pairing screen; Mac: Audio MIDI Setup).
struct BluetoothMIDIButton: View {
    var onChange: () -> Void
    @State private var showing = false

    var body: some View {
        #if os(iOS)
        Button("Bluetooth MIDI devices…") { showing = true }
            .sheet(isPresented: $showing, onDismiss: onChange) {
                BluetoothMIDIPairingView { showing = false }
            }
        #else
        Button("Bluetooth MIDI devices…") {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.audio.AudioMIDISetup") {
                NSWorkspace.shared.openApplication(at: app, configuration: .init())
            }
        }
        .help("Opens Audio MIDI Setup. Choose Window → Show MIDI Studio, then click the Bluetooth button in its toolbar to connect a device.")
        #endif
    }
}
