import Testing
import CoreImage
import Kernel
import Capture

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
}
