import SwiftUI
import AppKit
import FauxAdapters

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = SessionController()

    func applicationWillTerminate(_ notification: Notification) {
        if controller.isRunning { controller.stop() }
    }
}

@main
struct FauxCamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("FauxCam", systemImage: "camera.fill") {
            FauxCamMenu(controller: appDelegate.controller)
                .frame(width: 320)
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}

struct FauxCamMenu: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("FauxCam").font(.headline)
                Spacer()
                Button("Refresh") { controller.refresh() }
            }

            if controller.devices.isEmpty {
                Text("No booted simulators.").foregroundStyle(.secondary)
            } else {
                Picker("Simulator", selection: $controller.selectedUDID) {
                    ForEach(controller.devices, id: \.udid) { device in
                        Text("\(device.name) — \(device.runtime)").tag(device.udid)
                    }
                }
            }

            TextField("App bundle id", text: $controller.bundleIdentifier)
                .textFieldStyle(.roundedBorder)

            Picker("Source", selection: $controller.sourceKind) {
                Text("Image").tag(SessionController.SourceKind.image)
                Text("Webcam").tag(SessionController.SourceKind.webcam)
                Text("Video").tag(SessionController.SourceKind.video)
                Text("QR").tag(SessionController.SourceKind.qr)
            }
            .pickerStyle(.segmented)

            if controller.sourceKind.needsDetail {
                TextField(controller.sourceKind.detailPrompt, text: $controller.sourceDetail)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                if controller.isRunning {
                    Button("Stop", role: .destructive) { controller.stop() }
                } else {
                    Button("Start") { controller.start() }
                        .disabled(controller.devices.isEmpty || controller.bundleIdentifier.isEmpty)
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }

            if !controller.status.isEmpty {
                Text(controller.status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
