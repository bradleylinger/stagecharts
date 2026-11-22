import PDFKit
import AppKit
let doc = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))!
print("pages:", doc.pageCount)
for p in 0..<doc.pageCount {
    let page = doc.page(at: p)!
    print("=== page \(p) bounds \(page.bounds(for: .mediaBox))")
    guard let attr = page.attributedString else { print("no text"); continue }
    // font runs summary
    var fonts: [String: Int] = [:]
    attr.enumerateAttribute(.font, in: NSRange(location: 0, length: attr.length)) { v, r, _ in
        if let f = v as? NSFont { fonts["\(f.fontName) \(f.pointSize)", default: 0] += r.length }
    }
    print("fonts:", fonts)
    print(attr.string.prefix(1500))
}
