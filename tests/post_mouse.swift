import CoreGraphics
import Foundation

// Test helper: pretends to be an AI agent by posting a burst of synthetic mouse-move events
// near the current pointer position (it never clicks). Prints "posted" or "no-permission".
let canPost = CGPreflightPostEventAccess()
let origin = CGEvent(source: nil)?.location ?? CGPoint(x: 400, y: 400)
for step in 0..<40 {
    let point = CGPoint(x: origin.x + CGFloat(step % 8) * 4, y: origin.y + CGFloat(step % 5) * 3)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(40_000)
}
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: origin, mouseButton: .left)?.post(tap: .cghidEventTap)
print(canPost ? "posted" : "no-permission")
