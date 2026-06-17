import Foundation
import FauxApplication
import FauxAdapters

let command = FauxCommand(doctor: DoctorService(inspector: MachOToolInspector()))
exit(command.run(arguments: Array(CommandLine.arguments.dropFirst())))
