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

    static func render(deck: CreditDeck, preferences: Preferences, width: CGFloat) -> (CGImage, CGFloat)? {
        let corner = preferences.creditsLayout == "corner"
        let nameSize: CGFloat = corner ? 38 : 78
        let roleSize: CGFloat = corner ? 23 : 37
        let cardHeight: CGFloat = corner ? 122 : 198
        let height = cardHeight * CGFloat(deck.credits.count) + 50
        // Rasterize below Retina resolution, then soften the signal. Fuzz comes from the
        // lettering itself, rather than a sharp modern font with an enormous outer glow.
        let scale = min(0.85, 720 / width)
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
            let top = height - 24 - CGFloat(index) * cardHeight
            draw(credit.role, y: top - roleSize * 1.2, size: roleSize, width: width, preferences: preferences, caps: false)
            draw(credit.name.uppercased(), y: top - roleSize * 1.5 - nameSize * 1.22,
                 size: nameSize, width: width, preferences: preferences, caps: true)
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
                    let variation = CGFloat((random >> 24) & 15) / 700
                    let gain: CGFloat = (y % 2 == 0 ? 0.978 : 0.947) - variation
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
            .foregroundColor: NSColor(calibratedRed: 0.94, green: 0.95, blue: 0.90, alpha: 1)]
        var line = NSAttributedString(string: text, attributes: attributes)
        let maximum = width * 0.90
        if line.size().width > maximum {
            selected = font(preferences: preferences, size: size * maximum / line.size().width)
            attributes[.font] = selected
            line = NSAttributedString(string: text, attributes: attributes)
        }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.46)
        shadow.shadowBlurRadius = 2.8
        shadow.shadowOffset = NSSize(width: 1.2, height: -1.5)
        shadow.set()
        line.draw(at: NSPoint(x: (width - line.size().width) / 2, y: y))
        NSShadow().set()
    }

    static func writePreview(to url: URL, deck: CreditDeck, preferences: Preferences) throws {
        let width: CGFloat = 1100
        let height: CGFloat = 850
        guard let (strip, stripHeight) = render(deck: deck, preferences: preferences, width: width),
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

final class CreditRollView: NSView {
    var strip: CALayer?
    var deck: CreditDeck?
    var renderKey: String?

    func configure(deck: CreditDeck, preferences: Preferences) {
        let appearance = "\(bounds.width):\(bounds.height):\(preferences.creditsLayout):\(preferences.creditsFontName ?? "Chewy-Regular"):\(preferences.creditsFontPath ?? "")"
        guard self.deck != deck || self.renderKey != appearance else { return }
        self.deck = deck
        self.renderKey = appearance
        wantsLayer = true
        layer?.masksToBounds = true
        strip?.removeFromSuperlayer()
        guard let (image, height) = CreditsPainter.render(deck: deck, preferences: preferences, width: bounds.width) else { return }
        let rolling = CALayer()
        rolling.contents = image
        rolling.contentsGravity = .resize
        rolling.magnificationFilter = .linear
        rolling.minificationFilter = .linear
        rolling.frame = CGRect(x: 0, y: -height, width: bounds.width, height: height)
        layer?.addSublayer(rolling)
        let fade = CAGradientLayer()
        fade.frame = bounds
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fade.locations = [0, 0.08, 0.91, 1]
        layer?.mask = fade
        let rise = CABasicAnimation(keyPath: "position.y")
        rise.fromValue = -height / 2
        rise.toValue = bounds.height + height / 2
        rise.duration = Double((height + bounds.height) / (preferences.creditsLayout == "corner" ? 32 : 58))
        rise.timingFunction = CAMediaTimingFunction(name: .linear)
        rise.repeatCount = .infinity
        rolling.add(rise, forKey: "roll")
        strip = rolling
        setAccessibilityLabel("Fictional rolling credits for \(deck.task)")
    }
}

final class CreditsOverlay {
    private var panel: CreditsPanel?
    private var view: CreditRollView?
    private var previewTimer: Timer?
    var previewing: Bool { previewTimer != nil }
    var isVisible: Bool { panel?.isVisible ?? false }
    var isScrolling: Bool { isVisible && view?.strip?.animation(forKey: "roll") != nil }
    var isClickThrough: Bool { panel?.ignoresMouseEvents == true && panel?.canBecomeKey == false }

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
        view?.strip?.removeAllAnimations()
        view?.strip?.removeFromSuperlayer()
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
