// Usage: winid [titleSubstring]  → prints "id x y w h" of the StageCharts window
import CoreGraphics
import Foundation
let want = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w["kCGWindowOwnerName"] as? String) == "StageCharts" && (w["kCGWindowLayer"] as? Int) == 0 {
    let title = w["kCGWindowName"] as? String ?? ""
    guard let b = w["kCGWindowBounds"] as? [String: Double], (b["Height"] ?? 0) > 300 else { continue }
    if let want, !title.contains(want) { continue }
    print(w["kCGWindowNumber"]!, Int(b["X"]!), Int(b["Y"]!), Int(b["Width"]!), Int(b["Height"]!), title)
}
