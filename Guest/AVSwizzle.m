#include "AVSwizzle.h"
#include "FauxConfig.h"

@import Foundation;
@import ObjectiveC.runtime;
@import os.log;
@import CoreMedia;
@import AVFoundation;

static NSString *const kFauxBackUniqueID = @"faux-back-0001";
static NSString *const kFauxFrontUniqueID = @"faux-front-0001";
static NSString *const kVideoMediaTypeCode = @"vide";
static const void *kFauxUniqueIDKey = &kFauxUniqueIDKey;

static const NSInteger kFauxPositionBack = AVCaptureDevicePositionBack;
static const NSInteger kFauxPositionFront = AVCaptureDevicePositionFront;
static const NSInteger kFauxAuthorizationAuthorized = AVAuthorizationStatusAuthorized;


static id fauxBackDevice;
static id fauxFrontDevice;
static IMP fauxOriginalDefaultDevice;
static IMP fauxOriginalDevices;
static IMP fauxOriginalDevicesWithMediaType;
static IMP fauxOriginalAuthorizationStatus;
static IMP fauxOriginalRequestAccess;

static os_log_t fauxLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.fauxcam", "discovery"); });
    return log;
}

static BOOL fauxIsVideoMediaType(NSString *mediaType) {
    return [mediaType isEqualToString:kVideoMediaTypeCode] || [mediaType isEqualToString:AVMediaTypeVideo];
}

BOOL FauxIsFakeDevice(id device) {
    if (!device) return NO;
    NSString *uniqueID = objc_getAssociatedObject(device, kFauxUniqueIDKey);
    return [uniqueID isEqualToString:kFauxBackUniqueID] || [uniqueID isEqualToString:kFauxFrontUniqueID];
}

// MARK: - Fake device getters

static NSInteger fauxPositionForDevice(id device) {
    NSString *uniqueID = objc_getAssociatedObject(device, kFauxUniqueIDKey);
    return [uniqueID isEqualToString:kFauxFrontUniqueID] ? kFauxPositionFront : kFauxPositionBack;
}

static NSInteger fauxDevicePosition(id self, SEL _cmd) { return fauxPositionForDevice(self); }
static NSString *fauxDeviceUniqueID(id self, SEL _cmd) { return objc_getAssociatedObject(self, kFauxUniqueIDKey); }
static NSString *fauxDeviceLocalizedName(id self, SEL _cmd) {
    return fauxPositionForDevice(self) == kFauxPositionFront ? @"Faux Front Camera" : @"Faux Back Camera";
}
static NSString *fauxDeviceModelID(id self, SEL _cmd) { return @"FauxCam Model"; }
static NSString *fauxDeviceManufacturer(id self, SEL _cmd) { return @"FauxCam"; }
static NSString *fauxDeviceType(id self, SEL _cmd) { return @"AVCaptureDeviceTypeBuiltInWideAngleCamera"; }
static BOOL fauxDeviceHasMediaType(id self, SEL _cmd, NSString *mediaType) { return fauxIsVideoMediaType(mediaType); }
static BOOL fauxDeviceIsConnected(id self, SEL _cmd) { return YES; }
static BOOL fauxDeviceIsSuspended(id self, SEL _cmd) { return NO; }

// MARK: - Fake format

static CMVideoFormatDescriptionRef fauxSharedFormatDescription(void) {
    static CMVideoFormatDescriptionRef formatDescription = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        OSStatus status = CMVideoFormatDescriptionCreate(kCFAllocatorDefault,
                                                         kCMVideoCodecType_422YpCbCr8,
                                                         faux_config_width(), faux_config_height(), NULL, &formatDescription);
        if (status != noErr) {
            os_log_error(fauxLog(), "format description create failed status=%d", (int)status);
            formatDescription = NULL;
        }
    });
    return formatDescription;
}

static CMVideoFormatDescriptionRef fauxFormatDescription(id self, SEL _cmd) { return fauxSharedFormatDescription(); }
static NSString *fauxFormatMediaType(id self, SEL _cmd) { return kVideoMediaTypeCode; }
static NSString *fauxFormatDescriptionText(id self, SEL _cmd) {
    return [NSString stringWithFormat:@"<FauxCaptureDeviceFormat %dx%d>", faux_config_width(), faux_config_height()];
}

static id fauxSharedFormat(void) {
    static id format;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class superClass = objc_getClass("AVCaptureDeviceFormat");
        if (!superClass) return;
        Class formatClass = objc_getClass("FauxCaptureDeviceFormat");
        if (!formatClass) {
            formatClass = objc_allocateClassPair(superClass, "FauxCaptureDeviceFormat", 0);
            if (!formatClass) return;
            class_addMethod(formatClass, @selector(formatDescription), (IMP)fauxFormatDescription, "^{opaqueCMFormatDescription=}@:");
            class_addMethod(formatClass, @selector(mediaType), (IMP)fauxFormatMediaType, "@@:");
            class_addMethod(formatClass, @selector(description), (IMP)fauxFormatDescriptionText, "@@:");
            objc_registerClassPair(formatClass);
        }
        format = class_createInstance(formatClass, 0);
    });
    return format;
}

static id fauxDeviceFormats(id self, SEL _cmd) {
    id format = fauxSharedFormat();
    return format ? @[format] : @[];
}
static id fauxDeviceActiveFormat(id self, SEL _cmd) { return fauxSharedFormat(); }

// MARK: - Fake device construction

