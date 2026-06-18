import Foundation
import FauxDomain
import FauxApplication
import FauxAdapters

let defaultBackColor = (blue: UInt8(0), green: UInt8(160), red: UInt8(80), alpha: UInt8(255))
let videoSourcePrefix = "video:"

func makeFrameSource(_ spec: String) throws -> FrameSource {
    if spec == "webcam" {
        return WebcamSource() ?? ImageSource(solidColor: defaultBackColor)
    }
    if spec.hasPrefix(videoSourcePrefix) {
        return VideoFileSource(url: URL(fileURLWithPath: String(spec.dropFirst(videoSourcePrefix.count))))
    }
    return ImageSource(solidColor: defaultBackColor)
}

let command = FauxCommand(
    doctor: DoctorService(inspector: MachOToolInspector()),
    serverFactory: { socketPath, sourceSpec in
        FauxServer(
            coordinator: StreamCoordinator(
                source: try makeFrameSource(sourceSpec),
                transport: try UnixSocketTransport(listeningAt: socketPath)
            )
        )
    }
)
exit(command.run(arguments: Array(CommandLine.arguments.dropFirst())))
