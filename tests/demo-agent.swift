import CoreGraphics
import Foundation

// CI helper for screenshots: a tiny scripted "agent" that drives the pointer with synthetic
// events. Usage: demo-agent click X Y | move X Y | key CODE | sleep SECONDS ...
var args = Array(CommandLine.arguments.dropFirst())
func mouse(_ type: CGEventType, _ point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}
func number() -> Double { Double(args.removeFirst()) ?? 0 }
while !args.isEmpty {
    switch args.removeFirst() {
    case "move":
        mouse(.mouseMoved, CGPoint(x: number(), y: number()))
    case "click":
        let point = CGPoint(x: number(), y: number())
        mouse(.mouseMoved, point); usleep(80_000)
        mouse(.leftMouseDown, point); usleep(80_000)
        mouse(.leftMouseUp, point)
    case "key":
        let code = CGKeyCode(number())
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    case "sleep":
        usleep(UInt32(number() * 1_000_000))
    default: break
    }
    usleep(50_000)
}
