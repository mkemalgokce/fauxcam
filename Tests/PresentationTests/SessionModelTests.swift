import Testing
import Foundation
import Kernel
import Capture
import Simulators
import Injection
import Framing
@testable import Presentation

@MainActor
struct SessionModelSourceTests {
    @Test func initialSourceIsTestImage() {
        let harness = makeSessionHarness()
        #expect(harness.factory.descriptors == [.testImage])
        #expect(harness.model.sourceDescriptor == .testImage)
    }

    @Test func switchingKindRebuildsTheLiveSource() {
        let harness = makeSessionHarness()
        let model = harness.model

        model.videoPath = "/tmp/clip.mov"
        model.sourceKind = .video
        #expect(harness.factory.descriptors.last == .video(URL(fileURLWithPath: "/tmp/clip.mov")))

        model.sourceKind = .qr
        model.qrText = "hello"
        #expect(harness.factory.descriptors.last == .qr("hello"))

        model.sourceKind = .image
        #expect(harness.factory.descriptors.last == .testImage)
    }

    @Test func sameKindDoesNotRebuild() {
        let harness = makeSessionHarness()
        let countBefore = harness.factory.descriptors.count
        harness.model.sourceKind = .image
        #expect(harness.factory.descriptors.count == countBefore)
    }

    @Test func sourceDescriptorReflectsPaths() {
        let harness = makeSessionHarness()
        let model = harness.model
        model.imagePath = "/tmp/pic.png"
        #expect(model.sourceDescriptor == .image(URL(fileURLWithPath: "/tmp/pic.png")))
        #expect(model.hasCustomMedia)
        #expect(model.mediaLabel == "pic.png")
    }

    @Test func chooseMediaRoutesByExtension() {
        let harness = makeSessionHarness()
        let model = harness.model

        model.chooseMedia(URL(fileURLWithPath: "/tmp/movie.MOV"))
        #expect(model.sourceKind == .video)
        #expect(model.videoPath == "/tmp/movie.MOV")

        model.chooseMedia(URL(fileURLWithPath: "/tmp/shot.png"))
        #expect(model.sourceKind == .image)
        #expect(model.imagePath == "/tmp/shot.png")
    }

    @Test func resetMediaClearsPathsAndReturnsToImage() {
        let harness = makeSessionHarness()
        let model = harness.model
        model.videoPath = "/tmp/movie.mov"
        model.sourceKind = .video
        model.resetMedia()
        #expect(model.imagePath.isEmpty)
        #expect(model.videoPath.isEmpty)
        #expect(model.sourceKind == .image)
        #expect(model.mediaLabel == "Test image")
        #expect(!model.hasCustomMedia)
    }

    @Test func liveCropWritesTheSharedStore() {
        let harness = makeSessionHarness()
        let region = CropRegion(centerX: 0.3, centerY: 0.7, zoom: 2.0)
        harness.model.region = region
        #expect(harness.cropStore.current == region)
    }
}

@MainActor
struct SessionModelDeviceTests {
    @Test func firstPollPopulatesDevicesAndDefaultsToFirst() async {
        let alpha = device("A"), beta = device("B")
        let harness = makeSessionHarness(devices: [alpha, beta])
        harness.model.startPolling()
        await eventually { harness.model.devices == [alpha, beta] }
        harness.model.stopPolling()
        #expect(harness.model.selectedUDID == "A")
        #expect(harness.model.selectedDevice == alpha)
    }

    @Test func validSelectionSurvivesAPoll() async {
        let alpha = device("A"), beta = device("B")
        let harness = makeSessionHarness(devices: [alpha, beta])
        harness.model.selectedUDID = "B"
        harness.model.startPolling()
        await eventually { harness.model.devices == [alpha, beta] }
        harness.model.stopPolling()
        #expect(harness.model.selectedUDID == "B")
    }

    @Test func staleSelectionFallsBackToFirst() async {
        let alpha = device("A"), beta = device("B")
        let harness = makeSessionHarness(devices: [alpha, beta])
        harness.model.selectedUDID = "GONE"
        harness.model.startPolling()
        await eventually { harness.model.devices == [alpha, beta] }
        harness.model.stopPolling()
        #expect(harness.model.selectedUDID == "A")
    }

    @Test func noBootedDevicesClearsSelection() async {
        let harness = makeSessionHarness(devices: [])
        harness.model.selectedUDID = "A"
        harness.model.startPolling()
        await eventually { harness.model.selectedUDID == "" }
        harness.model.stopPolling()
        #expect(harness.model.selectedUDID == "")
    }

    @Test func orientationIsRememberedPerDevice() {
        let harness = makeSessionHarness()
        let model = harness.model
        model.selectedUDID = "A"
        model.setDeviceLandscape(true)

        model.selectDevice("B")
        #expect(model.deviceLandscape == false)
        #expect(harness.cropStore.read().rotationRadians == 0)

        model.selectDevice("A")
        #expect(model.deviceLandscape == true)
        #expect(abs(harness.cropStore.read().rotationRadians - .pi / 2) < 1e-9)
    }