/// Builds the fake AVCaptureDevice subclass used for camera discovery. The instance
/// is created without AVCaptureDevice's designated initializer, so only the discovery
/// selectors (plus NSObject defaults) are valid on it; SessionSwizzle intercepts every
/// AVCaptureSession / AVCaptureDeviceInput usage path, so the zeroed-ivar device is
/// never driven by AVFoundation directly.
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
    class_addMethod(deviceClass, @selector(hasMediaType:), (IMP)fauxDeviceHasMediaType, "B@:@");
    class_addMethod(deviceClass, @selector(isConnected), (IMP)fauxDeviceIsConnected, "B@:");
    class_addMethod(deviceClass, @selector(isSuspended), (IMP)fauxDeviceIsSuspended, "B@:");
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

// MARK: - Swizzled implementations

static id fauxDiscoverySessionDevices(id self, SEL _cmd) { return fauxAllDevices(); }

static id fauxDefaultDevice(id self, SEL _cmd, NSString *deviceType, NSString *mediaType, NSInteger position) {
    if (fauxIsVideoMediaType(mediaType)) {
        fauxBuildDevices();
        return position == kFauxPositionFront ? fauxFrontDevice : fauxBackDevice;
    }
    if (fauxOriginalDefaultDevice) {
        return ((id (*)(id, SEL, NSString *, NSString *, NSInteger))fauxOriginalDefaultDevice)(self, _cmd, deviceType, mediaType, position);
    }
    return nil;
}

static id fauxDevicesWithMediaType(id self, SEL _cmd, NSString *mediaType) {
    if (fauxIsVideoMediaType(mediaType)) return fauxAllDevices();
    if (fauxOriginalDevicesWithMediaType) {
        return ((id (*)(id, SEL, NSString *))fauxOriginalDevicesWithMediaType)(self, _cmd, mediaType);
    }
    return @[];
}

static id fauxDevices(id self, SEL _cmd) {
    NSArray *original = fauxOriginalDevices ? ((id (*)(id, SEL))fauxOriginalDevices)(self, _cmd) : @[];
    if (![original isKindOfClass:[NSArray class]]) original = @[];
    return [original arrayByAddingObjectsFromArray:fauxAllDevices()];
}

static NSInteger fauxAuthorizationStatus(id self, SEL _cmd, NSString *mediaType) {
    if (fauxIsVideoMediaType(mediaType)) return kFauxAuthorizationAuthorized;
    if (fauxOriginalAuthorizationStatus) {
        return ((NSInteger (*)(id, SEL, NSString *))fauxOriginalAuthorizationStatus)(self, _cmd, mediaType);
    }
    return AVAuthorizationStatusNotDetermined;
}

static void fauxRequestAccess(id self, SEL _cmd, NSString *mediaType, void (^handler)(BOOL)) {
    if (fauxIsVideoMediaType(mediaType)) {
        if (handler) dispatch_async(dispatch_get_main_queue(), ^{ handler(YES); });
        return;
    }
    if (fauxOriginalRequestAccess) {
        ((void (*)(id, SEL, NSString *, void (^)(BOOL)))fauxOriginalRequestAccess)(self, _cmd, mediaType, handler);
        return;
    }
    if (handler) dispatch_async(dispatch_get_main_queue(), ^{ handler(NO); });
}

// MARK: - Installation

static IMP fauxOriginalClassMethodImplementation(Class targetClass, SEL selector) {
    Method method = class_getClassMethod(targetClass, selector);
    return method ? method_getImplementation(method) : NULL;
}

static void fauxReplaceClassMethod(Class targetClass, SEL selector, IMP implementation, const char *fallbackTypes) {
    Class metaClass = object_getClass(targetClass);
    Method existing = class_getClassMethod(targetClass, selector);
    const char *types = existing ? method_getTypeEncoding(existing) : fallbackTypes;
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
        os_log_error(fauxLog(), "missing AVCaptureDeviceDiscoverySession");
        return;
    }
    fauxInstallInstanceMethod(sessionClass, @selector(devices), (IMP)fauxDiscoverySessionDevices, "@@:");
}

static void fauxInstallDeviceClassSwizzle(void) {
    Class deviceClass = objc_getClass("AVCaptureDevice");
    if (!deviceClass) {
        os_log_error(fauxLog(), "missing AVCaptureDevice");
        return;
    }
    fauxOriginalDefaultDevice = fauxOriginalClassMethodImplementation(deviceClass, @selector(defaultDeviceWithDeviceType:mediaType:position:));
    fauxOriginalDevices = fauxOriginalClassMethodImplementation(deviceClass, @selector(devices));
    fauxOriginalDevicesWithMediaType = fauxOriginalClassMethodImplementation(deviceClass, @selector(devicesWithMediaType:));
    fauxOriginalAuthorizationStatus = fauxOriginalClassMethodImplementation(deviceClass, @selector(authorizationStatusForMediaType:));
    fauxOriginalRequestAccess = fauxOriginalClassMethodImplementation(deviceClass, @selector(requestAccessForMediaType:completionHandler:));

    fauxReplaceClassMethod(deviceClass, @selector(defaultDeviceWithDeviceType:mediaType:position:), (IMP)fauxDefaultDevice, "@@:@@q");
    fauxReplaceClassMethod(deviceClass, @selector(devicesWithMediaType:), (IMP)fauxDevicesWithMediaType, "@@:@");
    fauxReplaceClassMethod(deviceClass, @selector(devices), (IMP)fauxDevices, "@@:");
    fauxReplaceClassMethod(deviceClass, @selector(authorizationStatusForMediaType:), (IMP)fauxAuthorizationStatus, "q@:@");
    fauxReplaceClassMethod(deviceClass, @selector(requestAccessForMediaType:completionHandler:), (IMP)fauxRequestAccess, "v@:@@?");
}

void FauxInstallCameraDiscovery(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fauxBuildDevices();
        fauxInstallDiscoverySwizzle();
        fauxInstallDeviceClassSwizzle();
        os_log(fauxLog(), "camera discovery installed devices=%lu", (unsigned long)fauxAllDevices().count);
    });
}
