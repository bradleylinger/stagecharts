// Prints MIDI from the source named argv[1] for argv[2] seconds.
import CoreMIDI
import Foundation
let want = CommandLine.arguments[1], secs = Double(CommandLine.arguments[2]) ?? 10
var client = MIDIClientRef(), port = MIDIPortRef()
MIDIClientCreateWithBlock("listen" as CFString, &client, nil)
MIDIInputPortCreateWithProtocol(client, "in" as CFString, ._1_0, &port) { list, _ in
    for p in list.unsafeSequence() {
        let w = p.pointee.words.0
        print(String(format: "received status 0x%02X %d %d", (w >> 16) & 0xFF, (w >> 8) & 0x7F, w & 0x7F)); fflush(stdout)
    }
}
var found = false
for i in 0..<MIDIGetNumberOfSources() {
    var n: Unmanaged<CFString>?; MIDIObjectGetStringProperty(MIDIGetSource(i), kMIDIPropertyDisplayName, &n)
    if (n?.takeRetainedValue() as String?) == want { MIDIPortConnectSource(port, MIDIGetSource(i), nil); found = true }
}
print(found ? "listening to \(want)" : "source \(want) not found"); fflush(stdout)
RunLoop.current.run(until: Date().addingTimeInterval(secs))
