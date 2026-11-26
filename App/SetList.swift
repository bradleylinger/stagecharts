import Foundation

/// One song in a set, with its own key and capo for that service (nil = use the song's saved setting).
struct SetItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var songID: String
    var semitones: Int? = nil
    var capo: Int? = nil
    /// Helix Native snapshot (0–7) recalled when this song opens (see Helix.swift).
    var helixSnapshot: Int? = nil
    /// The guitar played on this song in this set (nil = the set's guitar).
    var guitar: UUID? = nil
}

struct SetList: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var date: Date
    var items: [SetItem]
    /// The Helix Native preset made for this set (file name in the library's Helix folder).
    var helixPreset: String? = nil
    /// That preset's snapshot names (index = snapshot), shown beside each song.
    var helixSnapshotNames: [String]? = nil
    /// The guitar normally played in this set (nil = the usual guitar from Settings → Helix).
    var guitar: UUID? = nil
}

extension JSONEncoder {
    static var setLists: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var setLists: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension SongLibrary {
    /// The set as text for building the same setlist in Playback (MultiTracks) – e.g. paste into Claude with
    /// the MultiTracks connector. Keys are the sounding keys (no capo).
    func playbackText(_ set: SetList) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        var lines = ["Create a MultiTracks/Playback setlist named \"\(set.name)\" dated \(df.string(from: set.date)) with these songs in order. "
                     + "Match each song in my MultiTracks library (then the catalog) by title and artist, and set the key, tempo and time signature:", ""]
        for (i, item) in set.items.enumerated() {
            guard let f = song(id: item.songID) else { continue }
            let s = settings(for: f.id)
            let r = RenderedSong(file: f, semitones: item.semitones ?? s.semitones, capo: 0, tempo: s.tempo)
            var parts = ["\(i + 1). \(f.song.title)"]
            if !f.song.artists.isEmpty { parts.append("artist: \(f.song.artists.joined(separator: ", "))") }
            if let k = r.soundingKey { parts.append("key: \(k.description)") }
            if let t = r.tempo { parts.append("tempo: \(t) BPM") }
            if let t = f.song.time { parts.append("time: \(t)") }
            if let c = f.song.ccli { parts.append("CCLI \(c)") }
            lines.append(parts.joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
    }
}
