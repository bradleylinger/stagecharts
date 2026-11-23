import SwiftUI
import ChordProKit

// MARK: - Sticky notes

/// A sticky note on a song: at the top of the chart (section nil) or on one section.
struct SongNote: Codable, Identifiable, Hashable {
    enum Tint: String, Codable, CaseIterable { case yellow, pink, blue, green }
    var id = UUID()
    var section: Int?          // SongSection.id, or nil for the top of the chart
    var text: String
    var tint: Tint = .yellow
}

extension SongNote.Tint {
    var color: Color {
        switch self {
        case .yellow: return Color(red: 1.0, green: 0.93, blue: 0.55)
        case .pink: return Color(red: 1.0, green: 0.78, blue: 0.84)
        case .blue: return Color(red: 0.74, green: 0.88, blue: 1.0)
        case .green: return Color(red: 0.78, green: 0.95, blue: 0.74)
        }
    }
}

/// One sticky note as drawn on the chart.
struct StickyNoteView: View {
    let note: SongNote
    let size: CGFloat
    var onTap: (() -> Void)? = nil

    var body: some View {
        Text(note.text.isEmpty ? "…" : note.text)
            .font(.custom("MarkerFelt-Wide", size: size * 0.95))
            .foregroundStyle(Color.black.opacity(0.85))
            .multilineTextAlignment(.leading)
            .padding(.horizontal, size * 0.6)
            .padding(.vertical, size * 0.4)
            .frame(maxWidth: size * 18, alignment: .leading)
            .background(note.tint.color, in: RoundedRectangle(cornerRadius: 3))
            .shadow(color: .black.opacity(0.25), radius: 3, x: 1, y: 2)
            .rotationEffect(.degrees(-1.2))
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }
            .accessibilityLabel("Note: \(note.text)")
    }
}

