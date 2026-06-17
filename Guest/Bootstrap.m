#import <os/log.h>
#import <dispatch/dispatch.h>
#import <unistd.h>
#include "../Shared/faux_wire.h"
#include "AVSwizzle.h"
#include "SessionSwizzle.h"

static os_log_t faux_guest_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.fauxcam", "bootstrap"); });
    return log;
}

__attribute__((constructor))
static void faux_guest_bootstrap(void) {
    os_log(faux_guest_log(), "FauxCam guest alive pid=%d (wire v%d)", getpid(), FAUX_PROTO_VERSION);
    FauxInstallCameraDiscovery();
    FauxInstallCaptureSession();
}
