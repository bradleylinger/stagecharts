// Renders the StageCharts app icon (1024×1024 PNG) with SwiftUI.
// Usage: icon <out.png> [variant]
import SwiftUI
import AppKit

struct Icon: View {
    var body: some View {
        ZStack {
            // Stage: deep night-blue to black
            LinearGradient(colors: [Color(red: 0.07, green: 0.09, blue: 0.20), Color(red: 0.01, green: 0.01, blue: 0.04)],
                           startPoint: .top, endPoint: .bottom)
            // Spotlight beam from above
            Path { p in
                p.move(to: CGPoint(x: 430, y: -40)); p.addLine(to: CGPoint(x: 594, y: -40))
                p.addLine(to: CGPoint(x: 900, y: 1024)); p.addLine(to: CGPoint(x: 124, y: 1024)); p.closeSubpath()
            }
            .fill(LinearGradient(colors: [Color(red: 1, green: 0.78, blue: 0.42).opacity(0.55), .clear],
                                 startPoint: .top, endPoint: .bottom))
            .blur(radius: 18)
            // Warm pool of light on the floor
            Ellipse()
                .fill(RadialGradient(colors: [Color(red: 1, green: 0.72, blue: 0.35).opacity(0.55), .clear],
                                     center: .center, startRadius: 0, endRadius: 360))
                .frame(width: 820, height: 260)
                .offset(y: 380)
            // A second page behind: the set list
            RoundedRectangle(cornerRadius: 34)
                .fill(Color(white: 0.80))
                .frame(width: 560, height: 600)
                .shadow(color: .black.opacity(0.45), radius: 30, y: 18)
                .rotationEffect(.degrees(7))
                .offset(x: 46, y: 22)
            // The chart page
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 34)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.55), radius: 40, y: 24)
                VStack(alignment: .leading, spacing: 0) {
                    // Chord, SongSelect style: root + raised extension (accent)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("G").font(.system(size: 260, weight: .black)).foregroundStyle(.black)
                        Text("2").font(.system(size: 140, weight: .black)).baselineOffset(118)
                            .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.16))
                    }
                    .padding(.leading, 46)
                    .padding(.top, 4)
                    // Lyric lines
                    VStack(alignment: .leading, spacing: 36) {
                        Capsule().frame(width: 440, height: 32)
                        Capsule().frame(width: 340, height: 32)
                        Capsule().frame(width: 400, height: 32)
                        Capsule().frame(width: 260, height: 32)
                    }
                    .foregroundStyle(Color(white: 0.70))
                    .padding(.leading, 54)
                    .padding(.top, -2)
                }
            }
            .frame(width: 560, height: 600)
            .rotationEffect(.degrees(-5))
            .offset(x: -18, y: 34)
        }
        .frame(width: 1024, height: 1024)
        .clipped()
    }
}

let out = CommandLine.arguments[1]
MainActor.assumeIsolated {
    let r = ImageRenderer(content: Icon())
    r.scale = 1
    guard let cg = r.cgImage else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: cg)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print("wrote \(out)")
}
