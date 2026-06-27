import Testing
import AppKit
@testable import Presentation

@MainActor
struct BrandTests {
    @Test func logoResolvesFromTheModuleBundle() {
        let logo = Brand.logo
        #expect(logo != nil)
        #expect((logo?.size.width ?? 0) > 0)
    }

    @Test func menuBarGlyphIsATemplateScaledToTheRequestedHeight() {
        let glyph = Brand.menuBarGlyph(height: 18)
        #expect(glyph.isTemplate)
        #expect(abs(glyph.size.height - 18) < 0.5)
        #expect(glyph.size.width > 0)
    }
}
