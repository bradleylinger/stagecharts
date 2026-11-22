import PDFKit
import AppKit
let doc = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))!
let outDir = CommandLine.arguments[2]
print("pages:", doc.pageCount)
for i in 0..<doc.pageCount {
    let page = doc.page(at: i)!
    let img = page.thumbnail(of: CGSize(width: 900, height: 1165), for: .mediaBox)
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/p\(i + 1).png"))
}
