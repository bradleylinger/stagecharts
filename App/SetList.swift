import Foundation

/// One song in a set, with its own key and capo for that service (nil = use the song's saved setting).
struct SetItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var songID: String
    var semitones: Int? = nil
    var capo: Int? = nil
}

struct SetList: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var date: Date
    var items: [SetItem]
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
