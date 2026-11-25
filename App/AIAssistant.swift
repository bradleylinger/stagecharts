import Foundation
import Security
import PDFKit
import ChordProKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// AI features (Claude): turning chart documents/photos into transposable ChordPro, and suggesting
// transitions between songs in a set. The user's own Anthropic API key is kept in the Keychain;
// only the chart / song details being worked on are sent.

enum AIError: LocalizedError {
    case noKey, api(String), refused, empty, unsupported(String)
    var errorDescription: String? {
        switch self {
        case .noKey: return "Add your Anthropic API key in Settings → AI first."
        case .api(let m): return m
        case .refused: return "Claude declined this request."
        case .empty: return "Claude didn't return a chart. Try again."
        case .unsupported(let k): return "\(k) files can't be sent to Claude yet – use a PDF or a photo."
        }
    }
}

/// The API key, in the Keychain (this device only; not synced).
enum AIKey {
    private static let service = "StageCharts.Anthropic", account = "api-key"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static var value: String? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static var isSet: Bool { value?.isEmpty == false }
    static func save(_ key: String) {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
    static func remove() { SecItemDelete(query as CFDictionary) }
}

/// Minimal Claude Messages API client (URLSession; there's no official Swift SDK).
enum Claude {
    static let model = "claude-opus-5-5"

    /// Models the player can choose for the Helix preset designer: (id, name, note).
    static let choices: [(id: String, name: String, note: String)] = [
        ("claude-opus-5-5", "Claude Opus 5.5", "recommended"),
        ("claude-fable-5-2", "Claude Fable 5.2", "most capable, about 2× the cost"),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5", "faster, about half the cost"),
    ]

    /// Sends one user turn; returns the text of the reply. With `tools` (server tools such as web search), a turn the
    /// API pauses is resumed, and only the text after the last tool result is returned (the final answer).
    static func ask(system: String, content: [[String: Any]], effort: String,
                    schema: [String: Any]? = nil, maxTokens: Int = 16000,
                    model: String = Claude.model, tools: [[String: Any]]? = nil) async throws -> String {
        guard let key = AIKey.value, !key.isEmpty else { throw AIError.noKey }
        var outputConfig: [String: Any] = ["effort": effort]
        if let schema { outputConfig["format"] = ["type": "json_schema", "schema": schema] }
        var messages: [[String: Any]] = [["role": "user", "content": content]]
        var reply: [[String: Any]] = []
        for _ in 0..<5 {
            var body: [String: Any] = [
                "model": model,
                "max_tokens": maxTokens,
                "system": system,
                "output_config": outputConfig,
                "fallbacks": "default",                 // on a policy decline, retry on a fallback model
                "messages": messages,
            ]
            if let tools { body["tools"] = tools }
            let json = try await send(body, key: key)
            if json["stop_reason"] as? String == "refusal" { throw AIError.refused }
            let blocks = json["content"] as? [[String: Any]] ?? []
            reply += blocks
            // A long server-tool loop pauses: send the turn so far back and the API carries on from there.
            guard json["stop_reason"] as? String == "pause_turn" else { break }
            if messages.count == 1 { messages.append(["role": "assistant", "content": reply]) }
            else { messages[1] = ["role": "assistant", "content": reply] }
        }
        let lastTool = reply.lastIndex { $0["type"] as? String != "text" } ?? -1
        let text = reply[(lastTool + 1)...].filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AIError.empty }
        return text
    }

    private static func send(_ body: [String: Any], key: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 900
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(http.statusCode)"
            switch http.statusCode {
            case 401: throw AIError.api("The API key wasn't accepted. Check it in Settings → AI.")
            case 429: throw AIError.api("Too many requests right now – wait a minute and try again.")
            default: throw AIError.api("Claude: \(msg)")
            }
        }
        return json
    }
}

// MARK: - 1. Convert a chart (PDF / photo) to ChordPro

