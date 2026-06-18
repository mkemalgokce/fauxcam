import Testing
import Foundation
@testable import FauxAdapters

private func fakePNG(width: UInt32, height: UInt32) -> Data {
    var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,  // signature
                          0x00, 0x00, 0x00, 0x0D,                          // IHDR length
                          0x49, 0x48, 0x44, 0x52]                          // "IHDR"
    for shift in [24, 16, 8, 0] { bytes.append(UInt8((width >> shift) & 0xFF)) }
    for shift in [24, 16, 8, 0] { bytes.append(UInt8((height >> shift) & 0xFF)) }
    return Data(bytes)
}

@Test func pngHeaderReadsPixelDimensions() {
    let dims = PNGHeader.pixelDimensions(fakePNG(width: 1206, height: 2622))
    #expect(dims?.width == 1206 && dims?.height == 2622)
}

@Test func pngHeaderRejectsNonPNG() {
    #expect(PNGHeader.pixelDimensions(Data([0, 1, 2, 3])) == nil)
    #expect(PNGHeader.pixelDimensions(Data()) == nil)
}

@Test func aspectProviderComputesRatioFromScreenshot() {
    let provider = SimctlScreenshotAspectProvider(captureScreenshot: { _ in fakePNG(width: 1206, height: 2622) })
    let aspect = provider.aspect(forDeviceWithUDID: "U1")
    #expect(aspect != nil)
    #expect(abs(aspect! - 1206.0 / 2622.0) < 0.0001)  // portrait phone
}

@Test func aspectProviderReturnsNilWhenScreenshotFails() {
    let provider = SimctlScreenshotAspectProvider(captureScreenshot: { _ in nil })
    #expect(provider.aspect(forDeviceWithUDID: "U1") == nil)
    #expect(provider.aspect(forDeviceWithUDID: "") == nil)
}

@Test func aspectProviderHandlesIpadAndLandscape() {
    let ipad = SimctlScreenshotAspectProvider(captureScreenshot: { _ in fakePNG(width: 1640, height: 2360) })
    #expect(abs(ipad.aspect(forDeviceWithUDID: "U")! - 1640.0 / 2360.0) < 0.0001)
    let landscape = SimctlScreenshotAspectProvider(captureScreenshot: { _ in fakePNG(width: 2622, height: 1206) })
    #expect(landscape.aspect(forDeviceWithUDID: "U")! > 1)  // rotated → wide
}
