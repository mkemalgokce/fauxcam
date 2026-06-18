import Foundation
import FauxApplication
import FauxAdapters

let defaultBackColor = (blue: UInt8(0), green: UInt8(160), red: UInt8(80), alpha: UInt8(255))

let command = FauxCommand(
    doctor: DoctorService(inspector: MachOToolInspector()),
    serverFactory: { socketPath in
        FauxServer(
            coordinator: StreamCoordinator(
                source: ImageSource(solidColor: defaultBackColor),
                transport: try UnixSocketTransport(listeningAt: socketPath)
            )
        )
    }
)
exit(command.run(arguments: Array(CommandLine.arguments.dropFirst())))
