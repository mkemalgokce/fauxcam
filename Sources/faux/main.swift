import Foundation
import OSLog
import FauxDomain
import FauxApplication
import FauxAdapters

private let compositionLog = Logger(subsystem: "com.fauxcam", category: "compose")
private let defaultBackColor = (blue: UInt8(0), green: UInt8(160), red: UInt8(80), alpha: UInt8(255))
private let webcamSourceToken = "webcam"
private let videoSourcePrefix = "video:"

private func makeFrameSource(_ spec: String) -> FrameSource {
    if spec == webcamSourceToken {
        if let webcam = WebcamSource() { return webcam }
        compositionLog.error("no camera available; falling back to image source")
        return ImageSource(solidColor: defaultBackColor)
    }
    if spec.hasPrefix(videoSourcePrefix) {
        let path = String(spec.dropFirst(videoSourcePrefix.count))
        guard FileManager.default.fileExists(atPath: path) else {
            compositionLog.error("video file not found at \(path, privacy: .public); falling back to image source")
            return ImageSource(solidColor: defaultBackColor)
        }
        return VideoFileSource(url: URL(fileURLWithPath: path))
    }
    return ImageSource(solidColor: defaultBackColor)
}

let command = FauxCommand(
    doctor: DoctorService(inspector: MachOToolInspector()),
    serverFactory: { socketPath, sourceSpec in
        FauxServer(
            coordinator: StreamCoordinator(
                source: makeFrameSource(sourceSpec),
                transport: try UnixSocketTransport(listeningAt: socketPath)
            )
        )
    }
)
exit(command.run(arguments: Array(CommandLine.arguments.dropFirst())))
