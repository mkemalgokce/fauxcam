#include "AVSwizzle.h"

@import Foundation;
@import ObjectiveC.runtime;
@import os.log;
@import CoreMedia;
@import AVFoundation;

static NSString *const kFauxBackUniqueID = @"faux-back-0001";
static NSString *const kFauxFrontUniqueID = @"faux-front-0001";
static const void *kFauxUniqueIDKey = &kFauxUniqueIDKey;

static const NSInteger kCameraPositionBack = 1;
static const NSInteger kCameraPositionFront = 2;
static const NSInteger kAuthorizationStatusAuthorized = 3;

static const int32_t kFauxFormatWidth = 1920;
static const int32_t kFauxFormatHeight = 1080;

static os_log_t fauxDiscoveryLog;
static id fauxBackDevice;
static id fauxFrontDevice;

static NSInteger fauxPositionForDevice(id device) {
    NSString *uniqueID = objc_getAssociatedObject(device, kFauxUniqueIDKey);
    return [uniqueID isEqualToString:kFauxFrontUniqueID] ? kCameraPositionFront : kCameraPositionBack;
}

static NSInteger fauxDevicePosition(id self, SEL _cmd) {
    return fauxPositionForDevice(self);
}

static NSString *fauxDeviceUniqueID(id self, SEL _cmd) {
    return objc_getAssociatedObject(self, kFauxUniqueIDKey);
}

static NSString *fauxDeviceLocalizedName(id self, SEL _cmd) {
    return fauxPositionForDevice(self) == kCameraPositionFront ? @"Faux Front Camera" : @"Faux Back Camera";
}

static NSString *fauxDeviceModelID(id self, SEL _cmd) { return @"FauxCam Model"; }
static NSString *fauxDeviceManufacturer(id self, SEL _cmd) { return @"FauxCam"; }
static NSString *fauxDeviceType(id self, SEL _cmd) { return @"AVCaptureDeviceTypeBuiltInWideAngleCamera"; }

static BOOL fauxDeviceHasMediaType(id self, SEL _cmd, NSString *mediaType) {
    return [mediaType isEqualToString:@"vide"] || [mediaType isEqualToString:@"AVMediaTypeVideo"];
}

static BOOL fauxDeviceIsConnected(id self, SEL _cmd) { return YES; }
static BOOL fauxDeviceIsSuspended(id self, SEL _cmd) { return NO; }

static CMVideoFormatDescriptionRef fauxSharedFormatDescription(void) {
    static CMVideoFormatDescriptionRef formatDescription = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CMVideoFormatDescriptionCreate(kCFAllocatorDefault,
                                       kCMVideoCodecType_422YpCbCr8,
                                       kFauxFormatWidth, kFauxFormatHeight, NULL, &formatDescription);
    });
    return formatDescription;
}

static id fauxDeviceFormats(id self, SEL _cmd) {
    Class formatClass = objc_getClass("AVCaptureDeviceFormat");
    if (!formatClass) return @[];
    id format = [formatClass alloc];
    return [format isKindOfClass:formatClass] ? @[format] : @[];
}

static id fauxDeviceActiveFormat(id self, SEL _cmd) {
    NSArray *formats = fauxDeviceFormats(self, _cmd);
    return formats.count ? formats.firstObject : nil;
}

static CMVideoFormatDescriptionRef fauxFormatDescription(id self, SEL _cmd) {
    return fauxSharedFormatDescription();
}

static Class fauxRegisterDeviceClass(NSString *name) {
    Class existing = objc_getClass(name.UTF8String);
    if (existing) return existing;
    Class superClass = objc_getClass("AVCaptureDevice");
    if (!superClass) return Nil;
    Class deviceClass = objc_allocateClassPair(superClass, name.UTF8String, 0);
    if (!deviceClass) return Nil;
    class_addMethod(deviceClass, @selector(position), (IMP)fauxDevicePosition, "q@:");
    class_addMethod(deviceClass, @selector(uniqueID), (IMP)fauxDeviceUniqueID, "@@:");
    class_addMethod(deviceClass, @selector(localizedName), (IMP)fauxDeviceLocalizedName, "@@:");
    class_addMethod(deviceClass, @selector(modelID), (IMP)fauxDeviceModelID, "@@:");
    class_addMethod(deviceClass, @selector(manufacturer), (IMP)fauxDeviceManufacturer, "@@:");
    class_addMethod(deviceClass, @selector(deviceType), (IMP)fauxDeviceType, "@@:");
    class_addMethod(deviceClass, @selector(hasMediaType:), (IMP)fauxDeviceHasMediaType, "c@:@");
    class_addMethod(deviceClass, @selector(isConnected), (IMP)fauxDeviceIsConnected, "c@:");
    class_addMethod(deviceClass, @selector(isSuspended), (IMP)fauxDeviceIsSuspended, "c@:");
    class_addMethod(deviceClass, @selector(formats), (IMP)fauxDeviceFormats, "@@:");
    class_addMethod(deviceClass, @selector(activeFormat), (IMP)fauxDeviceActiveFormat, "@@:");
    objc_registerClassPair(deviceClass);
    return deviceClass;
}

