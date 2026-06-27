import AppKit

/// FauxCam brand artwork. Resolved WITHOUT `Bundle.module`: its generated accessor `fatalError`s when the
/// resource bundle isn't where the building toolchain expects, and those expected locations differ between
/// Swift versions (6.3 looks at the `.app` root, 6.4 at `Contents/Resources`). Instead the art is loaded
/// from `Bundle.main` (the assembled `.app` carries the PNGs directly in `Contents/Resources`) and, for
/// `swift run` / previews / tests, from the SwiftPM resource bundle found via a non-fatal lookup.
public enum Brand {
    private static let logoResourceName = "faux_logo"
    private static let menuBarGlyphResourceName = "menubar"
    private static let menuBarGlyphFallbackSymbol = "camera.aperture"
    private static let accessibilityName = "FauxCam"
    private static let resourceBundleName = "FauxCam_Presentation"

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
        if let url = resourceBundle?.url(forResource: resourceName, withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        return nil
    }

    private final class BundleFinder {}

    /// The SwiftPM resource bundle, located by probing the usual directories directly — never via
    /// `Bundle.module`, so a missing/relocated bundle yields `nil` instead of a `fatalError`.
    private static let resourceBundle: Bundle? = {
        let candidateDirectories = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle(for: BundleFinder.self).resourceURL,
            Bundle(for: BundleFinder.self).bundleURL,
        ]
        for case let directory? in candidateDirectories {
            if let bundle = Bundle(url: directory.appendingPathComponent("\(resourceBundleName).bundle")) {
                return bundle
            }
        }
        return nil
    }()
}