enum AIChartConverter {
    static let system = """
    You convert worship chord charts into ChordPro for a chord-chart app. Transcribe exactly what the \
    chart says: every section, every lyric line and every chord, in order. Never invent, complete or \
    "fix" lyrics or chords, and never add sections that aren't on the chart. If something is unreadable, \
    write it as best you can and keep going.

    Output only the ChordPro text – no explanations and no code fences. Use this format:

    {title: Song Title}
    {artist: Writer One | Writer Two}          (writers / "Words and music by", joined with " | ")
    {key: G}                                   (the key the chart is written in)
    {tempo: 72}                                (only if shown)
    {time: 4/4}                                (only if shown)
    {ccli: 1234567}                            (the CCLI song number, only if shown)
    {copyright: 2019 Publisher | Publisher}    (only if shown)

    {comment: Verse 1}
    [G]Amazing grace how [C]sweet the [G]sound

    Rules:
    - Each section starts with {comment: Name} using the chart's own name (Intro, Verse 1, Pre-Chorus, \
    Chorus, Bridge, Tag, Interlude, Outro, Ending…).
    - Put each chord in square brackets immediately before the syllable it sits above. Split a word if \
    the chord falls mid-word (e.g. "a[D]mazing"). A chord at the end of a line goes after the last word.
    - Keep chord spellings exactly as printed (slash chords, sus, 7, add9, (b5)…).
    - Chord-only lines (intros, turnarounds, instrumentals) are written as bars: | [G] | [C] | [Em] [D] |
    - Keep repeat marks and directions as bracketed text the app shows in small type, e.g. [(x2)], [(To Chorus)], [(1.)].
    - Leave out page headers/footers, page numbers, license lines and the CCLI license number.
    - Two-column charts: read the whole left column top to bottom, then the right column.
    """

    /// Sends the document or photo to Claude and returns ChordPro.
    static func convert(fileURL: URL, hints: ChordProSong? = nil) async throws -> String {
        let block = try contentBlock(for: fileURL)
        var ask = "Convert this chord chart to ChordPro."
        if let h = hints {
            var known: [String] = []
            if !h.title.isEmpty { known.append("title: \(h.title)") }
            if let k = h.key { known.append("key: \(k.description)") }
            if let c = h.ccli { known.append("CCLI: \(c)") }
            if !h.artists.isEmpty { known.append("writers: \(h.artists.joined(separator: " | "))") }
            if !known.isEmpty { ask += " The library already knows: " + known.joined(separator: ", ") + " – use these if the chart agrees." }
        }
        var text = try await Claude.ask(system: system, content: [block, ["type": "text", "text": ask]], effort: "high")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {                               // strip a stray code fence
            text = text.components(separatedBy: "\n").dropFirst().filter { !$0.hasPrefix("```") }.joined(separator: "\n")
        }
        guard !ChordProSong(text).sections.isEmpty else { throw AIError.empty }
        // Mark it as converted (ranks below a real SongSelect ChordPro, which can still replace it).
        return ChordProDocument.setting("x_source", to: "ai", in: text)
    }

    private static func contentBlock(for url: URL) throws -> [String: Any] {
        let ext = url.pathExtension.lowercased()
        let data = try SongLibrary.coordinatedData(url).orThrow()
        if ext == "pdf" {
            return ["type": "document", "source": ["type": "base64", "media_type": "application/pdf", "data": data.base64EncodedString()]]
        }
        let direct = ["jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp"]
        if let mt = direct[ext] {
            return ["type": "image", "source": ["type": "base64", "media_type": mt, "data": data.base64EncodedString()]]
        }
        // HEIC / TIFF etc.: re-encode as JPEG.
        if let jpeg = jpegData(from: data) {
            return ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]]
        }
        throw AIError.unsupported(ext.uppercased())
    }

    private static func jpegData(from data: Data) -> Data? {
        #if os(iOS)
        return UIImage(data: data)?.jpegData(compressionQuality: 0.9)
        #else
        guard let img = NSImage(data: data), let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        #endif
    }
}

private extension Optional where Wrapped == Data {
    func orThrow() throws -> Data { guard let d = self else { throw CocoaError(.fileReadNoSuchFile) }; return d }
}

// MARK: - 3. Transitions between songs

