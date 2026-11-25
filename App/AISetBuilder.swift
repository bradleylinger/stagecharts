import SwiftUI
import ChordProKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - 4. Build a set list from pasted text (e.g. the worship leader's email)

/// What Claude read from the pasted text.
struct ProposedSet: Codable {
    struct Song: Codable {
        let requested: String       // the song as written in the text
        let songID: String?         // the matching library song's id, or nil when it isn't in the library
        let key: String?            // key asked for in the text, e.g. "Bb", "F#m"
        let note: String?           // anything else said about it ("acoustic intro", "skip v2")
    }
    let name: String
    let date: String?               // yyyy-MM-dd
    let songs: [Song]
}

enum AISetBuilder {
    static let system = """
    You turn a worship leader's message (usually an email) into a set list for a chord-chart app. \
    The message lists songs to play, often with keys, notes, a service date and other chatter \
    (rehearsal times, reminders, who's playing). Pick out only the songs to be played, in order. \
    Match each one to the band's library by title, allowing for typos, shortened titles, missing \
    words and artist names (e.g. "Goodness" → "Goodness of God", "10,000 Reasons" → "10,000 Reasons \
    (Bless the Lord)"). Use the library id exactly as given. If a song isn't in the library, give \
    songID null; never match it to a different song. If a song appears twice (e.g. a reprise), \
    include it twice. Give the key only if the message says it, as a plain key like "G", "Bb" or \
    "F#m" ("in A", "key of Bb", "(E)", "capo 2 G shapes" means the sounding key A). Put other short \
    instructions about a song in note. Name the set after the service in the message (e.g. \
    "Sunday Nov 30" or "Christmas Eve") and give its date as yyyy-MM-dd if it can be worked out; \
    today's date is given for resolving "this Sunday".
    """

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "name": ["type": "string"],
            "date": ["type": ["string", "null"], "description": "yyyy-MM-dd"],
            "songs": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "requested": ["type": "string"],
                        "songID": ["type": ["string", "null"]],
                        "key": ["type": ["string", "null"]],
                        "note": ["type": ["string", "null"]],
                    ],
                    "required": ["requested", "songID", "key", "note"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["name", "date", "songs"],
        "additionalProperties": false,
    ]

    /// One line per library song: id, title, artist, original key.
    static func catalog(_ songs: [SongFile]) -> String {
        songs.map { f in
            var parts = ["id: \(f.id)", "title: \(f.song.title)"]
            if !f.song.artists.isEmpty { parts.append("artist: \(f.song.artists.joined(separator: ", "))") }
            if let k = f.song.key { parts.append("key: \(k.description)") }
            return parts.joined(separator: " | ")
        }.joined(separator: "\n")
    }

    static func propose(from text: String, library: [SongFile]) async throws -> ProposedSet {
        let df = DateFormatter(); df.dateFormat = "EEEE yyyy-MM-dd"
        let ask = """
        Today is \(df.string(from: Date())).

        <library>
        \(catalog(library))
        </library>

        <message>
        \(text)
        </message>
        """
        let reply = try await Claude.ask(system: system, content: [["type": "text", "text": ask]],
                                         effort: "medium", schema: schema, maxTokens: 8000)
        guard let set = try? JSONDecoder().decode(ProposedSet.self, from: Data(reply.utf8)), !set.songs.isEmpty else {
            throw AIError.api("Claude didn't find any songs in that text.")
        }
        return set
    }
}

/// Paste → Claude reads it → review the matches and keys → create the set.
@available(iOS 18, macOS 14, *)
struct AISetBuilderView: View {
    /// Called with the new set's id.
    let onCreated: (UUID) -> Void
    @EnvironmentObject var library: SongLibrary
    @Environment(\.dismiss) private var dismiss

    struct Row: Identifiable {
        let id = UUID()
        var requested: String
        var songID: String?
        var key: String?            // nil = the song's own key
        var note: String?
    }

    @State private var text = ""
    @State private var working = false
    @State private var error: String?
    @State private var rows: [Row]?
    @State private var name = ""
    @State private var date = Date()
    @State private var songSelect: SongSelectLink?
    struct SongSelectLink: Identifiable { let id = UUID(); let url: URL }

    var body: some View {
        SheetNavigation {
            Group {
                if rows != nil { review } else { paste }
            }
            .navigationTitle(rows == nil ? "Set list from text" : "Check the set")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if rows != nil {
                        Button("Create") { create() }.disabled(rows?.contains { $0.songID != nil } != true)
                    } else if working {
                        ProgressView()
                    } else {
                        Button("Read") { read() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 520)
        #endif
        #if DEBUG
        .onAppear { if ProcessInfo.processInfo.arguments.contains("-mockSetReply") { text = "test"; read() } }
        #endif
        // SongSelect opens on top of this sheet so the set being checked isn't lost.
        .sheet(item: $songSelect) { link in SongSelectBrowser(start: link.url) }
        .onChange(of: library.songs.count) { _ in matchNewSongs() }
    }

    /// After a download from SongSelect, fill in rows that weren't in the library.
    private func matchNewSongs() {
        guard var r = rows else { return }
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        for i in r.indices where r[i].songID == nil {
            let want = norm(r[i].requested)
            guard !want.isEmpty else { continue }
            if let f = library.songs.first(where: { norm($0.song.title) == want })
                ?? library.songs.first(where: { norm($0.song.title).hasPrefix(want) || want.hasPrefix(norm($0.song.title)) }) {
                r[i].songID = f.id
            }
        }
        rows = r
    }

    // MARK: Step 1: paste

    private var paste: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 220)
                    .font(.callout)
                    .disabled(working)
                Button("Paste from clipboard", systemImage: "doc.on.clipboard") {
                    #if os(iOS)
                    text = UIPasteboard.general.string ?? text
                    #else
                    text = NSPasteboard.general.string(forType: .string) ?? text
                    #endif
                }
                .disabled(working)
            } header: {
                Text("Paste the email from your worship leader")
            } footer: {
                Text("Claude picks out the songs, their keys and the date, and matches them to your library. Then you check it before the set is made. The text and your song titles are sent to Anthropic with your API key (Settings → SongSelect & AI).")
            }
            if working {
                Section { HStack { ProgressView(); Text("Reading…").foregroundStyle(.secondary) } }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
    }

