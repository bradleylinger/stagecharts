// Renders the StageCharts app icon (1024×1024 PNG) with SwiftUI.
// Flat style: near-black field, one coral circle, heavy rounded "SC" monogram.
// Usage: icon <out.png> [mac]   (mac: rounded-square shape with the standard macOS margin)
import SwiftUI
import AppKit

let ink = Color(red: 0.09, green: 0.08, blue: 0.08)
let coral = Color(red: 1.0, green: 0.36, blue: 0.30)

struct Mark: View {
    var body: some View {
        ZStack {
            ink
            Circle().fill(coral).frame(width: 800, height: 800)
            HStack(alignment: .firstTextBaseline, spacing: -18) {
                Text("S").font(.system(size: 400, weight: .black, design: .rounded))
                Text("C").font(.system(size: 400, weight: .black, design: .rounded))
            }
            .foregroundColor(ink)
            .offset(y: 6)
        }
        .frame(width: 1024, height: 1024)
    }
}

struct MacIcon: View {          // macOS: 824-pt rounded square inside the 1024 canvas, soft shadow
    var body: some View {
        Mark()
            .scaleEffect(824.0 / 1024.0)
            .frame(width: 824, height: 824)
            .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 8)
            .frame(width: 1024, height: 1024)
    }
}

let args = CommandLine.arguments
let out = args[1]
MainActor.assumeIsolated {
    let r = args.count > 2 && args[2] == "mac" ? ImageRenderer(content: AnyView(MacIcon())) : ImageRenderer(content: AnyView(Mark()))
    r.scale = 1
    guard let cg = r.cgImage else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: cg)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print("wrote \(out)")
}