struct TransitionIdea: Codable, Identifiable, Hashable {
    var id: String { name + bars }
    let name: String
    let bars: String          // e.g. "| C | G/B | Bb | D7sus D7 |" in sounding key
    let explanation: String
}

enum AITransitions {
    static let system = """
    You are an experienced worship band music director. Suggest short, playable transitions between two \
    songs in a set: a few bars that leave the first song's ending and lead naturally into the second \
    song's opening, at the band's keys and tempos. Prefer common, singable moves (pivot chords, \
    secondary dominants, sus4 to V, stepwise bass lines, a bar of the new key's IV or V). Give options \
    from simplest to most interesting. Write chords in the sounding key with standard names, bars \
    separated by "|". Keep each explanation to one or two short sentences a guitarist or keys player \
    can follow on stage.
    """

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "options": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Short label, e.g. \"Pivot on Em\""],
                        "bars": ["type": "string", "description": "Chord bars, e.g. \"| C | D/C | Bm7 | E7sus E7 |\""],
                        "explanation": ["type": "string"],
                    ],
                    "required": ["name", "bars", "explanation"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["options"],
        "additionalProperties": false,
    ]

    /// Last chords of a song (in the order played), at most `limit`.
    static func closingChords(_ song: ChordProSong, limit: Int = 8) -> [String] {
        var all: [String] = []
        for section in song.sections {
            for line in section.lines {
                guard case .lyrics(let segs) = line else { continue }
                for seg in segs { if let c = seg.chord, let f = c.first, "ABCDEFG".contains(f) { all.append(c) } }
            }
        }
        return Array(all.suffix(limit))
    }

    static func describe(_ r: RenderedSong, opening: Bool) -> String {
        var parts = ["\"\(r.song.title)\""]
        if let k = r.soundingKey { parts.append("key \(k.description)") }
        if let t = r.tempo { parts.append("\(t) BPM") }
        if let t = r.song.time { parts.append("\(t) time") }
        let chords = opening ? NextUpBar.openingChords(r.song) : closingChords(r.song)
        if !chords.isEmpty { parts.append((opening ? "opens with: " : "ends with: ") + chords.joined(separator: " ")) }
        if let sections = opening ? r.song.sections.first?.label : r.song.sections.last?.label {
            parts.append((opening ? "first section: " : "last section: ") + sections)
        }
        return parts.joined(separator: ", ")
    }

    /// `from` / `to` must be rendered in the sounding key (capo 0).
    static func suggest(from: RenderedSong, to: RenderedSong) async throws -> [TransitionIdea] {
        let ask = """
        Song 1 \(describe(from, opening: false)).
        Song 2 \(describe(to, opening: true)).
        Suggest 3 transitions of 2–8 bars from the end of song 1 into the start of song 2.
        """
        let text = try await Claude.ask(system: system, content: [["type": "text", "text": ask]],
                                        effort: "medium", schema: schema, maxTokens: 8000)
        struct Reply: Codable { let options: [TransitionIdea] }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(text.utf8)), !reply.options.isEmpty else {
            throw AIError.empty
        }
        return reply.options
    }

    // Saved suggestions (per song pair and keys), so they're not requested again.
    private static let cacheKey = "aiTransitions"
    static func cacheID(_ a: RenderedSong, _ b: RenderedSong) -> String {
        "\(a.song.title)|\(a.soundingKey?.description ?? "")|\(a.tempo ?? 0)→\(b.song.title)|\(b.soundingKey?.description ?? "")|\(b.tempo ?? 0)"
    }
    static func cached(_ id: String) -> [TransitionIdea]? {
        guard let d = UserDefaults.standard.data(forKey: cacheKey),
              let all = try? JSONDecoder().decode([String: [TransitionIdea]].self, from: d) else { return nil }
        return all[id]
    }
    static func store(_ ideas: [TransitionIdea], for id: String) {
        var all = (UserDefaults.standard.data(forKey: cacheKey))
            .flatMap { try? JSONDecoder().decode([String: [TransitionIdea]].self, from: $0) } ?? [:]
        all[id] = ideas
        if let d = try? JSONEncoder().encode(all) { UserDefaults.standard.set(d, forKey: cacheKey) }
    }
}
