import Testing
import Foundation
import AppKit
import Kernel
import Framing
@testable import Presentation

@MainActor
struct PreviewModelTests {
    private static let previewLong = Int(OutputResolution.previewLongSide)
    private static let bezelLong = Int(OutputResolution.bezelLongSide)

    /// Runs the loop just long enough to capture at least one tick's demands, then stops it.
    private func capturedDemands(outputAspect: Double, configure: (PreviewModel) -> Void = { _ in }) async -> [Demand] {
        let producer = RecordingProducer()
        let model = PreviewModel(source: producer, cropStore: CropStore(), outputAspect: outputAspect)
        configure(model)
        model.start()
        await eventually { model.sourceImage != nil }
        model.stop()
        return producer.demands
    }

    @Test func portraitAspectSizesBothDemandsByTheirLongSide() async {
        let demands = await capturedDemands(outputAspect: 9.0 / 19.5)
        let viewfinder = demands.filter { max($0.requestedWidth, $0.requestedHeight) == Self.previewLong }
        let bezel = demands.filter { max($0.requestedWidth, $0.requestedHeight) == Self.bezelLong }
        #expect(!viewfinder.isEmpty)
        #expect(!bezel.isEmpty)
        for demand in demands {
            #expect(demand.position == .back)
            #expect(demand.requestedHeight >= demand.requestedWidth)
            let ratio = Double(demand.requestedWidth) / Double(demand.requestedHeight)
            #expect(abs(ratio - 9.0 / 19.5) < 0.02)
        }
    }

    @Test func landscapeAspectMakesWidthTheLongSide() async {
        let demands = await capturedDemands(outputAspect: 16.0 / 9.0)
        let viewfinder = demands.filter { max($0.requestedWidth, $0.requestedHeight) == Self.previewLong }
        #expect(!viewfinder.isEmpty)
        for demand in viewfinder {
            #expect(demand.requestedWidth == Self.previewLong)
            let ratio = Double(demand.requestedWidth) / Double(demand.requestedHeight)
            #expect(abs(ratio - 16.0 / 9.0) < 0.05)
        }
    }

    @Test func nonPositiveInitialAspectClampsToPortraitDefault() async {
        let demands = await capturedDemands(outputAspect: 0)
        #expect(!demands.isEmpty)
        for demand in demands {
            #expect(demand.requestedHeight >= demand.requestedWidth)
            let ratio = Double(demand.requestedWidth) / Double(demand.requestedHeight)
            #expect(abs(ratio - 9.0 / 19.5) < 0.02)
        }
    }

    @Test func setOutputAspectZeroClampsToPortraitDefault() async {
        let demands = await capturedDemands(outputAspect: 16.0 / 9.0) { model in
            model.setOutputAspect(0)
        }
        #expect(!demands.isEmpty)
        for demand in demands {
            #expect(demand.requestedHeight >= demand.requestedWidth)
        }
    }

    @Test func setCropWritesTheSharedStore() {
        let store = CropStore()
        let model = PreviewModel(source: RecordingProducer(), cropStore: store, outputAspect: 1)
        let region = CropRegion(centerX: 0.2, centerY: 0.8, zoom: 1.5)
        model.setCrop(region)
        #expect(store.current == region)
    }

    @Test func fpsStartsAtZero() {
        let model = PreviewModel(source: RecordingProducer(), cropStore: CropStore(), outputAspect: 1)
        #expect(model.fps == 0)
    }

    @Test func rebuildClearsRenderedImages() async {
        let model = PreviewModel(source: RecordingProducer(), cropStore: CropStore(), outputAspect: 1)
        model.start()
        await eventually { model.sourceImage != nil }
        model.stop()
        model.rebuild()
        #expect(model.sourceImage == nil)
        #expect(model.deviceImage == nil)
    }
}
