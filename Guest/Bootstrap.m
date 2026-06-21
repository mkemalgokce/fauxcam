#import <os/log.h>
#import <dispatch/dispatch.h>
#import <unistd.h>
#import <mach-o/dyld.h>
#include "../Shared/faux_wire.h"
#include "AVSwizzle.h"
#include "SessionSwizzle.h"
#include "PickerSwizzle.h"

static os_log_t faux_guest_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.fauxcam", "bootstrap"); });
    return log;
}

// Each install is success-gated and a no-op once done, so running it on every image load is cheap.
static void faux_install_all(void) {
    FauxInstallCameraDiscovery();
    FauxInstallCaptureSession();
    FauxInstallImagePickerCamera();
}

// Fires for every already-loaded image and every future dlopen. Frameworks loaded lazily by
// Flutter/Unity/React Native (AVFoundation, UIKit) thus get hooked the moment they appear.
static void faux_image_added(const struct mach_header *mh, intptr_t slide) {
    faux_install_all();
}

__attribute__((constructor))
static void faux_guest_bootstrap(void) {
    os_log(faux_guest_log(), "FauxCam guest alive pid=%d (wire v%d)", getpid(), FAUX_PROTO_VERSION);
    faux_install_all();
    _dyld_register_func_for_add_image(faux_image_added);
}
