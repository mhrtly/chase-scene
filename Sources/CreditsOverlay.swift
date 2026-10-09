import AppKit
import CoreImage
import CoreText
import QuartzCore

enum CreditsPainter {
    private static let filters = CIContext(options: [.cacheIntermediates: false])
    private static var registered: Set<String> = []

    static func font(preferences: Preferences, size: CGFloat) -> NSFont {
        let url = preferences.creditsFontPath.map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.url(forResource: "Chewy-Regular", withExtension: "ttf")
        if let url, !registered.contains(url.path) {
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) { registered.insert(url.path) }
        }
        return NSFont(name: preferences.creditsFontName ?? "Chewy-Regular", size: size)
            ?? NSFont(name: "MarkerFelt-Wide", size: size) ?? .boldSystemFont(ofSize: size)
    }

    static func sizes(preferences: Preferences, width: CGFloat) -> (name: CGFloat, role: CGFloat, activity: CGFloat, height: CGFloat) {
        let corner = preferences.creditsLayout == "corner"
        let name: CGFloat = corner ? 57 : max(112, min(180, width * 0.074))
        let role: CGFloat = corner ? 30 : max(42, min(64, width * 0.028))
        let activity: CGFloat = corner ? 18 : 27
        return (name, role, activity, name * 1.24 + role * 1.28 + activity * 1.2 + (corner ? 32 : 46))
    }

    static func render(deck: CreditDeck, preferences: Preferences, width: CGFloat) -> (CGImage, CGFloat)? {
        let style = sizes(preferences: preferences, width: width)
        let height = style.height * CGFloat(deck.credits.count)
        // Keep the television softness, with enough resolution for large, solid white glyphs.
        let scale = min(0.9, 1000 / width)
        let pixelWidth = Int((width * scale).rounded())
        let pixelHeight = Int((height * scale).rounded())
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.scaleBy(x: scale, y: scale)
        for (index, credit) in deck.credits.enumerated() {
            let top = height - 16 - CGFloat(index) * style.height
            draw("Now: " + deck.task, y: top - style.activity * 1.15, size: style.activity,
                 width: width, preferences: preferences, caps: false)
            draw(credit.role, y: top - style.activity * 1.25 - style.role * 1.22, size: style.role,
                 width: width, preferences: preferences, caps: false)
            draw(credit.name.uppercased(), y: top - style.activity * 1.25 - style.role * 1.3 - style.name * 1.22,
                 size: style.name, width: width, preferences: preferences, caps: true)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let original = bitmap.cgImage else { return nil }
        let signal = CIImage(cgImage: original)
        let softened = signal.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.72])
            .cropped(to: signal.extent)
        guard let blurred = filters.createCGImage(softened, from: signal.extent),
              let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                  bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(blurred, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        if let data = context.data?.assumingMemoryBound(to: UInt8.self) {
            var random: UInt32 = 1986
            for y in 0..<pixelHeight {
                for x in 0..<pixelWidth {
                    random = random &* 1664525 &+ 1013904223
                    let variation = CGFloat((random >> 24) & 15) / 1600
                    let gain: CGFloat = (y % 2 == 0 ? 1 : 0.987) - variation
                    let offset = (y * pixelWidth + x) * 4
                    for c in 0..<4 { data[offset + c] = UInt8(CGFloat(data[offset + c]) * gain) }
                }
            }
        }
        return context.makeImage().map { ($0, height) }
    }

    private static func draw(_ text: String, y: CGFloat, size: CGFloat, width: CGFloat,
                             preferences: Preferences, caps: Bool) {
        var selected = font(preferences: preferences, size: size)
        var attributes: [NSAttributedString.Key: Any] = [.font: selected, .kern: caps ? 1.1 : 0.2,
            .foregroundColor: NSColor.white, .strokeColor: NSColor.black, .strokeWidth: -6.0]
        var line = NSAttributedString(string: text, attributes: attributes)
        let maximum = width * 0.90
        if line.size().width > maximum {
            selected = font(preferences: preferences, size: size * maximum / line.size().width)
            attributes[.font] = selected
            line = NSAttributedString(string: text, attributes: attributes)
        }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.92)
        shadow.shadowBlurRadius = 5.5
        shadow.shadowOffset = NSSize(width: 4.5, height: -5)
        shadow.set()
        line.draw(at: NSPoint(x: (width - line.size().width) / 2, y: y))
        NSShadow().set()
        // A white stroke thickens the actual letters over their dark outline and shadow.
        attributes[.strokeColor] = NSColor.white
        attributes[.strokeWidth] = -2.8
        NSAttributedString(string: text, attributes: attributes)
            .draw(at: NSPoint(x: (width - line.size().width) / 2, y: y))
    }

    static func writePreview(to url: URL, deck: CreditDeck, preferences: Preferences) throws {
        let width: CGFloat = 1100
        let sample = CreditDeck(task: deck.task, credits: Array(deck.credits.prefix(3)))
        let height = sizes(preferences: preferences, width: width).height * CGFloat(sample.credits.count) + 48
        guard let (strip, stripHeight) = render(deck: sample, preferences: preferences, width: width),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw ControlError.invalid("Could not render credits preview.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSGradient(starting: NSColor(calibratedRed: 0.29, green: 0.34, blue: 0.20, alpha: 1),
                   ending: NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.09, alpha: 1))?
            .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)
        graphics.cgContext.interpolationQuality = .medium
        graphics.cgContext.draw(strip, in: CGRect(x: 0, y: height - stripHeight - 20, width: width, height: stripHeight))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ControlError.invalid("Could not encode preview.") }
        try png.write(to: url, options: .atomic)
    }
}

