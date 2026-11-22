// OCR experiment: render PDF page 1 and print recognized lines with positions.
import PDFKit
import Vision
import AppKit
let doc = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))!
let page = doc.page(at: 0)!
let b = page.bounds(for: .mediaBox), scale: CGFloat = 4
let w = Int(b.width * scale), h = Int(b.height * scale)
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
ctx.scaleBy(x: scale, y: scale); page.draw(with: .mediaBox, to: ctx)
let img = ctx.makeImage()!
let req = VNRecognizeTextRequest()
req.recognitionLevel = .accurate
req.usesLanguageCorrection = false
try! VNImageRequestHandler(cgImage: img).perform([req])
let obs = (req.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
for o in obs.prefix(Int(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "40")!) {
    let t = o.topCandidates(1)[0]
    print(String(format: "y%5.1f x%5.1f h%4.1f | ", o.boundingBox.midY * b.height, o.boundingBox.minX * b.width, o.boundingBox.height * b.height) + t.string)
}
