import PDFKit
let doc = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))!
let page = doc.page(at: 0)!
let sel = page.selection(for: page.bounds(for: .mediaBox))!
for line in sel.selectionsByLine().prefix(70) {
    let b = line.bounds(for: page)
    print(String(format: "x%5.1f y%5.1f w%5.1f h%4.1f | ", b.minX, b.minY, b.width, b.height) + (line.string ?? ""))
}