    private func read() {
        #if DEBUG
        let mock = ProcessInfo.processInfo.arguments.contains("-mockSetReply")
        #else
        let mock = false
        #endif
        guard AIKey.isSet || mock else { error = AIError.noKey.localizedDescription; return }
        working = true; error = nil
        let input = text, songs = library.songs
        Task {
            do {
                var set: ProposedSet
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-mockSetReply") {      // UI check without an API call
                    let ids = songs.prefix(3).map(\.id)
                    set = ProposedSet(name: "Sunday Nov 30", date: "2026-11-30", songs: [
                        .init(requested: "amazing grace", songID: ids.first, key: "A", note: "Acoustic intro, full band on v2"),
                        .init(requested: "Firm Foundation", songID: nil, key: "C", note: nil),
                        .init(requested: ids.count > 1 ? "second one" : "x", songID: ids.dropFirst().first, key: nil, note: nil),
                    ])
                } else { set = try await AISetBuilder.propose(from: input, library: songs) }
                #else
                set = try await AISetBuilder.propose(from: input, library: songs)
                #endif
                name = set.name
                if let d = set.date, let parsed = Self.ymd.date(from: d) { date = parsed }
                rows = set.songs.map { s in
                    let id = s.songID.flatMap { library.song(id: $0) != nil ? $0 : nil }
                    return Row(requested: s.requested, songID: id, key: s.key.flatMap { Key($0)?.description }, note: s.note)
                }
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }

    // MARK: Step 2: review

    private var review: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                DatePicker("Date", selection: $date, displayedComponents: .date)
            }
            Section {
                ForEach(Binding(get: { rows ?? [] }, set: { rows = $0 })) { $row in rowView($row) }
                    .onMove { rows?.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { rows?.remove(atOffsets: $0) }
            } header: {
                Text("Songs")
            } footer: {
                let missing = rows?.filter { $0.songID == nil }.count ?? 0
                Text(missing == 0 ? "Keys left on “Song's key” use the key you normally play it in."
                     : "\(missing) song\(missing == 1 ? " isn't" : "s aren't") in your library and won't be added. Get it from SongSelect, then add it to the set.")
            }
            Section {
                Button("Start over") { rows = nil }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func rowView(_ row: Binding<Row>) -> some View {
        let r = row.wrappedValue
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: r.songID == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(r.songID == nil ? .orange : .green)
                Picker(selection: row.songID) {
                    Text("Not in library – skip").tag(String?.none)
                    ForEach(library.songs.sorted { $0.song.title < $1.song.title }) { f in
                        Text(f.song.title + (f.song.artists.first.map { " – \($0)" } ?? "")).tag(Optional(f.id))
                    }
                } label: {
                    Text(r.songID.flatMap { library.song(id: $0)?.song.title } ?? r.requested).fontWeight(.semibold)
                }
            }
            if r.songID != nil {
                Picker("Key", selection: row.key) {
                    Text("Song's key" + (originalKey(r).map { " (\($0))" } ?? "")).tag(String?.none)
                    ForEach(keyChoices(r), id: \.self) { Text($0).tag(Optional($0)) }
                }
            } else {
                Button("Find “\(r.requested)” on SongSelect", systemImage: "globe") {
                    var c = URLComponents(string: "https://songselect.ccli.com/search/results")!
                    c.queryItems = [URLQueryItem(name: "search", value: r.requested)]
                    songSelect = SongSelectLink(url: c.url ?? SongSelect.home)
                }
                .font(.callout)
            }
            if r.songID != nil, let title = r.songID.flatMap({ library.song(id: $0)?.song.title }),
               title.lowercased() != r.requested.lowercased() {
                Text("Email said: “\(r.requested)”").font(.caption).foregroundStyle(.secondary)
            }
            if let note = r.note, !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func originalKey(_ r: Row) -> String? {
        r.songID.flatMap { library.song(id: $0)?.song.key?.description }
    }
    private func keyChoices(_ r: Row) -> [String] {
        let minor = r.songID.flatMap { library.song(id: $0)?.song.key?.isMinor } ?? (r.key?.hasSuffix("m") ?? false)
        var keys = (0..<12).map { Key(root: $0, isMinor: minor).description }
        if let k = r.key, !keys.contains(k) { keys.append(k) }
        return keys
    }

    private func create() {
        let items: [SetItem] = (rows ?? []).compactMap { r in
            guard let id = r.songID, let f = library.song(id: id) else { return nil }
            var item = SetItem(songID: id)
            if let want = r.key.flatMap(Key.init), let original = f.song.key {
                item.semitones = original.semitones(to: want)
            }
            return item
        }
        guard !items.isEmpty else { return }
        let set = library.createSet(name: name.isEmpty ? "New set" : name, date: date)
        library.updateSet(set.id) { $0.items = items }
        onCreated(set.id)
        dismiss()
    }

    private static let ymd: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
}