static id fauxMakeDevice(NSString *uniqueID, NSString *className) {
    Class deviceClass = fauxRegisterDeviceClass(className);
    if (!deviceClass) return nil;
    id device = class_createInstance(deviceClass, 0);
    objc_setAssociatedObject(device, kFauxUniqueIDKey, uniqueID, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return device;
}

static void fauxBuildDevices(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fauxBackDevice = fauxMakeDevice(kFauxBackUniqueID, @"FauxCaptureDeviceBack");
        fauxFrontDevice = fauxMakeDevice(kFauxFrontUniqueID, @"FauxCaptureDeviceFront");
    });
}

static NSArray *fauxAllDevices(void) {
    fauxBuildDevices();
    if (!fauxBackDevice || !fauxFrontDevice) return @[];
    return @[fauxBackDevice, fauxFrontDevice];
}

static id fauxDiscoverySessionDevices(id self, SEL _cmd) {
    NSArray *devices = fauxAllDevices();
    os_log(fauxDiscoveryLog, "discovered=%lu", (unsigned long)devices.count);
    return devices;
}

static id fauxDefaultDevice(id self, SEL _cmd, NSString *deviceType, NSString *mediaType, NSInteger position) {
    fauxBuildDevices();
    return position == kCameraPositionFront ? fauxFrontDevice : fauxBackDevice;
}

static id fauxDevicesWithMediaType(id self, SEL _cmd, NSString *mediaType) { return fauxAllDevices(); }
static id fauxDevices(id self, SEL _cmd) { return fauxAllDevices(); }
static NSInteger fauxAuthorizationStatus(id self, SEL _cmd, NSString *mediaType) { return kAuthorizationStatusAuthorized; }

static void fauxRequestAccess(id self, SEL _cmd, NSString *mediaType, void (^handler)(BOOL)) {
    if (handler) dispatch_async(dispatch_get_main_queue(), ^{ handler(YES); });
}

static void fauxReplaceClassMethod(Class deviceClass, SEL selector, IMP implementation, const char *types) {
    Class metaClass = object_getClass(deviceClass);
    if (!class_replaceMethod(metaClass, selector, implementation, types)) {
        class_addMethod(metaClass, selector, implementation, types);
    }
}

static void fauxInstallInstanceMethod(Class targetClass, SEL selector, IMP implementation, const char *fallbackTypes) {
    Method existing = class_getInstanceMethod(targetClass, selector);
    const char *types = existing ? method_getTypeEncoding(existing) : fallbackTypes;
    if (!class_replaceMethod(targetClass, selector, implementation, types)) {
        class_addMethod(targetClass, selector, implementation, types);
    }
}

static void fauxInstallDiscoverySwizzle(void) {
    Class sessionClass = objc_getClass("AVCaptureDeviceDiscoverySession");
    if (!sessionClass) {
        os_log_error(fauxDiscoveryLog, "missing AVCaptureDeviceDiscoverySession");
        return;
    }
    fauxReplaceClassMethod(sessionClass, @selector(devices), (IMP)fauxDiscoverySessionDevices, "@@:");
    fauxInstallInstanceMethod(sessionClass, @selector(devices), (IMP)fauxDiscoverySessionDevices, "@@:");
}

static void fauxInstallFormatSwizzle(void) {
    Class formatClass = objc_getClass("AVCaptureDeviceFormat");
    if (!formatClass) return;
    fauxInstallInstanceMethod(formatClass, @selector(formatDescription), (IMP)fauxFormatDescription, "^{opaqueCMFormatDescription=}@:");
}

static void fauxInstallDeviceClassSwizzle(void) {
    Class deviceClass = objc_getClass("AVCaptureDevice");
    if (!deviceClass) {
        os_log_error(fauxDiscoveryLog, "missing AVCaptureDevice");
        return;
    }
    fauxReplaceClassMethod(deviceClass, @selector(defaultDeviceWithDeviceType:mediaType:position:), (IMP)fauxDefaultDevice, "@@:@@q");
    fauxReplaceClassMethod(deviceClass, @selector(devicesWithMediaType:), (IMP)fauxDevicesWithMediaType, "@@:@");
    fauxReplaceClassMethod(deviceClass, @selector(devices), (IMP)fauxDevices, "@@:");
    fauxReplaceClassMethod(deviceClass, @selector(authorizationStatusForMediaType:), (IMP)fauxAuthorizationStatus, "q@:@");
    fauxReplaceClassMethod(deviceClass, @selector(requestAccessForMediaType:completionHandler:), (IMP)fauxRequestAccess, "v@:@@?");
}

void FauxInstallCameraDiscovery(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fauxDiscoveryLog = os_log_create("com.fauxcam", "discovery");
        fauxBuildDevices();
        fauxInstallDiscoverySwizzle();
        fauxInstallFormatSwizzle();
        fauxInstallDeviceClassSwizzle();
        os_log(fauxDiscoveryLog, "camera discovery installed devices=%lu", (unsigned long)fauxAllDevices().count);
    });
}
