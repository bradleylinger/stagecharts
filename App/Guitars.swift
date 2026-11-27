import Foundation
import Combine

/// One of the player's guitars and how the Helix guitar block evens it out (dB, -12…+12): level before the amp,
/// low shelf (150 Hz) and high shelf (3 kHz).
struct MyGuitar: Codable, Identifiable, Hashable {
    /// "Fender Player Stratocaster" → "Stratocaster".
    static func shortName(_ name: String) -> String {
        let skip: Set<String> = ["gibson", "fender", "reverend", "prs", "player", "deluxe", "series", "american", "standard"]
        let words = name.split(separator: " ").filter { !skip.contains($0.lowercased()) }
        return words.prefix(2).joined(separator: " ").isEmpty ? name : words.prefix(2).joined(separator: " ")
    }

    var id = UUID()
    var name: String
    /// Pickups and character, for Claude ("three single coils; bright, low output").
    var pickups: String
    var level: Double = 0
    var low: Double = 0
    var high: Double = 0

    /// -12…+12 dB → CC 0–127 (the knob's range in the preset).
    static func cc(_ db: Double) -> Int {
        let r = HelixBuilder.guitarRange
        return Int(((min(max(db, -r), r) + r) / (2 * r) * 127).rounded())
    }

    /// For Claude: "Fender Player Stratocaster: three single coils; bright, low output".
    var promptLine: String { pickups.isEmpty ? name : "\(name): \(pickups)" }
}

/// The player's guitars and which one they normally play. Kept on this device (the one sending MIDI).
final class GuitarStore: ObservableObject {
    static let shared = GuitarStore()
    private static let key = "helixGuitars", defaultKey = "helixDefaultGuitar"

    @Published var guitars: [MyGuitar] { didSet { save() } }
    @Published var defaultID: UUID? {
        didSet { UserDefaults.standard.set(defaultID?.uuidString, forKey: Self.defaultKey) }
    }

    /// Starting points: single coils get more level, a little more low end and less top than humbuckers.
    static let starters: [MyGuitar] = [
        MyGuitar(name: "Gibson Les Paul Traditional Pro", pickups: "two humbuckers; thick, dark, highest output",
               level: 0, low: -1.5, high: 1),
        MyGuitar(name: "Reverend Double Agent OG", pickups: "humbucker (bridge) and P-90 (neck); medium-high output",
               level: 1, low: -0.5, high: 0),
        MyGuitar(name: "Fender Deluxe Nashville Telecaster", pickups: "three single coils (Tele bridge, Strat middle, Tele neck); bright, low output",
               level: 3, low: 1, high: -2),
        MyGuitar(name: "Fender Player Stratocaster", pickups: "three single coils; bright, low output",
               level: 3, low: 1.5, high: -1.5),
    ]

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.key), let g = try? JSONDecoder().decode([MyGuitar].self, from: d) {
            guitars = g
        } else {
            guitars = Self.starters
        }
        defaultID = UserDefaults.standard.string(forKey: Self.defaultKey).flatMap(UUID.init) ?? guitars.first?.id
    }

    private func save() {
        if let d = try? JSONEncoder().encode(guitars) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    func guitar(_ id: UUID?) -> MyGuitar? { id.flatMap { id in guitars.first { $0.id == id } } }

    /// The guitar for a song in a set: the song's own choice, else the set's, else the usual one.
    func guitar(for item: SetItem, in set: SetList) -> MyGuitar? {
        guitar(item.guitar) ?? guitar(set.guitar) ?? guitar(defaultID) ?? guitars.first
    }

    func update(_ g: MyGuitar) {
        if let i = guitars.firstIndex(where: { $0.id == g.id }) { guitars[i] = g }
    }
}
