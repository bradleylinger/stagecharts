import PDFKit
let doc = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))!
let page = doc.page(at: 0)!
let ns = page.string! as NSString
let r = ns.range(of: "VERSE 2")
for i in r.location..<min(ns.length, r.location+60) {
    let c = ns.substring(with: NSRange(location: i, length: 1)); if c == "\n" || c == " " { continue }
    let b = page.selection(for: NSRange(location: i, length: 1))!.bounds(for: page)
    print(String(format: "%@ x%6.1f-%6.1f y%6.1f", c, b.minX, b.maxX, b.midY))
}
