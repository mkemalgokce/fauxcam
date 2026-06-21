/// Pure parsers for the Mach-O CLI tool output — fully unit-testable, no process.
enum MachOParse {
    /// `lipo -archs` -> the listed architectures.
    static func architectures(fromLipoArchs output: String) -> [String] {
        output.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }
    /// `otool -l` -> true if a build-version load command targets PLATFORM_IOSSIMULATOR (7).
    static func isSimulatorPlatform(fromOtool output: String) -> Bool {
        output.contains("platform 7") || output.contains("PLATFORM_IOSSIMULATOR")
    }
    /// `codesign -dvvv` -> true if the signature is ad-hoc.
    static func isAdHocSigned(fromCodesign output: String) -> Bool {
        output.lowercased().contains("adhoc")
    }
}
