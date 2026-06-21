#ifndef FAUX_PICKER_SWIZZLE_H
#define FAUX_PICKER_SWIZZLE_H

/// Makes UIImagePickerController's `.camera` source work in the Simulator by routing it to a
/// live FauxCam-fed capture screen, since the system camera picker is unavailable there and is
/// not backed by an AVCaptureSession the rest of the guest already swizzles.
void FauxInstallImagePickerCamera(void);

#endif
