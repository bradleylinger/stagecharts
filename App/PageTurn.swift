import CoreGraphics
import Foundation

/// How far Page up / Page down move the chart (Settings → Display). Used by MIDI, keyboard and the toolbar.
enum PageTurn: String, CaseIterable, Identifiable {
    case scroll, page
    var id: String { rawValue }
    static let storageKey = "pageTurn"
    static var current: PageTurn { PageTurn(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .scroll }

    var title: String {
        switch self {
        case .scroll: return "Scroll most of a screen"
        case .page: return "Turn a whole page"
        }
    }

    /// Distance of one page turn in a chart view `height` tall with text size `size`.
    /// A whole page keeps about one chord + lyric line from the bottom at the top, so you don't lose your place.
    func distance(height: CGFloat, size: CGFloat) -> CGFloat {
        switch self {
        case .scroll: return height * 0.8
        case .page: return max(height * 0.6, height - size * 2.6)
        }
    }

    /// A whole page moves quickly, like turning it; scrolling glides.
    var duration: Double { self == .page ? 0.18 : 0.45 }
}
