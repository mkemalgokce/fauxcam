import FauxApplication

struct FauxServer {
    private let coordinator: StreamCoordinating

    init(coordinator: StreamCoordinating) {
        self.coordinator = coordinator
    }

    func run() throws {
        try coordinator.pumpUntilDisconnect()
    }
}
