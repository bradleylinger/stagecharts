// Test MIDI sender: creates a virtual source "Test Sender" and sends messages.
// Usage: midisend <channel 1-16> pc <1-128> | cc <num> <val> [more...]   e.g. midisend 1 pc 3 cc 20 127
import CoreMIDI
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
// Optional: --net "<Bonjour session name>" sends over network MIDI (like Audio MIDI Setup → Connect).
var netTarget: String? = nil
if args.first == "--net" { netTarget = args[1]; args.removeFirst(2) }
// Optional: --dest "<destination name>" sends to an existing MIDI destination (e.g. "Network Session 1").
var destName: String? = nil
if args.first == "--dest" { destName = args[1]; args.removeFirst(2) }
if args.first == "--list" {
    for i in 0..<MIDIGetNumberOfDestinations() {
        var n: Unmanaged<CFString>?; MIDIObjectGetStringProperty(MIDIGetDestination(i), kMIDIPropertyDisplayName, &n)
        print("dest:", (n?.takeRetainedValue() as String?) ?? "?")
    }
    let s = MIDINetworkSession.default()
    print("network session enabled:", s.isEnabled, "name:", s.networkName, "connections:", s.connections().map { $0.host.name })
    exit(0)
}
guard let ch = Int(args.first ?? ""), (1...16).contains(ch) else { print("usage: midisend <ch> pc N | cc N V ..."); exit(1) }
args.removeFirst()

var client = MIDIClientRef(), source = MIDIEndpointRef()
MIDIClientCreateWithBlock("midisend" as CFString, &client, nil)
MIDISourceCreateWithProtocol(client, "Test Sender" as CFString, ._1_0, &source)
var outPort = MIDIPortRef()
var netDest: MIDIEndpointRef = 0
if let want = destName {
    for i in 0..<MIDIGetNumberOfDestinations() {
        var n: Unmanaged<CFString>?; MIDIObjectGetStringProperty(MIDIGetDestination(i), kMIDIPropertyDisplayName, &n)
        if (n?.takeRetainedValue() as String?) == want { netDest = MIDIGetDestination(i) }
    }
    guard netDest != 0 else { print("no destination named \(want)"); exit(1) }
    MIDIOutputPortCreate(client, "out" as CFString, &outPort)
    netTarget = want
} else if let name = netTarget {
    let session = MIDINetworkSession.default()
    session.isEnabled = true
    session.connectionPolicy = .anyone
    // "--net host.local:5004" connects by address; otherwise by Bonjour name.
    let host: MIDINetworkHost
    if let colon = name.lastIndex(of: ":"), let port = Int(name[name.index(after: colon)...]) {
        host = MIDINetworkHost(name: String(name[..<colon]), address: String(name[..<colon]), port: port)
    } else {
        host = MIDINetworkHost(name: name, netService: NetService(domain: "local.", type: "_apple-midi._udp", name: name))
    }
    let conn = MIDINetworkConnection(host: host)
    print("connecting to \(name):", session.addConnection(conn))
    netDest = session.destinationEndpoint()
    MIDIOutputPortCreate(client, "out" as CFString, &outPort)
    RunLoop.current.run(until: Date().addingTimeInterval(3))   // let the RTP-MIDI handshake finish
    print("connections:", session.connections().map { $0.host.name })
} else {
    Thread.sleep(forTimeInterval: 1.5)   // give listeners time to connect to the new source
}

func send(_ status: UInt8, _ d1: Int, _ d2: Int) {
    let word = (UInt32(0x2) << 28) | (UInt32(status) << 16) | (UInt32(d1 & 0x7F) << 8) | UInt32(d2 & 0x7F)
    var list = MIDIEventList()
    let pkt = MIDIEventListInit(&list, ._1_0)
    var w = word
    _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, pkt, 0, 1, &w)
    if netTarget != nil { MIDISendEventList(outPort, netDest, &list) } else { MIDIReceivedEventList(source, &list) }
    print(String(format: "sent 0x%02X %d %d", status, d1, d2))
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
}

var i = 0
while i < args.count {
    switch args[i] {
    case "pc": send(0xC0 | UInt8(ch - 1), Int(args[i + 1])! - 1, 0); i += 2
    case "cc": send(0xB0 | UInt8(ch - 1), Int(args[i + 1])!, Int(args[i + 2])!); i += 3
    case "note": send(0x90 | UInt8(ch - 1), Int(args[i + 1])!, Int(args[i + 2])!); send(0x80 | UInt8(ch - 1), Int(args[i + 1])!, 0); i += 3
    case "wait": Thread.sleep(forTimeInterval: Double(args[i + 1])!); i += 2
    default: print("unknown \(args[i])"); exit(1)
    }
}
Thread.sleep(forTimeInterval: 0.5)
