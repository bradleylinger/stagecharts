import PDFKit
let doc = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))!
let page = doc.page(at: 0)!
let ns = page.string! as NSString
for i in 0..<40 {
    let c = ns.substring(with: NSRange(location: i, length: 1))
    let a = page.characterBounds(at: i)
    let b = page.selection(for: NSRange(location: i, length: 1))?.bounds(for: page) ?? .zero
    print(String(format: "%2d %@  cb x%6.1f y%6.1f w%4.1f h%4.1f   sel x%6.1f y%6.1f w%4.1f h%4.1f", i, c == "\n" ? "⏎" : c, a.minX, a.minY, a.width, a.height, b.minX, b.minY, b.width, b.height))
}
