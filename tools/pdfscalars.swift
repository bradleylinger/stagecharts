import PDFKit
let doc = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))!
let s = doc.page(at: 0)!.string!
for u in s.unicodeScalars where u.value > 126 || u.value < 9 { print(String(format: "U+%04X", u.value)) }