private final class CreditsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class RowCompletion: NSObject, CAAnimationDelegate {
    let finished: () -> Void
    init(_ finished: @escaping () -> Void) { self.finished = finished }
    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) { if flag { finished() } }
}

final class CreditRollView: NSView {
    let rollIdentifier = UUID().uuidString
    let stream = CreditStream()
    private var rows: [UUID: CALayer] = [:]
    private var rowTimer: Timer?
    private var preferences = Preferences()
    private var renderKey: String?
    private var spawnY: CGFloat = 0
    private var speed: CGFloat = 0
    private(set) var lastName = ""
    private(set) var lastTask = ""
    var isScrolling: Bool { rows.values.contains { $0.animation(forKey: "rise") != nil } }
    var rowCount: Int { rows.count }

    func configure(deck: CreditDeck, preferences: Preferences) {
        stream.update(deck)
        setAccessibilityLabel("Fictional rolling credits for \(deck.task)")
        let appearance = "\(bounds.width):\(bounds.height):\(preferences.creditsLayout):\(preferences.creditsFontName ?? "Chewy-Regular"):\(preferences.creditsFontPath ?? "")"
        guard renderKey != appearance || rowTimer == nil else { return }
        stop()
        self.preferences = preferences
        renderKey = appearance
        wantsLayer = true
        layer?.masksToBounds = true
        let fade = CAGradientLayer()
        fade.frame = bounds
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fade.locations = [0, 0.05, 0.95, 1]
        layer?.mask = fade
        let height = CreditsPainter.sizes(preferences: preferences, width: bounds.width).height
        speed = preferences.creditsLayout == "corner" ? 49 : 88
        let count = Int(ceil(bounds.height / height)) + 1
        spawnY = bounds.height - height / 2 - CGFloat(count - 1) * height
        for index in 0..<count { addRow(y: bounds.height - height / 2 - CGFloat(index) * height) }
        // One callback per credit, never per animation frame. There is no whole-reel loop.
        let timer = Timer(timeInterval: Double(height / speed), repeats: true) { [weak self] _ in
            guard let self else { return }
            self.addRow(y: self.spawnY)
        }
        RunLoop.main.add(timer, forMode: .common)
        rowTimer = timer
    }

