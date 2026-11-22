import SwiftUI
import ChordProKit

/// CCLI usage report, built from the set lists: every song in a set dated within the period counts
/// as one use. Export as CSV for the CCLI copy report.
struct CCLIUsage: Identifiable {
    let id: String              // song file id
    let title: String
    let ccli: String?
    let authors: String
    var dates: [Date]
    var uses: Int { dates.count }
}

extension SongLibrary {
    func ccliUsage(from: Date, to: Date) -> (services: Int, songs: [CCLIUsage]) {
        let sets = setLists.filter { $0.date >= from && $0.date <= to && $0.date <= Date() }
        var bySong: [String: CCLIUsage] = [:]
        for set in sets {
            for item in set.items {
                guard let f = song(id: item.songID) else { continue }
                bySong[f.id, default: CCLIUsage(id: f.id, title: f.song.title, ccli: f.song.ccli,
                                                 authors: f.song.artists.joined(separator: " | "), dates: [])]
                    .dates.append(set.date)
            }
        }
        let songs = bySong.values.sorted { ($0.uses, $1.title) > ($1.uses, $0.title) }
        return (sets.count, songs)
    }
}

@available(iOS 16.0, *)
struct CCLIReportView: View {
    @EnvironmentObject var library: SongLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var from = Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? Date()
    @State private var to = Date()

    var body: some View {
        let report = library.ccliUsage(from: Calendar.current.startOfDay(for: from),
                                       to: Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: to) ?? to)
        let missing = report.songs.filter { $0.ccli == nil }.count
        SheetNavigation {
            List {
                Section {
                    DatePicker("From", selection: $from, displayedComponents: .date)
                    DatePicker("To", selection: $to, displayedComponents: .date)
                    HStack {
                        Button("Last 6 months") { setRange(months: 6) }
                        Button("Last 12 months") { setRange(months: 12) }
                    }
                    .buttonStyle(.bordered)
                } footer: {
                    Text("Every song in a set list dated in this period counts as one use. Sets dated in the future aren't counted.")
                }
                Section {
                    Text("\(report.services) services · \(report.songs.count) songs · \(report.songs.reduce(0) { $0 + $1.uses }) uses")
                        .font(.headline)
                    if missing > 0 {
                        Text("\(missing) song\(missing == 1 ? " has" : "s have") no CCLI number – look these up on SongSelect when reporting.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section("Songs") {
                    ForEach(report.songs) { s in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).font(.body.weight(.semibold))
                                Text(s.ccli.map { "CCLI \($0)" } ?? "No CCLI number")
                                    .font(.caption)
                                    .foregroundStyle(s.ccli == nil ? Color.orange : Color.secondary)
                            }
                            Spacer()
                            Text("\(s.uses)×").font(.body.monospacedDigit())
                        }
                        .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("CCLI Usage")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if let url = csvFile(report.songs) {
                        ShareLink(item: url) { Label("Export CSV", systemImage: "square.and.arrow.up") }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 640)
        #endif
    }

    private func setRange(months: Int) {
        to = Date()
        from = Calendar.current.date(byAdding: .month, value: -months, to: to) ?? to
    }

    private func csvFile(_ songs: [CCLIUsage]) -> URL? {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["Title,CCLI Number,Authors,Times Used,Dates"]
        for s in songs {
            lines.append([q(s.title), q(s.ccli ?? ""), q(s.authors), String(s.uses),
                          q(s.dates.sorted().map { df.string(from: $0) }.joined(separator: " "))].joined(separator: ","))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CCLI usage \(df.string(from: from)) to \(df.string(from: to)).csv")
        return (try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }
}
