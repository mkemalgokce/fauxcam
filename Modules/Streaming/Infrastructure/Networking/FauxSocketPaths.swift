/// The well-known AF_UNIX endpoints, mirrored from `Shared/faux_wire.h` (`FAUX_SOCKET_DIR` /
/// `FAUX_AUTO_SOCKET`) so the host and the injected guest agree on a single source of truth. The
/// equality is asserted by the wire contract test, so any divergence from the C header breaks the build.
public enum FauxSocketPaths {
    public static let directory = "/private/tmp/com.fauxcam"
    public static let autoServer = directory + "/auto.sock"
}
