import Foundation
import MultipeerConnectivity
#if os(iOS)
import UIKit
#endif

/// What the leader sends to followers.
enum BandMessage: Codable {
    case set(SetBundle)                          // the set list and its charts (sent on join and on changes)
    case select(position: Int?, songID: String)  // song changed (position in set, or a library song)
    case scroll(Double)                          // 0...1 of the chart
    case song(SetBundle.Song)                    // a library song (no set selected): send the chart itself
}

/// Band follow mode over the local network (Wi-Fi / peer-to-peer) using MultipeerConnectivity.
/// One iPad leads; followers mirror its set list, song changes and scrolling.
@MainActor
final class BandSync: NSObject, ObservableObject {
    enum Role: String, CaseIterable, Identifiable {
        case off, lead, follow
        var id: String { rawValue }
        var title: String {
            switch self { case .off: return "Off"; case .lead: return "Lead"; case .follow: return "Follow" }
        }
    }

    @Published var role: Role = .off { didSet { if role != oldValue { restart() } } }
    @Published private(set) var peers: [String] = []
    @Published private(set) var leaderName: String?

    // Follower callbacks (wired by ContentView)
    var onSet: ((SetBundle) -> Void)?
    var onSelect: ((Int?, String) -> Void)?
    var onScroll: ((Double) -> Void)?
    var onSong: ((SetBundle.Song) -> Void)?
    /// Leader: current state to send to someone who just joined.
    var snapshot: (() -> [BandMessage])?

    private static let serviceType = "stagecharts"     // Bonjour: _stagecharts._tcp / _udp
    private let me: MCPeerID
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var lastScrollSent = Date.distantPast
    private var pendingScroll: Double?

    override init() {
        #if os(iOS)
        let name = UIDevice.current.name
        #else
        let name = Host.current().localizedName ?? "Mac"
        #endif
        me = MCPeerID(displayName: String(name.prefix(60)))
        super.init()
        role = Role(rawValue: UserDefaults.standard.string(forKey: "bandRole") ?? "") ?? .off
        restart()
    }

    var statusText: String {
        switch role {
        case .off: return "Off"
        case .lead: return peers.isEmpty ? "Leading – waiting for band" : "Leading \(peers.count) device\(peers.count == 1 ? "" : "s")"
        case .follow: return leaderName.map { "Following \($0)" } ?? "Looking for a leader…"
        }
    }

    private func restart() {
        UserDefaults.standard.set(role.rawValue, forKey: "bandRole")
        advertiser?.stopAdvertisingPeer(); advertiser = nil
        browser?.stopBrowsingForPeers(); browser = nil
        session?.disconnect(); session = nil
        peers = []; leaderName = nil
        guard role != .off else { return }

        let s = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        session = s
        switch role {
        case .lead:
            let a = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: ["role": "lead"], serviceType: Self.serviceType)
            a.delegate = self
            a.startAdvertisingPeer()
            advertiser = a
        case .follow:
            let b = MCNearbyServiceBrowser(peer: me, serviceType: Self.serviceType)
            b.delegate = self
            b.startBrowsingForPeers()
            browser = b
        case .off: break
        }
    }

    // MARK: Leader → followers

    func send(_ message: BandMessage, reliable: Bool = true) {
        guard role == .lead, let s = session, !s.connectedPeers.isEmpty,
              let data = try? JSONEncoder.setLists.encode(message) else { return }
        try? s.send(data, toPeers: s.connectedPeers, with: reliable ? .reliable : .unreliable)
    }

    /// Scroll updates are frequent: send at most ~12/second, always delivering the last position.
    func sendScroll(_ fraction: Double) {
        guard role == .lead, session?.connectedPeers.isEmpty == false else { return }
        pendingScroll = fraction
        let wait = 0.08 - Date().timeIntervalSince(lastScrollSent)
        if wait <= 0 { flushScroll() }
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.flushScroll() }
        }
    }

    private func flushScroll() {
        guard let f = pendingScroll else { return }
        pendingScroll = nil
        lastScrollSent = Date()
        send(.scroll(f), reliable: false)
    }

    // MARK: Followers ← leader

    private func receive(_ data: Data) {
        guard role == .follow, let message = try? JSONDecoder.setLists.decode(BandMessage.self, from: data) else { return }
        switch message {
        case .set(let bundle): onSet?(bundle)
        case .select(let position, let songID): onSelect?(position, songID)
        case .scroll(let f): onScroll?(f)
        case .song(let s): onSong?(s)
        }
    }

    private func peersChanged() {
        guard let s = session else { peers = []; return }
        peers = s.connectedPeers.map(\.displayName)
        if role == .follow { leaderName = peers.first }
    }
}

// MARK: - Delegates (called on background queues → hop to main)

extension BandSync: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            self.peersChanged()
            if state == .connected, self.role == .lead, let msgs = self.snapshot?(),
               let s = self.session {
                for m in msgs {
                    if let data = try? JSONEncoder.setLists.encode(m) { try? s.send(data, toPeers: [peerID], with: .reliable) }
                }
            }
        }
    }
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in self.receive(data) }
    }
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension BandSync: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in invitationHandler(self.role == .lead, self.session) }   // leader accepts band members
    }
}

extension BandSync: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard info?["role"] == "lead" else { return }
        Task { @MainActor in
            guard self.role == .follow, let s = self.session, s.connectedPeers.isEmpty else { return }
            browser.invitePeer(peerID, to: s, withContext: nil, timeout: 15)
        }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in self.peersChanged() }
    }
}
