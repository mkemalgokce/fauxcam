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

static const NSInteger kFauxPositionUnspecified = AVCaptureDevicePositionUnspecified;
static const NSInteger kFauxPositionBack = AVCaptureDevicePositionBack;
static const NSInteger kFauxPositionFront = AVCaptureDevicePositionFront;
static const NSInteger kFauxAuthorizationAuthorized = AVAuthorizationStatusAuthorized;


static id fauxBackDevice;
static id fauxFrontDevice;
static IMP fauxOriginalDefaultDevice;
static IMP fauxOriginalDefaultDeviceWithMediaType;
static IMP fauxOriginalDeviceWithUniqueID;
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

long FauxFakeDevicePosition(id device) {
    if (!device) return 0;
    NSString *uniqueID = objc_getAssociatedObject(device, kFauxUniqueIDKey);
    if ([uniqueID isEqualToString:kFauxFrontUniqueID]) return kFauxPositionFront;
    if ([uniqueID isEqualToString:kFauxBackUniqueID]) return kFauxPositionBack;
    return 0;
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
static void *fauxFormatNullPointer(id self, SEL _cmd) { return NULL; }
static id fauxFormatEmptyArray(id self, SEL _cmd) { return @[]; }
static BOOL fauxFormatBoolNo(id self, SEL _cmd) { return NO; }
static float fauxFormatFloatFOV(id self, SEL _cmd) { return 60.0f; }
static CGFloat fauxFormatZoomOne(id self, SEL _cmd) { return 1.0; }
static long fauxFormatAutoFocusSystem(id self, SEL _cmd) { return 0; }

// Benign forwarding net for fake AV subclasses: any selector with no IMP anywhere returns nil/zero
// instead of crashing.
static NSMethodSignature *fauxAVFwdSig(id self, SEL _cmd, SEL sel) { return [NSMethodSignature signatureWithObjCTypes:"@@:"]; }
static void fauxAVFwdInvoke(id self, SEL _cmd, NSInvocation *inv) { id n = nil; @try { [inv setReturnValue:&n]; } @catch (__unused id e) { } }
static void fauxAVInstallNet(Class cls) {
    if (!cls) return;
    class_addMethod(cls, @selector(methodSignatureForSelector:), (IMP)fauxAVFwdSig, "@@::");
    class_addMethod(cls, @selector(forwardInvocation:), (IMP)fauxAVFwdInvoke, "v@:@");
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
            class_addMethod(formatClass, sel_registerName("figCaptureSourceVideoFormat"), (IMP)fauxFormatNullPointer, "^v@:");
            class_addMethod(formatClass, @selector(videoSupportedFrameRateRanges), (IMP)fauxFormatEmptyArray, "@@:");
            class_addMethod(formatClass, @selector(supportedColorSpaces), (IMP)fauxFormatEmptyArray, "@@:");
            class_addMethod(formatClass, @selector(supportedDepthDataFormats), (IMP)fauxFormatEmptyArray, "@@:");
            class_addMethod(formatClass, @selector(videoFieldOfView), (IMP)fauxFormatFloatFOV, "f@:");
            class_addMethod(formatClass, @selector(videoMaxZoomFactor), (IMP)fauxFormatZoomOne, "d@:");
            class_addMethod(formatClass, @selector(videoZoomFactorUpscaleThreshold), (IMP)fauxFormatZoomOne, "d@:");
            class_addMethod(formatClass, @selector(isVideoBinned), (IMP)fauxFormatBoolNo, "B@:");
            class_addMethod(formatClass, @selector(isVideoHDRSupported), (IMP)fauxFormatBoolNo, "B@:");
            class_addMethod(formatClass, @selector(isHighestPhotoQualitySupported), (IMP)fauxFormatBoolNo, "B@:");
            class_addMethod(formatClass, @selector(autoFocusSystem), (IMP)fauxFormatAutoFocusSystem, "q@:");
            objc_registerClassPair(formatClass);
            fauxAVInstallNet(formatClass);
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

// MARK: - Fake device configuration accessors (crash-safety)
// These are REAL AVCaptureDevice methods; on the fake (zeroed-ivar) instance the inherited
// implementations dereference uninitialized internal state and crash. Camera frameworks
// (Flutter, vision-camera, etc.) routinely call them, so we override with benign behavior.

static BOOL fauxDeviceLockForConfiguration(id self, SEL _cmd, NSError **error) { if (error) *error = nil; return YES; }
static void fauxDeviceUnlockForConfiguration(id self, SEL _cmd) { }
static BOOL fauxDeviceBoolNo(id self, SEL _cmd) { return NO; }
static BOOL fauxDeviceBoolYesArg(id self, SEL _cmd, id arg) { return YES; }
static BOOL fauxDeviceModeSupported(id self, SEL _cmd, NSInteger mode) { return NO; }
static BOOL fauxDeviceSetTorchModeOnWithLevel(id self, SEL _cmd, float level, NSError **error) { if (error) *error = nil; return YES; }
static NSInteger fauxDeviceIntegerZero(id self, SEL _cmd) { return 0; }
static void fauxDeviceSetIntegerNoop(id self, SEL _cmd, NSInteger value) { }
static float fauxDeviceFloatZero(id self, SEL _cmd) { return 0.0f; }
static CGFloat fauxDeviceZoomOne(id self, SEL _cmd) { return 1.0; }
static void fauxDeviceSetZoom(id self, SEL _cmd, CGFloat factor) { }
static void fauxDeviceSetObjectNoop(id self, SEL _cmd, id value) { }
static CMTime fauxDeviceFrameDuration(id self, SEL _cmd) { return CMTimeMake(1, faux_config_fps() > 0 ? faux_config_fps() : 30); }
static void fauxDeviceSetFrameDuration(id self, SEL _cmd, CMTime duration) { }
static CMTime fauxDeviceMinExposure(id self, SEL _cmd) { return CMTimeMake(1, 1000); }
static CMTime fauxDeviceMaxExposure(id self, SEL _cmd) { return CMTimeMake(1, 3); }
static float fauxDeviceFloatHundred(id self, SEL _cmd) { return 100.0f; }
static float fauxDeviceFloatTwo(id self, SEL _cmd) { return 2.0f; }
static void fauxDeviceSetBoolNoop(id self, SEL _cmd, BOOL v) { }
static id fauxDeviceEmptyArray(id self, SEL _cmd) { return @[]; }
static CGPoint fauxDevicePointCenter(id self, SEL _cmd) { return CGPointMake(0.5, 0.5); }
static void fauxDeviceSetPoint(id self, SEL _cmd, CGPoint p) { }

static void fauxAddDeviceConfigMethods(Class deviceClass) {
    NSString *cmTimeGet = [NSString stringWithFormat:@"%s@:", @encode(CMTime)];
    NSString *cmTimeSet = [NSString stringWithFormat:@"v@:%s", @encode(CMTime)];
    class_addMethod(deviceClass, @selector(lockForConfiguration:), (IMP)fauxDeviceLockForConfiguration, "B@:^@");
    class_addMethod(deviceClass, @selector(unlockForConfiguration), (IMP)fauxDeviceUnlockForConfiguration, "v@:");
    class_addMethod(deviceClass, @selector(hasTorch), (IMP)fauxDeviceBoolNo, "B@:");
    class_addMethod(deviceClass, @selector(hasFlash), (IMP)fauxDeviceBoolNo, "B@:");
    class_addMethod(deviceClass, @selector(isTorchAvailable), (IMP)fauxDeviceBoolNo, "B@:");
    class_addMethod(deviceClass, @selector(isFlashAvailable), (IMP)fauxDeviceBoolNo, "B@:");
    class_addMethod(deviceClass, @selector(isTorchActive), (IMP)fauxDeviceBoolNo, "B@:");
    class_addMethod(deviceClass, @selector(supportsAVCaptureSessionPreset:), (IMP)fauxDeviceBoolYesArg, "B@:@");
    class_addMethod(deviceClass, @selector(isTorchModeSupported:), (IMP)fauxDeviceModeSupported, "B@:q");
    class_addMethod(deviceClass, @selector(isFlashModeSupported:), (IMP)fauxDeviceModeSupported, "B@:q");
    class_addMethod(deviceClass, @selector(isFocusModeSupported:), (IMP)fauxDeviceModeSupported, "B@:q");
    class_addMethod(deviceClass, @selector(isExposureModeSupported:), (IMP)fauxDeviceModeSupported, "B@:q");
    class_addMethod(deviceClass, @selector(isWhiteBalanceModeSupported:), (IMP)fauxDeviceModeSupported, "B@:q");
    class_addMethod(deviceClass, @selector(setTorchMode:), (IMP)fauxDeviceSetIntegerNoop, "v@:q");
    class_addMethod(deviceClass, @selector(setTorchModeOnWithLevel:error:), (IMP)fauxDeviceSetTorchModeOnWithLevel, "B@:f^@");
    class_addMethod(deviceClass, @selector(torchMode), (IMP)fauxDeviceIntegerZero, "q@:");
    class_addMethod(deviceClass, @selector(torchLevel), (IMP)fauxDeviceFloatZero, "f@:");
    class_addMethod(deviceClass, @selector(focusMode), (IMP)fauxDeviceIntegerZero, "q@:");
    class_addMethod(deviceClass, @selector(setFocusMode:), (IMP)fauxDeviceSetIntegerNoop, "v@:q");
    class_addMethod(deviceClass, @selector(exposureMode), (IMP)fauxDeviceIntegerZero, "q@:");
    class_addMethod(deviceClass, @selector(setExposureMode:), (IMP)fauxDeviceSetIntegerNoop, "v@:q");
    class_addMethod(deviceClass, @selector(whiteBalanceMode), (IMP)fauxDeviceIntegerZero, "q@:");
    class_addMethod(deviceClass, @selector(setWhiteBalanceMode:), (IMP)fauxDeviceSetIntegerNoop, "v@:q");
    class_addMethod(deviceClass, @selector(videoZoomFactor), (IMP)fauxDeviceZoomOne, "d@:");
    class_addMethod(deviceClass, @selector(setVideoZoomFactor:), (IMP)fauxDeviceSetZoom, "v@:d");
    class_addMethod(deviceClass, @selector(minAvailableVideoZoomFactor), (IMP)fauxDeviceZoomOne, "d@:");
    class_addMethod(deviceClass, @selector(maxAvailableVideoZoomFactor), (IMP)fauxDeviceZoomOne, "d@:");
    class_addMethod(deviceClass, @selector(setActiveFormat:), (IMP)fauxDeviceSetObjectNoop, "v@:@");
    class_addMethod(deviceClass, @selector(activeVideoMinFrameDuration), (IMP)fauxDeviceFrameDuration, cmTimeGet.UTF8String);
    class_addMethod(deviceClass, @selector(setActiveVideoMinFrameDuration:), (IMP)fauxDeviceSetFrameDuration, cmTimeSet.UTF8String);
    class_addMethod(deviceClass, @selector(activeVideoMaxFrameDuration), (IMP)fauxDeviceFrameDuration, cmTimeGet.UTF8String);
    class_addMethod(deviceClass, @selector(setActiveVideoMaxFrameDuration:), (IMP)fauxDeviceSetFrameDuration, cmTimeSet.UTF8String);
    class_addMethod(deviceClass, @selector(isRampingVideoZoom), (IMP)fauxDeviceBoolNo, "B@:");
    NSString *ptGet = [NSString stringWithFormat:@"%s@:", @encode(CGPoint)];
    NSString *ptSet = [NSString stringWithFormat:@"v@:%s", @encode(CGPoint)];
    class_addMethod(deviceClass, @selector(exposureDuration), (IMP)fauxDeviceFrameDuration, cmTimeGet.UTF8String);
    class_addMethod(deviceClass, @selector(minExposureDuration), (IMP)fauxDeviceMinExposure, cmTimeGet.UTF8String);
    class_addMethod(deviceClass, @selector(maxExposureDuration), (IMP)fauxDeviceMaxExposure, cmTimeGet.UTF8String);
    class_addMethod(deviceClass, @selector(ISO), (IMP)fauxDeviceFloatHundred, "f@:");
    class_addMethod(deviceClass, @selector(lensAperture), (IMP)fauxDeviceFloatTwo, "f@:");
    class_addMethod(deviceClass, @selector(lensPosition), (IMP)fauxDeviceFloatZero, "f@:");
    class_addMethod(deviceClass, @selector(exposureTargetOffset), (IMP)fauxDeviceFloatZero, "f@:");
    class_addMethod(deviceClass, @selector(exposureTargetBias), (IMP)fauxDeviceFloatZero, "f@:");
    class_addMethod(deviceClass, @selector(minExposureTargetBias), (IMP)fauxDeviceFloatZero, "f@:");
    class_addMethod(deviceClass, @selector(maxExposureTargetBias), (IMP)fauxDeviceFloatZero, "f@:");
    class_addMethod(deviceClass, @selector(focusPointOfInterest), (IMP)fauxDevicePointCenter, ptGet.UTF8String);
    class_addMethod(deviceClass, @selector(setFocusPointOfInterest:), (IMP)fauxDeviceSetPoint, ptSet.UTF8String);
    class_addMethod(deviceClass, @selector(isFocusPointOfInterestSupported), (IMP)fauxDeviceBoolNo, "B@:");
    class_addMethod(deviceClass, @selector(exposurePointOfInterest), (IMP)fauxDevicePointCenter, ptGet.UTF8String);
    class_addMethod(deviceClass, @selector(setExposurePointOfInterest:), (IMP)fauxDeviceSetPoint, ptSet.UTF8String);
    class_addMethod(deviceClass, @selector(isExposurePointOfInterestSupported), (IMP)fauxDeviceBoolNo, "B@:");
    class_addMethod(deviceClass, @selector(activeColorSpace), (IMP)fauxDeviceIntegerZero, "q@:");
    class_addMethod(deviceClass, @selector(setActiveColorSpace:), (IMP)fauxDeviceSetIntegerNoop, "v@:q");
    class_addMethod(deviceClass, @selector(isVirtualDevice), (IMP)fauxDeviceBoolNo, "B@:");
    class_addMethod(deviceClass, @selector(constituentDevices), (IMP)fauxDeviceEmptyArray, "@@:");
    class_addMethod(deviceClass, @selector(isSubjectAreaChangeMonitoringEnabled), (IMP)fauxDeviceBoolNo, "B@:");
    class_addMethod(deviceClass, @selector(setSubjectAreaChangeMonitoringEnabled:), (IMP)fauxDeviceSetBoolNoop, "v@:B");
    class_addMethod(deviceClass, @selector(isLowLightBoostSupported), (IMP)fauxDeviceBoolNo, "B@:");
    class_addMethod(deviceClass, @selector(isLowLightBoostEnabled), (IMP)fauxDeviceBoolNo, "B@:");
    class_addMethod(deviceClass, @selector(automaticallyEnablesLowLightBoostWhenAvailable), (IMP)fauxDeviceBoolNo, "B@:");
    class_addMethod(deviceClass, @selector(setAutomaticallyEnablesLowLightBoostWhenAvailable:), (IMP)fauxDeviceSetBoolNoop, "v@:B");
    class_addMethod(deviceClass, @selector(isSmoothAutoFocusSupported), (IMP)fauxDeviceBoolNo, "B@:");
    class_addMethod(deviceClass, @selector(isAdjustingFocus), (IMP)fauxDeviceBoolNo, "B@:");
    class_addMethod(deviceClass, @selector(isAdjustingExposure), (IMP)fauxDeviceBoolNo, "B@:");
    class_addMethod(deviceClass, @selector(isAdjustingWhiteBalance), (IMP)fauxDeviceBoolNo, "B@:");
}

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
    fauxAddDeviceConfigMethods(deviceClass);
    objc_registerClassPair(deviceClass);
    fauxAVInstallNet(deviceClass);
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

static const void *kDiscoveryPositionKey = &kDiscoveryPositionKey;
static IMP fauxOriginalDiscoveryFactory;

static id fauxDiscoverySessionDevices(id self, SEL _cmd) {
    NSNumber *pos = objc_getAssociatedObject(self, kDiscoveryPositionKey);
    if (!pos || pos.integerValue == kFauxPositionUnspecified) return fauxAllDevices();
    fauxBuildDevices();
    if (pos.integerValue == kFauxPositionFront) return fauxFrontDevice ? @[fauxFrontDevice] : @[];
    if (pos.integerValue == kFauxPositionBack) return fauxBackDevice ? @[fauxBackDevice] : @[];
    return fauxAllDevices();
}

// Honor the position filter passed to the discovery-session factory.
static id fauxDiscoveryFactory(id self, SEL _cmd, NSArray *deviceTypes, NSString *mediaType, NSInteger position) {
    id session = nil;
    if (fauxOriginalDiscoveryFactory) {
        session = ((id (*)(id, SEL, NSArray *, NSString *, NSInteger))fauxOriginalDiscoveryFactory)(self, _cmd, deviceTypes, mediaType, position);
    }
    if (session) objc_setAssociatedObject(session, kDiscoveryPositionKey, @(position), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return session;
}

static id fauxDeviceWithUniqueID(id self, SEL _cmd, NSString *uniqueID) {
    fauxBuildDevices();
    if ([uniqueID isEqualToString:kFauxBackUniqueID]) return fauxBackDevice;
    if ([uniqueID isEqualToString:kFauxFrontUniqueID]) return fauxFrontDevice;
    if (fauxOriginalDeviceWithUniqueID) {
        return ((id (*)(id, SEL, NSString *))fauxOriginalDeviceWithUniqueID)(self, _cmd, uniqueID);
    }
    return nil;
}

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

static id fauxDefaultDeviceWithMediaType(id self, SEL _cmd, NSString *mediaType) {
    os_log(fauxLog(), "defaultDeviceWithMediaType:%{public}@ video=%d", mediaType, fauxIsVideoMediaType(mediaType) ? 1 : 0);
    if (fauxIsVideoMediaType(mediaType)) {
        fauxBuildDevices();
        return fauxBackDevice;
    }
    if (fauxOriginalDefaultDeviceWithMediaType) {
        return ((id (*)(id, SEL, NSString *))fauxOriginalDefaultDeviceWithMediaType)(self, _cmd, mediaType);
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
    fauxOriginalDiscoveryFactory = fauxOriginalClassMethodImplementation(sessionClass, @selector(discoverySessionWithDeviceTypes:mediaType:position:));
    fauxReplaceClassMethod(sessionClass, @selector(discoverySessionWithDeviceTypes:mediaType:position:), (IMP)fauxDiscoveryFactory, "@@:@@q");
}

static void fauxInstallDeviceClassSwizzle(void) {
    Class deviceClass = objc_getClass("AVCaptureDevice");
    if (!deviceClass) {
        os_log_error(fauxLog(), "missing AVCaptureDevice");
        return;
    }
    fauxOriginalDefaultDevice = fauxOriginalClassMethodImplementation(deviceClass, @selector(defaultDeviceWithDeviceType:mediaType:position:));
    fauxOriginalDefaultDeviceWithMediaType = fauxOriginalClassMethodImplementation(deviceClass, @selector(defaultDeviceWithMediaType:));
    fauxOriginalDevices = fauxOriginalClassMethodImplementation(deviceClass, @selector(devices));
    fauxOriginalDevicesWithMediaType = fauxOriginalClassMethodImplementation(deviceClass, @selector(devicesWithMediaType:));
    fauxOriginalAuthorizationStatus = fauxOriginalClassMethodImplementation(deviceClass, @selector(authorizationStatusForMediaType:));
    fauxOriginalRequestAccess = fauxOriginalClassMethodImplementation(deviceClass, @selector(requestAccessForMediaType:completionHandler:));

    fauxReplaceClassMethod(deviceClass, @selector(defaultDeviceWithDeviceType:mediaType:position:), (IMP)fauxDefaultDevice, "@@:@@q");
    fauxReplaceClassMethod(deviceClass, @selector(defaultDeviceWithMediaType:), (IMP)fauxDefaultDeviceWithMediaType, "@@:@");
    fauxReplaceClassMethod(deviceClass, @selector(devicesWithMediaType:), (IMP)fauxDevicesWithMediaType, "@@:@");
    fauxReplaceClassMethod(deviceClass, @selector(devices), (IMP)fauxDevices, "@@:");
    fauxReplaceClassMethod(deviceClass, @selector(authorizationStatusForMediaType:), (IMP)fauxAuthorizationStatus, "q@:@");
    fauxReplaceClassMethod(deviceClass, @selector(requestAccessForMediaType:completionHandler:), (IMP)fauxRequestAccess, "v@:@@?");
    fauxOriginalDeviceWithUniqueID = fauxOriginalClassMethodImplementation(deviceClass, @selector(deviceWithUniqueID:));
    fauxReplaceClassMethod(deviceClass, @selector(deviceWithUniqueID:), (IMP)fauxDeviceWithUniqueID, "@@:@");
}

// Success-gated so the dyld add-image retry can install once AVFoundation loads (lazy in
// Flutter/Unity). dyld serializes image-load callbacks, so no lock is needed.
void FauxInstallCameraDiscovery(void) {
    static BOOL sInstalled = NO;
    if (sInstalled) return;
    if (!objc_getClass("AVCaptureDevice")) return;
    fauxBuildDevices();
    fauxInstallDiscoverySwizzle();
    fauxInstallDeviceClassSwizzle();
    os_log(fauxLog(), "camera discovery installed devices=%lu", (unsigned long)fauxAllDevices().count);
    sInstalled = YES;
}
