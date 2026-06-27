import AppKit

/// FauxCam brand artwork, shipped as resources of this module and resolved through `Bundle.module`, so the
/// images load identically whether the app runs from a built bundle, `swift run`, or the test runner —
/// unlike `Bundle.main`, which only carries them inside the assembled `.app`.
public enum Brand {
    private static let logoResourceName = "faux_logo"
    private static let menuBarGlyphResourceName = "menubar"
    private static let menuBarGlyphFallbackSymbol = "camera.aperture"
    private static let accessibilityName = "FauxCam"

    /// The full-colour fox + lens mark used as the in-app logo (settings header, onboarding).
    public static var logo: NSImage? { image(named: logoResourceName) }

    /// The monochrome menu-bar glyph as a template image scaled to `height`, with an SF Symbol fallback so
    /// the menu-bar label always renders even if the resource is somehow missing.
    public static func menuBarGlyph(height: CGFloat) -> NSImage {
        if let glyph = image(named: menuBarGlyphResourceName), glyph.size.height > 0 {
            let aspectRatio = glyph.size.width / glyph.size.height
            glyph.size = NSSize(width: height * aspectRatio, height: height)
            glyph.isTemplate = true
            glyph.accessibilityDescription = accessibilityName
            return glyph
        }
        let fallback = NSImage(systemSymbolName: menuBarGlyphFallbackSymbol, accessibilityDescription: accessibilityName) ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }

    private static func image(named resourceName: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}
