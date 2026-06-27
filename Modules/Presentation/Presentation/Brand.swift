import AppKit

/// FauxCam brand artwork. The assembled `.app` carries the PNGs directly in `Contents/Resources`, so it
/// resolves them via `Bundle.main` and never touches the SwiftPM `Bundle.module` accessor — which
/// `fatalError`s when the resource bundle isn't where the building toolchain expects (Swift 6.3 probes the
/// `.app` root, 6.4 `Contents/Resources`). `Bundle.module` is consulted only as a lazy fallback for
/// `swift run` / previews / tests, where it resolves correctly and is never the shipped path.
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
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        return moduleImage(named: resourceName)
    }

    /// Reached only when `Bundle.main` lacks the resource — i.e. `swift run` / previews / tests, never the
    /// shipped `.app`. So `Bundle.module`'s `fatalError`-on-miss accessor is only evaluated in contexts
    /// where it resolves the bundle correctly.
    private static func moduleImage(named resourceName: String) -> NSImage? {
        Bundle.module.url(forResource: resourceName, withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }
}
