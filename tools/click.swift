// click X Y            — left click at screen point
// click scroll X Y N   — scroll wheel N lines (negative = down) at point
import CoreGraphics
import Foundation
var a = Array(CommandLine.arguments.dropFirst())
let scroll = a.first == "scroll"; if scroll { a.removeFirst() }
if a.first == "drag" {   // click drag X1 Y1 X2 Y2
    a.removeFirst()
    let p1 = CGPoint(x: Double(a[0])!, y: Double(a[1])!), p2 = CGPoint(x: Double(a[2])!, y: Double(a[3])!)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p1, mouseButton: .left)?.post(tap: .cghidEventTap)
    for i in 1...20 {
        let t = Double(i) / 20
        let p = CGPoint(x: p1.x + (p2.x - p1.x) * t, y: p1.y + (p2.y - p1.y) * t)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(15_000)
    }
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p2, mouseButton: .left)?.post(tap: .cghidEventTap)
    exit(0)
}
let p = CGPoint(x: Double(a[0])!, y: Double(a[1])!)
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(80_000)
if scroll {
    let n = Int32(a[2])!
    for _ in 0..<abs(n) {
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: n < 0 ? -3 : 3, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
        usleep(30_000)
    }
} else {
    for t in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(80_000)
    }
}
