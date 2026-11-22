import PDFKit
import AppKit
let doc = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))!
struct G { let c: Character; let r: CGRect; let font: String }
for p in 0..<doc.pageCount {
    let page = doc.page(at: p)!
    guard let attr = page.attributedString, let s = page.string else { continue }
    let ns = s as NSString
    var gl: [G] = []
    for i in 0..<ns.length {
        let ch = Character(ns.substring(with: NSRange(location: i, length: 1)))
        if ch.isWhitespace { continue }
        let r = page.characterBounds(at: i)
        let f = (i < attr.length ? attr.attribute(.font, at: i, effectiveRange: nil) as? NSFont : nil)
        let tag = f.map { ($0.fontName.contains("Bold") ? "B" : "R") + String(Int($0.pointSize.rounded())) + ($0.fontName.hasPrefix("Verdana") ? "v" : "") } ?? "?"
        gl.append(G(c: ch, r: r, font: tag))
    }
    // group into rows by baseline y
    let rows = Dictionary(grouping: gl) { Int(($0.r.minY).rounded()) }
    print("=== page \(p)")
    for y in rows.keys.sorted(by: >) {
        let g = rows[y]!.sorted { $0.r.minX < $1.r.minX }
        // build words: split on gaps > 2pt or font change
        var out = ""; var prev: G? = nil
        for x in g {
            if let pv = prev {
                if x.font != pv.font || x.r.minX - pv.r.maxX > 2.0 { out += " " }
                if x.r.minX - pv.r.maxX > 2.0 && x.font != pv.font { }
            } else { out += "@\(Int(x.r.minX)) " }
            if prev == nil || x.font != prev!.font { out += "<\(x.font)>" }
            out.append(x.c); prev = x
        }
        print(String(format: "y%4d ", y) + out)
    }
}
