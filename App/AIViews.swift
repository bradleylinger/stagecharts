import SwiftUI
import ChordProKit

/// Converts a chart with Claude, shows the result, and saves it when accepted.
struct AIConvertSheet: View {
    enum Source { case song(SongFile), file(URL) }
    let source: Source
    var onSaved: (String) -> Void = { _ in }

    @EnvironmentObject var library: SongLibrary
    @Environment(\.dismiss) private var dismiss
    @AppStorage("chartStyle") private var styleRaw = ChartStyle.classic.rawValue
    @State private var result: String?
    @State private var error: String?
    @State private var working = false

    private var style: ChartStyle { ChartStyle(rawValue: styleRaw) ?? .classic }
    private var title: String {
        switch source {
        case .song(let f): return f.song.title
        case .file(let u): return u.deletingPathExtension().lastPathComponent
        }
    }

    var body: some View {
        SheetNavigation {
            Group {
                if let result {
                    preview(ChordProSong(result))
                } else if let error {
                    VStack(spacing: 14) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(.orange)
                        Text(error).multilineTextAlignment(.center)
                        Button("Try again") { start() }.buttonStyle(.borderedProminent)
                    }
                    .padding(30)
                } else {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Claude is reading “\(title)”…").font(.headline)
                        Text("This usually takes 30–90 seconds.").font(.caption).foregroundColor(.secondary)
                    }
                    .padding(30)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Convert with AI")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use this chart") { save() }.disabled(result == nil)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 760)
        #endif
        .onAppear { if result == nil && !working { start() } }
    }

    private func preview(_ song: ChordProSong) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Check it against the original before using it. You can convert again if something's off.")
                    .font(.caption).foregroundColor(.secondary)
                Text(song.title).font(ChartFonts.heading(28))
                Text([song.key.map { "Key \($0.description)" }, song.tempo.map { "\($0) BPM" }, song.time,
                      song.ccli.map { "CCLI \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline.bold())
                ForEach(song.sections) { SectionView(section: $0, size: 17, style: style) }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(style.background)
    }

    private func start() {
        error = nil; working = true
        Task {
            do {
                let raw: String
                switch source {
                case .song(let f):
                    guard let url = f.pdfURL else { throw AIError.unsupported("This") }
                    raw = try await AIChartConverter.convert(fileURL: url, hints: f.song)
                case .file(let u):
                    let scoped = u.startAccessingSecurityScopedResource()
                    defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                    raw = try await AIChartConverter.convert(fileURL: u)
                }
                await MainActor.run { result = raw; working = false }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; working = false }
            }
        }
    }

    private func save() {
        guard let result else { return }
        do {
            var existing: SongFile? = nil
            if case .song(let f) = source { existing = f }
            let id = try library.saveAIChart(result, replacing: existing)
            onSaved(id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            self.result = nil
        }
    }
}

/// Transition ideas from one song into the next (AI), cached per song pair and keys.
struct TransitionSheet: View {
    let from: RenderedSong
    let to: RenderedSong
    /// Capo on this device: shapes are shown under the sounding chords.
    let capo: Int

    @Environment(\.dismiss) private var dismiss
    @State private var ideas: [TransitionIdea] = []
    @State private var error: String?
    @State private var working = false

    var body: some View {
        SheetNavigation {
            List {
                Section {
                    HStack {
                        songLabel(from)
                        Image(systemName: "arrow.right").foregroundColor(.secondary)
                        songLabel(to)
                    }
                }
                if working {
                    HStack(spacing: 10) { ProgressView(); Text("Claude is writing transitions…") }
                } else if let error {
                    Text(error).foregroundColor(.orange)
                    Button("Try again") { load(force: true) }
                }
                ForEach(ideas) { idea in
                    Section(idea.name) {
                        Text(idea.bars).font(.system(.title3, design: .monospaced).bold()).textSelection(.enabled)
                        if capo > 0 {
                            Text("Capo \(capo): " + shapes(idea.bars))
                                .font(.system(.body, design: .monospaced)).foregroundColor(.red)
                        }
                        Text(idea.explanation).font(.callout).foregroundColor(.secondary)
                    }
                }
                if !ideas.isEmpty && !working {
                    Button("Suggest different transitions") { load(force: true) }
                }
            }
            .navigationTitle("Transition")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 560)
        #endif
        .onAppear { load(force: false) }
    }

    private func songLabel(_ r: RenderedSong) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(r.song.title).font(.headline).lineLimit(1)
            Text([r.soundingKey.map { "Key \($0.description)" }, r.tempo.map { "\($0) BPM" }].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundColor(.secondary)
        }
    }

    /// The same bars with every chord moved down by the capo (the shapes to play).
    private func shapes(_ bars: String) -> String {
        let prefersFlats = to.soundingKey?.transposed(by: -capo).prefersFlats
        return bars.split(separator: " ", omittingEmptySubsequences: false).map { tok -> String in
            let t = String(tok)
            guard let f = t.first, "ABCDEFG".contains(f) else { return t }
            return Transposer.transposeChord(t, by: -capo, preferFlats: prefersFlats ?? false) ?? t
        }.joined(separator: " ")
    }

    private func load(force: Bool) {
        let id = AITransitions.cacheID(from, to)
        if !force, let c = AITransitions.cached(id) { ideas = c; return }
        working = true; error = nil
        Task {
            do {
                let new = try await AITransitions.suggest(from: from, to: to)
                AITransitions.store(new, for: id)
                await MainActor.run { ideas = new; working = false }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; working = false }
            }
        }
    }
}

/// Settings → AI: the user's Anthropic API key (kept in the Keychain on this device).
struct AISettingsSection: View {
    @State private var keyField = ""
    @State private var hasKey = AIKey.isSet

    var body: some View {
        Section {
            if hasKey {
                HStack {
                    Label("API key saved on this device", systemImage: "checkmark.seal.fill").foregroundColor(.green)
                    Spacer()
                    Button("Remove", role: .destructive) { AIKey.remove(); hasKey = false }
                }
            } else {
                SecureField("Anthropic API key (sk-ant-…)", text: $keyField)
                Button("Save key") { AIKey.save(keyField); keyField = ""; hasKey = AIKey.isSet }
                    .disabled(keyField.trimmingCharacters(in: .whitespaces).isEmpty)
                Link("Get a key at console.anthropic.com", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
            }
        } header: {
            Text("AI (Claude)")
        } footer: {
            Text("Used to convert PDF and photo charts into transposable charts, and to suggest transitions between songs. Only the chart or the two songs involved are sent to Anthropic. Each request is billed to your Anthropic account – typically a few cents.")
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
