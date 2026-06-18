#ifndef FAUX_AVSWIZZLE_H
#define FAUX_AVSWIZZLE_H

#import <objc/objc.h>

void FauxInstallCameraDiscovery(void);
BOOL FauxIsFakeDevice(id device);
/// Returns the AVCaptureDevicePosition raw value for a fake device (2 = front, 1 = back, 0 = unspecified).
long FauxFakeDevicePosition(id device);

#endif
