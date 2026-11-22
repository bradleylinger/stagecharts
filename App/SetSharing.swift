import Foundation
import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// A set list plus its song charts, for sending to another device running StageCharts.
    static let stageSet = UTType(exportedAs: "com.bradlinger.stagecharts.set", conformingTo: .json)
}

/// File format of a .stageset: the set (with per-song keys/capos) and the ChordPro text of every song.
struct SetBundle: Codable {
    struct Song: Codable {
        var fileName: String
        var chordPro: String
        var notes: [SongNote]? = nil      // sticky notes travel with the chart
        var tempo: Int? = nil             // the band's BPM
    }
    var format = 1
    var set: SetList
    var songs: [Song]
}

extension SongLibrary {
    /// Writes the set and its songs to a temporary .stageset file.
    func makeSetBundle(_ set: SetList) -> SetBundle {
        var seen = Set<String>()
        let songs = set.items.compactMap { item -> SetBundle.Song? in
            guard seen.insert(item.songID).inserted, let f = song(id: item.songID) else { return nil }
            let s = settings(for: f.id)
            return SetBundle.Song(fileName: f.id, chordPro: f.raw, notes: s.notes.isEmpty ? nil : s.notes, tempo: s.tempo)
        }
        return SetBundle(set: set, songs: songs)
    }

    func exportSetBundle(_ set: SetList) throws -> URL {
        let bundle = makeSetBundle(set)
        let safe = set.name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).stageset")
        try JSONEncoder.setLists.encode(bundle).write(to: url, options: .atomic)
        return url
    }

    /// Imports a received .stageset: adds/updates its songs and adds the set (replacing an older
    /// copy of the same set). Returns the set's id.
    @discardableResult
    func importSetBundle(_ url: URL) throws -> UUID {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bundle = try JSONDecoder.setLists.decode(SetBundle.self, from: Data(contentsOf: url))
        return try importSetBundle(bundle)
    }

    /// Writes the bundle's songs (only those that changed) and adds/replaces its set.
    @discardableResult
    func importSetBundle(_ bundle: SetBundle) throws -> UUID {
        for s in bundle.songs {
            let name = (s.fileName as NSString).lastPathComponent     // never write outside Songs/
            guard !name.isEmpty, !name.hasPrefix(".") else { continue }
            if song(id: name)?.raw != s.chordPro {
                try s.chordPro.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            if let notes = s.notes, settings(for: name).notes != notes { update(name) { $0.notes = notes } }
            if let t = s.tempo, settings(for: name).tempo != t { update(name) { $0.tempo = t } }
        }
        reload()
        replaceOrAddSet(bundle.set)
        return bundle.set.id
    }
}

/// Lazily-built .stageset for ShareLink (AirDrop / Messages / Mail / Files).
@available(iOS 16, macOS 13, *)
struct SharedSetFile: Transferable {
    let name: String
    let make: @MainActor () throws -> URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .stageSet) { item in
            SentTransferredFile(try await MainActor.run { try item.make() })
        }
    }
}
