import PDFKit
let doc = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))!
let page = doc.page(at: 0)!
let ns = page.string! as NSString
let r = ns.range(of: "foundation")
for i in (r.location-8)..<(r.location+1) {
    let c = ns.substring(with: NSRange(location: i, length: 1))
    let b = page.selection(for: NSRange(location: i, length: 1))?.bounds(for: page) ?? .zero
    print(i, c.unicodeScalars.map { String(format: "U+%04X", $0.value) }, String(format: "x%.1f w%.1f h%.1f", b.minX, b.width, b.height))
}
