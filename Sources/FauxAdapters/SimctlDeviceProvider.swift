import Foundation
import FauxDomain

public enum SimDeviceError: Error {
    case simctlFailed
}

public enum SimctlDeviceListDecoder {
    private struct ListDTO: Decodable {
        let devices: [String: [DeviceDTO]]
    }

    private struct DeviceDTO: Decodable {
        let udid: String
        let name: String
        let state: String?
    }

    public static func decode(_ data: Data) -> [SimDevice] {
        guard let list = try? JSONDecoder().decode(ListDTO.self, from: data) else { return [] }
        var devices: [SimDevice] = []
        for (runtimeIdentifier, entries) in list.devices {
            for entry in entries where entry.state == "Booted" {
                devices.append(SimDevice(udid: entry.udid, name: entry.name, runtime: readableRuntime(from: runtimeIdentifier)))
            }
        }
        return devices.sorted { $0.name < $1.name }
    }

    static func readableRuntime(from identifier: String) -> String {
        guard let lastComponent = identifier.split(separator: ".").last else { return identifier }
        let parts = lastComponent.split(separator: "-")
        guard let platform = parts.first, parts.count >= 2 else { return String(lastComponent) }
        let version = parts.dropFirst().joined(separator: ".")
        return "\(platform) \(version)"
    }
}

public struct SimctlDeviceProvider: SimDeviceProviding {
    private let runSimctl: ([String]) -> Data?

    public init(runSimctl: @escaping ([String]) -> Data? = SimctlDeviceProvider.runViaXcrun) {
        self.runSimctl = runSimctl
    }

    public func bootedDevices() throws -> [SimDevice] {
        guard let data = runSimctl(["list", "devices", "booted", "-j"]) else { throw SimDeviceError.simctlFailed }
        return SimctlDeviceListDecoder.decode(data)
    }

    public static func runViaXcrun(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }
}
