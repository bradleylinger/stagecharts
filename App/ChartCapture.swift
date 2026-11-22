#if os(iOS)
import SwiftUI
import VisionKit
import PDFKit

/// Scans a paper chart with the camera (edge detection, straightening, several pages) and hands back a PDF.
struct ChartScanner: UIViewControllerRepresentable {
    var onDone: (URL?) -> Void

    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onDone: (URL?) -> Void
        init(onDone: @escaping (URL?) -> Void) { self.onDone = onDone }

        func documentCameraViewController(_ c: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onDone(ChartCapture.pdf(from: (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }))
        }
        func documentCameraViewControllerDidCancel(_ c: VNDocumentCameraViewController) { onDone(nil) }
        func documentCameraViewController(_ c: VNDocumentCameraViewController, didFailWithError error: Error) { onDone(nil) }
    }
}

enum ChartCapture {
    /// Pages → a compact PDF in the temporary folder (images scaled down so the upload stays small).
    static func pdf(from images: [UIImage], name: String = "Scanned chart") -> URL? {
        let doc = PDFDocument()
        for img in images {
            guard let small = downscaled(img), let page = PDFPage(image: small) else { continue }
            doc.insert(page, at: doc.pageCount)
        }
        guard doc.pageCount > 0 else { return nil }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HHmmss"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name) \(df.string(from: Date())).pdf")
        return doc.write(to: url) ? url : nil
    }

    static func downscaled(_ img: UIImage, maxSide: CGFloat = 2200) -> UIImage? {
        let s = img.size, scale = min(1, maxSide / max(s.width, s.height))
        let size = CGSize(width: s.width * scale, height: s.height * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.75).flatMap { UIImage(data: $0) }
    }
}
#endif