    private func addRow(y: CGFloat) {
        let deck = stream.next()
        guard let (image, height) = CreditsPainter.render(deck: deck, preferences: preferences, width: bounds.width) else { return }
        let row = CALayer()
        row.contents = image
        row.contentsGravity = .resize
        row.magnificationFilter = .linear
        row.minificationFilter = .linear
        row.frame = CGRect(x: 0, y: y - height / 2, width: bounds.width, height: height)
        layer?.addSublayer(row)
        let id = UUID()
        rows[id] = row
        lastName = deck.credits[0].name
        lastTask = deck.task
        let endY = bounds.height + height / 2
        let rise = CABasicAnimation(keyPath: "position.y")
        rise.fromValue = y
        rise.toValue = endY
        rise.duration = Double((endY - y) / speed)
        rise.timingFunction = CAMediaTimingFunction(name: .linear)
        rise.delegate = RowCompletion { [weak self] in self?.rows.removeValue(forKey: id)?.removeFromSuperlayer() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        row.position.y = endY
        row.add(rise, forKey: "rise")
        CATransaction.commit()
    }

    func stop() {
        rowTimer?.invalidate()
        rowTimer = nil
        for row in rows.values { row.removeAllAnimations(); row.removeFromSuperlayer() }
        rows.removeAll()
    }
    deinit { rowTimer?.invalidate() }
}

final class CreditsOverlay {
    private var panel: CreditsPanel?
    private var view: CreditRollView?
    private var previewTimer: Timer?
    var previewing: Bool { previewTimer != nil }
    var isVisible: Bool { panel?.isVisible ?? false }
    var isScrolling: Bool { isVisible && view?.isScrolling == true }
    var isClickThrough: Bool { panel?.ignoresMouseEvents == true && panel?.canBecomeKey == false }

    var streamStatus: [String: Any] {
        ["credits_scroll_id": view?.rollIdentifier ?? "", "credits_rows_emitted": view?.stream.emitted ?? 0,
         "credits_active_rows": view?.rowCount ?? 0, "credits_last_name": view?.lastName ?? "",
         "credits_last_task": view?.lastTask ?? ""]
    }

    func update(state: ControlState) {
        if previewing { return }
        if state.shouldShowCredits { show(deck: state.currentCredits, preferences: state.preferences) }
        else { hide() }
    }

    func preview(preferences: Preferences, deck: CreditDeck, finished: @escaping () -> Void) {
        previewTimer?.invalidate()
        show(deck: deck, preferences: preferences)
        previewTimer = Timer(timeInterval: 16, repeats: false) { [weak self] _ in
            self?.previewTimer = nil
            self?.hide()
            finished()
        }
        RunLoop.main.add(previewTimer!, forMode: .common)
    }

    func show(deck: CreditDeck, preferences: Preferences) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let frame: NSRect
        if preferences.creditsLayout == "corner" {
            let width = min(490, visible.width * 0.43)
            let height = min(640, visible.height * 0.82)
            frame = NSRect(x: visible.maxX - width - 16, y: visible.minY + 16, width: width, height: height)
        } else { frame = visible }
        if panel == nil {
            let window = CreditsPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.hidesOnDeactivate = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
            window.isReleasedWhenClosed = false
            window.title = "Fictional desktop-control credits"
            let content = CreditRollView(frame: NSRect(origin: .zero, size: frame.size))
            window.contentView = content
            panel = window
            view = content
        }
        panel?.setFrame(frame, display: false)
        view?.configure(deck: deck, preferences: preferences)
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        // Release textures and animations while idle; no per-frame CPU work or idle timer.
        view?.stop()
        panel?.contentView = nil
        panel?.close()
        panel = nil
        view = nil
    }

    func stopPreview() {
        previewTimer?.invalidate()
        previewTimer = nil
        hide()
    }
}
