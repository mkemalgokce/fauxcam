import Testing
import CoreImage
import Kernel
import Capture

/// A 100x100 image: left half red, right half blue — so panning/zooming changes the rendered pixels.
private func splitImage() -> CIImage {
    let left = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 50, height: 100))
    let right = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 50, y: 0, width: 50, height: 100))
    return right.composited(over: left)
}

private extension Frame {
    func bytes() -> [UInt8] { buffer.withUnsafeBytes { Array($0) } }
}

struct CoreImageCompositorTests {
    @Test func composesToExactDemandDimensions() async {
        let compositor = CoreImageCompositor(pool: TestPool())
        let demand = Demand(position: .back, requestedWidth: 8, requestedHeight: 8)
        let frame = await compositor.compose(SourceImage(image: solid(CIColor(red: 1, green: 0, blue: 0))),
                                             into: demand, crop: .identity)
        #expect(frame.width == 8)
        #expect(frame.height == 8)
        #expect(frame.bytesPerRow == 8 * 4)
        #expect(frame.isWellFormed)
    }

    @Test func aspectMatchedImageFillsWithItsColor() async {
        let compositor = CoreImageCompositor(pool: TestPool())   // 8x8 red into 8x8 -> fills, no letterbox
        let frame = await compositor.compose(SourceImage(image: solid(CIColor(red: 1, green: 0, blue: 0))),
                                             into: Demand(position: .back, requestedWidth: 8, requestedHeight: 8),
                                             crop: .identity)
        let (b, g, r, a) = frame.pixel(x: 4, y: 4)
        #expect(r > 200); #expect(g < 60); #expect(b < 60); #expect(a == 255)
    }

    @Test func zoomedOutSquareIntoWideFrameLetterboxesBlack() async {
        let compositor = CoreImageCompositor(pool: TestPool())   // 8x8 into 32x8 -> black side columns
        let frame = await compositor.compose(SourceImage(image: solid(CIColor(red: 1, green: 1, blue: 1))),
                                             into: Demand(position: .back, requestedWidth: 32, requestedHeight: 8),
                                             crop: .identity)
        let corner = frame.pixel(x: 0, y: 4)         // far-left column is letterbox
        #expect(corner.0 < 20 && corner.1 < 20 && corner.2 < 20)
    }

    @Test func nonIdentityCropRendersDifferentPixelsThanIdentity() async {
        let compositor = CoreImageCompositor(pool: TestPool())
        let demand = Demand(position: .back, requestedWidth: 32, requestedHeight: 32)
        let image = splitImage()
        let identity = await compositor.compose(SourceImage(image: image), into: demand, crop: .identity)
        let panned = await compositor.compose(SourceImage(image: image), into: demand,
                                              crop: CropRegion(centerX: 0.15, zoom: 3))
        #expect(identity.isWellFormed && panned.isWellFormed)
        #expect(identity.bytes() != panned.bytes())
    }

    @Test func writesBGRAChannelOrderAndPropagatesTimestamp() async {
        let compositor = CoreImageCompositor(pool: TestPool())
        let source = SourceImage(image: solid(CIColor(red: 30.0 / 255, green: 20.0 / 255, blue: 10.0 / 255)),
                                 presentationTimeNanoseconds: 12_345)
        let frame = await compositor.compose(source, into: Demand(position: .back, requestedWidth: 8, requestedHeight: 8),
                                             crop: .identity)
        let (blue, green, red, alpha) = frame.pixel(x: 4, y: 4)
        #expect(blue < green && green < red)        // distinct channels prove B, G, R byte order
        #expect(blue < 128 && green < 128 && red < 128)
        #expect(alpha == 255)
        #expect(frame.presentationTimeNanoseconds == 12_345)
    }
}