    @Test func toggleOrientationFlipsLandscape() {
        let harness = makeSessionHarness()
        #expect(harness.model.deviceLandscape == false)
        harness.model.toggleDeviceOrientation()
        #expect(harness.model.deviceLandscape == true)
    }

    @Test func togglingOrientationRotatesTheCropStoreWithoutMutatingRegion() {
        let harness = makeSessionHarness()
        let model = harness.model
        let regionBefore = model.region

        model.setDeviceLandscape(true)
        #expect(model.region == regionBefore)
        #expect(abs(harness.cropStore.read().rotationRadians - .pi / 2) < 1e-9)

        model.setDeviceLandscape(false)
        #expect(model.region == regionBefore)
        #expect(harness.cropStore.read().rotationRadians == 0)
    }

    @Test func selectedDeviceResolvesNameAndIsNilWhenNoneBooted() async {
        let alpha = device("A")
        let harness = makeSessionHarness(devices: [alpha])
        #expect(harness.model.selectedDevice == nil)
        harness.model.startPolling()
        await eventually { harness.model.selectedDevice == alpha }
        harness.model.stopPolling()
        #expect(harness.model.selectedDevice?.name == alpha.name)
    }
}

@MainActor
struct SessionModelAspectTests {
    @Test func portraitAspectIsTheNativeAspect() {
        let harness = makeSessionHarness()
        #expect(harness.model.nativeDeviceAspect == 9.0 / 19.5)
        #expect(harness.model.previewAspect == 9.0 / 19.5)
    }

    @Test func landscapeInvertsThePreviewAspect() {
        let harness = makeSessionHarness()
        harness.model.setDeviceLandscape(true)
        #expect(harness.model.previewAspect == 1.0 / (9.0 / 19.5))
    }

    @Test func refreshAdoptsTheResolvedScreenAspect() async {
        let harness = makeSessionHarness(aspect: 1170.0 / 2532.0)
        harness.model.selectedUDID = "A"
        await harness.model.refreshDeviceAspect()
        #expect(harness.model.deviceAspect == 1170.0 / 2532.0)
        #expect(harness.model.nativeDeviceAspect == 1170.0 / 2532.0)
    }

    @Test func nonPositiveResolvedAspectFallsBackToDefault() async {
        let harness = makeSessionHarness(aspect: nil)
        harness.model.selectedUDID = "A"
        await harness.model.refreshDeviceAspect()
        #expect(harness.model.nativeDeviceAspect == 9.0 / 19.5)
    }
}

@MainActor
struct SessionModelInjectionTests {
    @Test func autoInjectIsGatedOnOnboarding() async {
        let harness = makeSessionHarness(devices: [device("A")], onboarded: false)
        harness.model.startPolling()
        await eventually { harness.model.devices == [device("A")] }
        harness.model.stopPolling()
        #expect(await harness.injection.isActive == false)
        #expect(await harness.env.installed.isEmpty)
    }

    @Test func completingOnboardingReleasesAutoInjection() async {
        let harness = makeSessionHarness(devices: [device("A")], onboarded: false)
        harness.model.startPolling()
        await eventually { harness.model.devices == [device("A")] }
        harness.model.stopPolling()
        #expect(await harness.injection.isActive == false)

        harness.settings.hasOnboarded = true
        harness.model.onboardingDidComplete()
        #expect(await eventually { await harness.injection.isActive })
        #expect(await harness.env.installed == ["A"])
    }

    @Test func toggleWithNoDevicesSurfacesError() async {
        let harness = makeSessionHarness(devices: [])
        await harness.model.toggleInjection()
        #expect(harness.model.isInjecting == false)
        #expect(harness.model.lastError == "No booted simulators — boot one to start injecting.")
    }

    @Test func toggleSurfacesServerBindFailure() async {
        let harness = makeSessionHarness(devices: [device("A")], onboarded: false, server: BindFailingServer())
        harness.model.startPolling()
        await eventually { harness.model.devices == [device("A")] }
        harness.model.stopPolling()
        await harness.model.toggleInjection()
        #expect(harness.model.isInjecting == false)
        #expect((harness.model.lastError ?? "").contains("Frame server unavailable"))
    }

    @Test func toggleStaysActiveButWarnsOnXcodeHookFailure() async {
        let harness = makeSessionHarness(devices: [device("A")], onboarded: false, xcode: ThrowingXcode())
        harness.model.startPolling()
        await eventually { harness.model.devices == [device("A")] }
        harness.model.stopPolling()
        await harness.model.toggleInjection()
        #expect(harness.model.isInjecting == true)
        #expect((harness.model.lastError ?? "").contains("Xcode-run injection unavailable"))
    }

    @Test func toggleEnablesThenDisablesCleanly() async {
        let harness = makeSessionHarness(devices: [device("A")], onboarded: false)
        harness.model.startPolling()
        await eventually { harness.model.devices == [device("A")] }
        harness.model.stopPolling()

        await harness.model.toggleInjection()
        #expect(harness.model.isInjecting == true)
        #expect(harness.model.lastError == nil)

        await harness.model.toggleInjection()
        #expect(harness.model.isInjecting == false)
        #expect(harness.model.lastError == nil)
    }
}
