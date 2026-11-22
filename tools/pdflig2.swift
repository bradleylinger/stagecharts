import PDFKit
let doc = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))!
let page = doc.page(at: 0)!
let ns = page.string! as NSString
var r = ns.range(of: "rm")
while r.location != NSNotFound {
  let ctx = ns.substring(with: NSRange(location: max(0, r.location-4), length: 8)).unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ")
  let b = page.selection(for: NSRange(location: r.location-1, length: 1))?.bounds(for: page) ?? .zero
  print(r.location, ctx, String(format: "prev x%.1f w%.1f h%.1f", b.minX, b.width, b.height))
  r = ns.range(of: "rm", options: [], range: NSRange(location: r.location+2, length: ns.length - r.location - 2))
}