/// Sheet for writing/editing a note.
@available(iOS 16, macOS 13, *)
struct NoteEditor: View {
    @State var note: SongNote
    let sectionName: String?
    let onSave: (SongNote) -> Void
    let onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section(sectionName.map { "Note on \($0)" } ?? "Note at the top of the song") {
                    TextEditor(text: $note.text)
                        .font(.custom("MarkerFelt-Wide", size: 20))
                        .frame(minHeight: 120)
                        .focused($focused)
                        .scrollContentBackground(.hidden)
                        .background(note.tint.color.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    Picker("Colour", selection: $note.tint) {
                        ForEach(SongNote.Tint.allCases, id: \.self) { t in
                            Text(t.rawValue.capitalized).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                if let onDelete {
                    Section {
                        Button("Delete note", role: .destructive) { onDelete(); dismiss() }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Sticky note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(note); dismiss() }
                        .disabled(note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }
}

// MARK: - Next up

/// Bottom strip in a set: the next song, its key/capo, and its opening chords.
struct NextUpBar: View {
    let position: Int           // 1-based position of the NEXT song
    let total: Int
    let next: RenderedSong
    let size: CGFloat
    let style: ChartStyle
    var onTap: () -> Void
    var onTransition: (() -> Void)? = nil

    /// First chords of the song in order (consecutive repeats kept, like a chart's intro), max 8.
    static func openingChords(_ song: ChordProSong, limit: Int = 8) -> [String] {
        var out: [String] = []
        for section in song.sections {
            for line in section.lines {
                guard case .lyrics(let segs) = line else { continue }
                for seg in segs {
                    guard let c = seg.chord, let f = c.first, "ABCDEFG".contains(f) else { continue }
                    out.append(c)
                    if out.count == limit { return out }
                }
            }
        }
        return out
    }

    var body: some View {
        let s = size * 0.8
        HStack(spacing: 0) {
        Button(action: onTap) {
            HStack(spacing: s * 0.8) {
                Text("NEXT")
                    .font(ChartFonts.heading(s * 0.75))
                    .foregroundStyle(style.background)
                    .padding(.horizontal, s * 0.4)
                    .padding(.vertical, s * 0.15)
                    .background(style.text, in: RoundedRectangle(cornerRadius: 4))
                Text("\(position). \(next.song.title)")
                    .font(ChartFonts.heading(s))
                    .foregroundStyle(style.text)
                    .lineLimit(1)
                if let k = next.soundingKey {
                    Text("Key \(k.description)").font(ChartFonts.heading(s * 0.9)).foregroundStyle(style.secondary)
                }
                if next.capo > 0 {
                    Text("Capo \(next.capo)").font(ChartFonts.heading(s * 0.9)).foregroundStyle(.red)
                }
                if let bpm = next.tempo {
                    Text("\(bpm) BPM").font(ChartFonts.heading(s * 0.9)).foregroundStyle(style.secondary)
                }
                Divider().frame(height: s * 1.2)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: s * 0.9) {
                        ForEach(Array(Self.openingChords(next.song).enumerated()), id: \.offset) { _, c in
                            ChordLabel.text(c, size: s, color: style.chord)
                        }
                        Text("…").foregroundStyle(style.secondary)
                    }
                }
                Spacer(minLength: 0)
                Text("\(position - 1)/\(total)").font(.caption.monospacedDigit()).foregroundStyle(style.secondary)
                Image(systemName: "chevron.right").foregroundStyle(style.secondary)
            }
            .padding(.horizontal, s * 1.2)
            .padding(.vertical, s * 0.55)
            .frame(maxWidth: .infinity)
            .background(style.background)
            .overlay(alignment: .top) { Rectangle().fill(style.secondary.opacity(0.4)).frame(height: 1) }
        }
        .buttonStyle(.plain)
        .help("Go to the next song")
        if let onTransition {
            Button(action: onTransition) {
                Image(systemName: "sparkles").font(.system(size: s)).foregroundStyle(style.chord)
                    .padding(.horizontal, s * 0.9).padding(.vertical, s * 0.55)
                    .frame(maxHeight: .infinity)
                    .background(style.background)
                    .overlay(alignment: .top) { Rectangle().fill(style.secondary.opacity(0.4)).frame(height: 1) }
            }
            .buttonStyle(.plain)
            .help("Transition ideas into the next song (AI)")
        }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Format tag

/// Small tag showing what kind of chart a song is.
struct FormatTag: View {
    let song: ChordProSong

    private var label: (text: String, color: Color, help: String) {
        switch song.source {
        case .songSelectChordPro, .otherChordPro:
            return ("ChordPro", .green, "ChordPro chart")
        case .onSongSongSelect:
            return ("SongSelect", .blue, "From OnSong's SongSelect integration, converted to a transposable chart")
        case .convertedPDF where song.meta["x_source"] == "ai":
            return ("AI", .purple, "Converted with AI – check it against the original")
        case .convertedPDF:
            return ("PDF", .secondary, "Converted from a SongSelect PDF – import its ChordPro file to upgrade")
        case .pdfDocument:
            return ((song.documentKind ?? "PDF") + " only", .orange, "Original document shown as-is – the key can't be changed")
        }
    }

    var body: some View {
        let l = label
        Text(l.text)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(l.color == .secondary ? .secondary : .white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(l.color == .secondary ? Color.secondary.opacity(0.18) : l.color, in: RoundedRectangle(cornerRadius: 3))
            .help(l.help)
    }
}

// MARK: - Tempo & time signature

/// Edit BPM (with tap tempo) and time signature for a song.
struct TempoEditor: View {
    @State var tempo: Int
    let chartTempo: Int?
    @State var time: String
    let onSave: (Int, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var taps: [Date] = []

    static let signatures = ["2/4", "3/4", "4/4", "5/4", "6/4", "6/8", "7/8", "9/8", "12/8"]

    var body: some View {
        SheetNavigation {
            Form {
                Section(header: Text("Our tempo"),
                        footer: Text(chartTempo.map { "The chart says \($0) BPM. Your tempo is used everywhere in StageCharts; the chart is left unchanged." }
                                     ?? "This chart has no tempo; set the one you use.")) {
                    Stepper(value: $tempo, in: 0...300) {
                        Text(tempo > 0 ? "\(tempo) BPM" : "Not set").font(.title2.monospacedDigit())
                    }
                    if let chartTempo, chartTempo != tempo {
                        Button("Use chart tempo (\(chartTempo) BPM)") { tempo = chartTempo }
                    }
                    Button { tap() } label: {
                        Text(taps.count < 2 ? "Tap tempo (tap in time)" : "Tap tempo — \(tempo) BPM")
                            .frame(maxWidth: .infinity, minHeight: 60)
                            .font(.headline)
                    }
                    .buttonStyle(.bordered)
                }
                Section(header: Text("Time signature")) {
                    Picker("Time signature", selection: $time) {
                        ForEach(Self.signatures, id: \.self) { Text($0).tag($0) }
                        if !Self.signatures.contains(time) { Text(time).tag(time) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Tempo & time")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(tempo, time); dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 580, minHeight: 480)
        #endif
    }

    /// Average of the last few tap intervals; restarts after a 2-second pause.
    private func tap() {
        let now = Date()
        if let last = taps.last, now.timeIntervalSince(last) > 2 { taps = [] }
        taps.append(now)
        taps = Array(taps.suffix(8))
        guard taps.count >= 2 else { return }
        let intervals = zip(taps.dropFirst(), taps).map { $0.timeIntervalSince($1) }
        tempo = Int((60 / (intervals.reduce(0, +) / Double(intervals.count))).rounded())
    }
}

// MARK: - Google Drive settings

/// Sign in / status / sync now. Used in Settings and in the band viewer.
struct GoogleDriveSection: View {
    @EnvironmentObject var googleAuth: GoogleAuth
    @EnvironmentObject var drive: GoogleDriveSync
    @EnvironmentObject var library: SongLibrary
    @State private var signInError: String?

    var body: some View {
        Section(header: Text("Google Drive"),
                footer: Text("Keeps your library (songs, original PDFs, set lists, notes, keys) in “StageCharts Library” in your Google Drive and syncs it with every device signed in to the same account. StageCharts can only see files it created.")) {
            if !googleAuth.isConfigured {
                Text("Google sign-in isn't set up in this build yet.").foregroundColor(.secondary)
            } else if !googleAuth.isSignedIn {
                Button("Sign in with Google") {
                    Task {
                        do { try await googleAuth.signIn(); signInError = nil; await drive.syncNow() }
                        catch { signInError = error.localizedDescription }
                    }
                }
            } else {
                HStack {
                    Text(googleAuth.email ?? "Signed in")
                    Spacer()
                    Text(drive.isSyncing ? "Syncing…" : drive.status).foregroundColor(.secondary).font(.callout)
                }
                if let last = drive.lastSync {
                    Text("Last synced \(last.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundColor(.secondary)
                }
                Button("Sync now") { Task { await drive.syncNow() } }.disabled(drive.isSyncing)
                if library.usesCustomFolder {
                    Button("Keep the library on this device (recommended with Google sign-in)") { library.moveToDeviceStorage() }
                }
                Button("Sign out of Google", role: .destructive) { googleAuth.signOut() }
            }
            if let e = signInError ?? drive.lastError { Text(e).foregroundColor(.red).font(.caption) }
        }
    }
}
