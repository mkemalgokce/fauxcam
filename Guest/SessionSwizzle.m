#include "SessionSwizzle.h"
#include "AVSwizzle.h"
#include "FrameClient.h"
#include "FauxConfig.h"
#import "FauxBufferFactory.h"

@import Foundation;
@import ObjectiveC.runtime;
@import ObjectiveC.message;
@import os.log;
@import AVFoundation;
@import CoreMedia;
@import CoreImage;
@import QuartzCore;

static const uint8_t kSourcePixelBlue = 255;
static const uint8_t kSourcePixelGreen = 0;
static const uint8_t kSourcePixelRed = 255;
static const uint8_t kSourcePixelAlpha = 255;

static const void *kSessionPumpKey = &kSessionPumpKey;
static const void *kFakeInputDeviceKey = &kFakeInputDeviceKey;
static const void *kOutputDelegateKey = &kOutputDelegateKey;
static const void *kOutputQueueKey = &kOutputQueueKey;
static const void *kSessionPreviewLayersKey = &kSessionPreviewLayersKey;
static const void *kMetadataDelegateKey = &kMetadataDelegateKey;
static const void *kMetadataQueueKey = &kMetadataQueueKey;
static const void *kMetadataPumpKey = &kMetadataPumpKey;
static const void *kPhotoPumpKey = &kPhotoPumpKey;
static const void *kVideoPumpKey = &kVideoPumpKey;
static const void *kVideoFormatKey = &kVideoFormatKey;
static const void *kVideoSettingsKey = &kVideoSettingsKey;
static const void *kSessionPresetKey = &kSessionPresetKey;
static const void *kMetadataTypesKey = &kMetadataTypesKey;
static const void *kSessionInputsKey = &kSessionInputsKey;
static const void *kSessionOutputsKey = &kSessionOutputsKey;
static const void *kSessionRunningKey = &kSessionRunningKey;

// Installs a benign forwardInvocation/methodSignatureForSelector net on a fake class so any
// selector with no IMP anywhere resolves to a nil/zero return instead of crashing. Defined later.
static void fauxInstallForwardingNet(Class cls);

static IMP fauxNSObjectInit;
static IMP fauxOriginalInputInit;
static IMP fauxOriginalInputPorts;
static IMP fauxOriginalPreviewSetSession;
static IMP fauxOriginalPreviewSetSessionNoConn;
static IMP fauxOriginalPreviewInitWithSession;

static os_log_t fauxSessionLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.fauxcam", "session"); });
    return log;
}

// MARK: - Preview target

/// Displays the pump's frames over an app-owned AVCaptureVideoPreviewLayer by overlaying
/// an AVSampleBufferDisplayLayer, so preview-only apps (no AVCaptureVideoDataOutput) see frames.
@interface FauxPreviewTarget : NSObject
@property (nonatomic, weak) CALayer *previewLayer;
@property (nonatomic, strong) AVSampleBufferDisplayLayer *displayLayer;
- (instancetype)initWithPreviewLayer:(CALayer *)previewLayer;
- (void)enqueue:(CMSampleBufferRef)sampleBuffer mirrored:(BOOL)mirrored;
@end

@implementation FauxPreviewTarget
- (instancetype)initWithPreviewLayer:(CALayer *)previewLayer {
    self = [super init];
    if (self) {
        _previewLayer = previewLayer;
        _displayLayer = [[AVSampleBufferDisplayLayer alloc] init];
        _displayLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    }
    return self;
}

- (void)enqueue:(CMSampleBufferRef)sampleBuffer mirrored:(BOOL)mirrored {
    CALayer *preview = self.previewLayer;
    if (!preview) return;
    if (CGRectIsEmpty(preview.bounds)) return; // layout not done yet — don't enqueue into a zero rect
    if (self.displayLayer.superlayer != preview) {
        [preview addSublayer:self.displayLayer];
    }
    self.displayLayer.frame = preview.bounds;
    self.displayLayer.transform = mirrored ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity;
    // Always ResizeAspectFill — the real-camera default. We now inject a true camera-aspect (4:3) feed,
    // so filling the app's preview bounds matches a physical camera regardless of the app's own gravity.
    // (Don't adopt the app's gravity: that made the result depend on app-specific preview config.)
    if (self.displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        [self.displayLayer flush];
    }
    if (!self.displayLayer.isReadyForMoreMediaData) return;
    [self.displayLayer enqueueSampleBuffer:sampleBuffer];
}
@end

// MARK: - Fake metadata object (machine-readable code)

static const void *kMetadataStringKey = &kMetadataStringKey;

static NSString *fauxMetadataStringValue(id self, SEL _cmd) { return objc_getAssociatedObject(self, kMetadataStringKey); }
static AVMetadataObjectType fauxMetadataType(id self, SEL _cmd) { return AVMetadataObjectTypeQRCode; }
static CGRect fauxMetadataBounds(id self, SEL _cmd) { return CGRectMake(0.25, 0.25, 0.5, 0.5); }
static NSArray *fauxMetadataCorners(id self, SEL _cmd) {
    return @[ @{@"X": @0.25, @"Y": @0.25}, @{@"X": @0.75, @"Y": @0.25}, @{@"X": @0.75, @"Y": @0.75}, @{@"X": @0.25, @"Y": @0.75} ];
}
static CMTime fauxMetadataTime(id self, SEL _cmd) { return CMClockGetTime(CMClockGetHostTimeClock()); }
static CMTime fauxMetadataDuration(id self, SEL _cmd) { return kCMTimeZero; }
static NSString *fauxMetadataDescription(id self, SEL _cmd) {
    return [NSString stringWithFormat:@"<FauxMetadataObject %@>", objc_getAssociatedObject(self, kMetadataStringKey)];
}

static Class fauxMetadataObjectClass(void) {
    static Class metadataClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class superClass = objc_getClass("AVMetadataMachineReadableCodeObject");
        if (!superClass) return;
        metadataClass = objc_allocateClassPair(superClass, "FauxMetadataMachineReadableCodeObject", 0);
        if (!metadataClass) return;
        NSString *rectTypes = [NSString stringWithFormat:@"%s@:", @encode(CGRect)];
        NSString *timeTypes = [NSString stringWithFormat:@"%s@:", @encode(CMTime)];
        class_addMethod(metadataClass, @selector(stringValue), (IMP)fauxMetadataStringValue, "@@:");
        class_addMethod(metadataClass, @selector(type), (IMP)fauxMetadataType, "@@:");
        class_addMethod(metadataClass, @selector(bounds), (IMP)fauxMetadataBounds, rectTypes.UTF8String);
        class_addMethod(metadataClass, @selector(corners), (IMP)fauxMetadataCorners, "@@:");
        class_addMethod(metadataClass, @selector(time), (IMP)fauxMetadataTime, timeTypes.UTF8String);
        class_addMethod(metadataClass, @selector(duration), (IMP)fauxMetadataDuration, timeTypes.UTF8String);
        class_addMethod(metadataClass, @selector(description), (IMP)fauxMetadataDescription, "@@:");
        objc_registerClassPair(metadataClass);
        fauxInstallForwardingNet(metadataClass);
    });
    return metadataClass;
}

static id fauxMakeMetadataObject(NSString *string) {
    Class metadataClass = fauxMetadataObjectClass();
    if (!metadataClass) return nil;
    id object = class_createInstance(metadataClass, 0);
    objc_setAssociatedObject(object, kMetadataStringKey, string, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return object;
}

static CIDetector *fauxQRDetector(void) {
    static CIDetector *detector;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        detector = [CIDetector detectorOfType:CIDetectorTypeQRCode context:nil
                                      options:@{ CIDetectorAccuracy: CIDetectorAccuracyLow }];
    });
    return detector;
}

@interface FauxMetadataTarget : NSObject
@property (nonatomic, weak) id delegate;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) id output;
@property (nonatomic, strong) id connection;
@end
@implementation FauxMetadataTarget
@end

// MARK: - Fake photo (AVCapturePhotoOutput)

static const void *kPhotoUniqueIDKey = &kPhotoUniqueIDKey;
static const void *kPhotoDimensionsWidthKey = &kPhotoDimensionsWidthKey;
static const void *kPhotoDimensionsHeightKey = &kPhotoDimensionsHeightKey;
static const void *kPhotoFileDataKey = &kPhotoFileDataKey;
static const void *kPhotoPixelBufferKey = &kPhotoPixelBufferKey;
static const void *kPhotoResolvedSettingsKey = &kPhotoResolvedSettingsKey;

static int64_t fauxResolvedUniqueID(id self, SEL _cmd) {
    return [objc_getAssociatedObject(self, kPhotoUniqueIDKey) longLongValue];
}
static CMVideoDimensions fauxResolvedPhotoDimensions(id self, SEL _cmd) {
    CMVideoDimensions dimensions;
    dimensions.width = [objc_getAssociatedObject(self, kPhotoDimensionsWidthKey) intValue];
    dimensions.height = [objc_getAssociatedObject(self, kPhotoDimensionsHeightKey) intValue];
    return dimensions;
}
static CMVideoDimensions fauxResolvedZeroDimensions(id self, SEL _cmd) {
    CMVideoDimensions dimensions = { 0, 0 };
    return dimensions;
}

// Benign answers for the getters real apps read on the fake result objects, so an
// unhandled selector never reaches the real superclass IMP over the zeroed `_internal` ivar.
static id fauxFakeNilObject(id self, SEL _cmd) { return nil; }
static id fauxFakeEmptyDictionary(id self, SEL _cmd) { return @{}; }
static NSInteger fauxFakeIntegerOne(id self, SEL _cmd) { return 1; }
static NSInteger fauxFakeIntegerZero(id self, SEL _cmd) { return 0; }
static BOOL fauxFakeBoolNo(id self, SEL _cmd) { return NO; }
static void *fauxFakeNullPointer(id self, SEL _cmd) { return NULL; }
static CMTime fauxFakeHostTime(id self, SEL _cmd) { return CMClockGetTime(CMClockGetHostTimeClock()); }
static CMTimeRange fauxFakeZeroTimeRange(id self, SEL _cmd) { return kCMTimeRangeZero; }
static NSString *fauxFakePhotoCodec(id self, SEL _cmd) { return AVVideoCodecTypeJPEG; }
static NSString *fauxResolvedDescriptionText(id self, SEL _cmd) { return @"<FauxResolvedPhotoSettings>"; }
static NSString *fauxPhotoDescriptionText(id self, SEL _cmd) { return @"<FauxCapturePhoto>"; }

static id fauxMakeResolvedSettings(int64_t uniqueID, int32_t width, int32_t height) {
    static Class settingsClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class superClass = objc_getClass("AVCaptureResolvedPhotoSettings");
        if (!superClass) return;
        settingsClass = objc_allocateClassPair(superClass, "FauxResolvedPhotoSettings", 0);
        if (!settingsClass) return;
        NSString *dimsTypes = [NSString stringWithFormat:@"%s@:", @encode(CMVideoDimensions)];
        NSString *timeRangeTypes = [NSString stringWithFormat:@"%s@:", @encode(CMTimeRange)];
        class_addMethod(settingsClass, @selector(uniqueID), (IMP)fauxResolvedUniqueID, "q@:");
        class_addMethod(settingsClass, @selector(photoDimensions), (IMP)fauxResolvedPhotoDimensions, dimsTypes.UTF8String);
        class_addMethod(settingsClass, @selector(previewDimensions), (IMP)fauxResolvedZeroDimensions, dimsTypes.UTF8String);
        class_addMethod(settingsClass, @selector(livePhotoMovieDimensions), (IMP)fauxResolvedZeroDimensions, dimsTypes.UTF8String);
        class_addMethod(settingsClass, @selector(embeddedThumbnailDimensions), (IMP)fauxResolvedZeroDimensions, dimsTypes.UTF8String);
        class_addMethod(settingsClass, @selector(rawPhotoDimensions), (IMP)fauxResolvedZeroDimensions, dimsTypes.UTF8String);
        class_addMethod(settingsClass, @selector(photoProcessingTimeRange), (IMP)fauxFakeZeroTimeRange, timeRangeTypes.UTF8String);
        class_addMethod(settingsClass, @selector(expectedPhotoCount), (IMP)fauxFakeIntegerOne, "q@:");
        class_addMethod(settingsClass, @selector(photoCodecType), (IMP)fauxFakePhotoCodec, "@@:");
        class_addMethod(settingsClass, @selector(isFlashEnabled), (IMP)fauxFakeBoolNo, "B@:");
        class_addMethod(settingsClass, @selector(isStillImageStabilizationEnabled), (IMP)fauxFakeBoolNo, "B@:");
        class_addMethod(settingsClass, @selector(isRedEyeReductionEnabled), (IMP)fauxFakeBoolNo, "B@:");
        class_addMethod(settingsClass, @selector(description), (IMP)fauxResolvedDescriptionText, "@@:");
        objc_registerClassPair(settingsClass);
        fauxInstallForwardingNet(settingsClass);
    });
    if (!settingsClass) return nil;
    id settings = class_createInstance(settingsClass, 0);
    objc_setAssociatedObject(settings, kPhotoUniqueIDKey, @(uniqueID), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(settings, kPhotoDimensionsWidthKey, @(width), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(settings, kPhotoDimensionsHeightKey, @(height), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return settings;
}

static NSData *fauxPhotoFileDataRepresentation(id self, SEL _cmd) {
    return objc_getAssociatedObject(self, kPhotoFileDataKey);
}
static CVPixelBufferRef fauxPhotoPixelBuffer(id self, SEL _cmd) {
    return (__bridge CVPixelBufferRef)objc_getAssociatedObject(self, kPhotoPixelBufferKey);
}
static id fauxPhotoResolvedSettings(id self, SEL _cmd) {
    return objc_getAssociatedObject(self, kPhotoResolvedSettingsKey);
}
static CGImageRef fauxPhotoCGImageRepresentation(id self, SEL _cmd) {
    CVPixelBufferRef buffer = (__bridge CVPixelBufferRef)objc_getAssociatedObject(self, kPhotoPixelBufferKey);
    if (!buffer) return NULL;
    static CIContext *context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ context = [CIContext context]; });
    CIImage *image = [CIImage imageWithCVPixelBuffer:buffer];
    return (CGImageRef)CFAutorelease([context createCGImage:image fromRect:image.extent]);
}

static NSData *fauxJPEGFromPixelBuffer(CVPixelBufferRef buffer) {
    if (!buffer) return nil;
    static CIContext *context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ context = [CIContext context]; });
    CIImage *image = [CIImage imageWithCVPixelBuffer:buffer];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    NSData *data = [context JPEGRepresentationOfImage:image colorSpace:colorSpace options:@{}];
    CGColorSpaceRelease(colorSpace);
    return data;
}

static id fauxMakePhoto(CVPixelBufferRef buffer, id resolvedSettings) {
    static Class photoClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class superClass = objc_getClass("AVCapturePhoto");
        if (!superClass) return;
        photoClass = objc_allocateClassPair(superClass, "FauxCapturePhoto", 0);
        if (!photoClass) return;
        NSString *timeTypes = [NSString stringWithFormat:@"%s@:", @encode(CMTime)];
        class_addMethod(photoClass, @selector(fileDataRepresentation), (IMP)fauxPhotoFileDataRepresentation, "@@:");
        class_addMethod(photoClass, @selector(pixelBuffer), (IMP)fauxPhotoPixelBuffer, "^{__CVBuffer=}@:");
        class_addMethod(photoClass, @selector(CGImageRepresentation), (IMP)fauxPhotoCGImageRepresentation, "^{CGImage=}@:");
        class_addMethod(photoClass, @selector(resolvedSettings), (IMP)fauxPhotoResolvedSettings, "@@:");
        class_addMethod(photoClass, @selector(metadata), (IMP)fauxFakeEmptyDictionary, "@@:");
        class_addMethod(photoClass, @selector(timestamp), (IMP)fauxFakeHostTime, timeTypes.UTF8String);
        class_addMethod(photoClass, @selector(depthData), (IMP)fauxFakeNilObject, "@@:");
        class_addMethod(photoClass, @selector(previewPixelBuffer), (IMP)fauxFakeNullPointer, "^{__CVBuffer=}@:");
        class_addMethod(photoClass, @selector(portraitEffectsMatte), (IMP)fauxFakeNilObject, "@@:");
        class_addMethod(photoClass, @selector(cameraCalibrationData), (IMP)fauxFakeNilObject, "@@:");
        class_addMethod(photoClass, @selector(embeddedThumbnailPhotoFormat), (IMP)fauxFakeNilObject, "@@:");
        class_addMethod(photoClass, @selector(photoCount), (IMP)fauxFakeIntegerOne, "q@:");
        class_addMethod(photoClass, @selector(sequenceCount), (IMP)fauxFakeIntegerOne, "q@:");
        class_addMethod(photoClass, @selector(isRawPhoto), (IMP)fauxFakeBoolNo, "B@:");
        class_addMethod(photoClass, @selector(description), (IMP)fauxPhotoDescriptionText, "@@:");
        objc_registerClassPair(photoClass);
        fauxInstallForwardingNet(photoClass);
    });
    if (!photoClass) return nil;
    id photo = class_createInstance(photoClass, 0);
    objc_setAssociatedObject(photo, kPhotoFileDataKey, fauxJPEGFromPixelBuffer(buffer), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(photo, kPhotoPixelBufferKey, (__bridge id)buffer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(photo, kPhotoResolvedSettingsKey, resolvedSettings, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return photo;
}

// MARK: - Frame pump

@interface FauxFramePump : NSObject
@property (nonatomic, weak) id sampleBufferDelegate;
@property (nonatomic, strong) dispatch_queue_t deliveryQueue;
@property (nonatomic, strong) id captureOutput;
@property (nonatomic, strong) id captureConnection;
@property (nonatomic) BOOL frontCamera;
@property (nonatomic) OSType requestedPixelFormat; // 0 = BGRA default
- (void)start;
- (void)startIfReady;
- (void)stop;
- (void)registerPreviewLayer:(CALayer *)previewLayer;
- (void)registerMetadataDelegate:(id)delegate queue:(dispatch_queue_t)queue output:(id)output connection:(id)connection;
- (void)markPhotoConsumer;
- (void)detachOutput:(id)output;
- (CVPixelBufferRef)copyLatestImageBuffer CF_RETURNS_RETAINED;
@end

@implementation FauxFramePump {
    dispatch_source_t _timer;
    dispatch_queue_t _pumpQueue;
    FauxBufferFactory *_bufferFactory;
    uint8_t *_sourcePixels;
    size_t _sourceBytesPerRow;
    uint32_t _sequence;
    faux_frame_client *_frameClient;
    BOOL _usesHostSocket;
    int _hostFailures;
    BOOL _startRequested;
    BOOL _loggedPreviewDelivery;
    BOOL _loggedMetadataDelivery;
    BOOL _hasPhotoConsumer;
    int32_t _frameWidth;
    int32_t _frameHeight;
    int32_t _framesPerSecond;
    CVPixelBufferRef _latestImageBuffer;
    NSMutableArray<FauxPreviewTarget *> *_previewTargets;
    NSMutableArray<FauxMetadataTarget *> *_metadataTargets;
}

// All native pump state (_sourcePixels, _frameClient, _bufferFactory, _timer, frame dims) is
// mutated and read ONLY on _pumpQueue, which is created eagerly so start/stop/deliver can never
// race on it. Consumer arrays use @synchronized(self). _latestImageBuffer uses @synchronized(self)
// because photo capture pulls it from an unrelated background queue.
- (instancetype)init {
    self = [super init];
    if (self) {
        _pumpQueue = dispatch_queue_create("com.fauxcam.pump", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)registerPreviewLayer:(CALayer *)previewLayer {
    if (!previewLayer) return;
    @synchronized(self) {
        if (!_previewTargets) _previewTargets = [NSMutableArray array];
        for (FauxPreviewTarget *target in _previewTargets) {
            if (target.previewLayer == previewLayer) return;
        }
        [_previewTargets addObject:[[FauxPreviewTarget alloc] initWithPreviewLayer:previewLayer]];
        os_log(fauxSessionLog(), "preview layer registered total=%lu", (unsigned long)_previewTargets.count);
    }
    [self startIfReady];
}

- (void)registerMetadataDelegate:(id)delegate queue:(dispatch_queue_t)queue output:(id)output connection:(id)connection {
    if (!delegate || !queue) return;
    @synchronized(self) {
        if (!_metadataTargets) _metadataTargets = [NSMutableArray array];
        for (FauxMetadataTarget *existing in _metadataTargets) {
            if (existing.delegate == delegate) return;
        }
        FauxMetadataTarget *target = [[FauxMetadataTarget alloc] init];
        target.delegate = delegate;
        target.queue = queue;
        target.output = output;
        target.connection = connection;
        [_metadataTargets addObject:target];
        os_log(fauxSessionLog(), "metadata delegate registered");
    }
    [self startIfReady];
}

// Detach a removed output so the pump stops feeding it (camera-switch / remove-readd flows).
- (void)detachOutput:(id)output {
    if (!output) return;
    @synchronized(self) {
        if (self.captureOutput == output) {
            self.captureOutput = nil;
            self.sampleBufferDelegate = nil;
            self.deliveryQueue = nil;
        }
        if (_metadataTargets.count) {
            NSMutableArray *keep = [NSMutableArray array];
            for (FauxMetadataTarget *t in _metadataTargets) {
                if (t.output != output) [keep addObject:t];
            }
            _metadataTargets = keep;
        }
    }
}

- (void)markPhotoConsumer {
    dispatch_async(_pumpQueue, ^{
        self->_hasPhotoConsumer = YES;
        [self startOnQueueIfReady];
    });
}

- (BOOL)hasConsumer {
    if ((self.sampleBufferDelegate && self.deliveryQueue) || _hasPhotoConsumer) return YES;
    @synchronized(self) { return _previewTargets.count > 0 || _metadataTargets.count > 0; }
}

- (void)scanMetadataIfNeeded {
    if (_sequence % 6 != 0) return;
    NSArray<FauxMetadataTarget *> *targets;
    @synchronized(self) {
        if (_metadataTargets.count == 0) return;
        targets = [_metadataTargets copy];
    }
    CVPixelBufferRef buffer = [self copyLatestImageBuffer];
    if (!buffer) return;
    NSArray *features = [fauxQRDetector() featuresInImage:[CIImage imageWithCVPixelBuffer:buffer]];
    CVPixelBufferRelease(buffer);

    NSMutableArray *objects = [NSMutableArray array];
    for (CIQRCodeFeature *feature in features) {
        if (feature.messageString.length == 0) continue;
        id metadataObject = fauxMakeMetadataObject(feature.messageString);
        if (metadataObject) [objects addObject:metadataObject];
    }
    if (objects.count == 0) return;
    if (!_loggedMetadataDelivery) {
        _loggedMetadataDelivery = YES;
        os_log(fauxSessionLog(), "metadata objects delivered count=%lu", (unsigned long)objects.count);
    }

    for (FauxMetadataTarget *target in targets) {
        id delegate = target.delegate;
        dispatch_queue_t queue = target.queue;
        id output = target.output;
        id connection = target.connection;
        if (!delegate || !queue) continue;
        dispatch_async(queue, ^{
            if ([delegate respondsToSelector:@selector(captureOutput:didOutputMetadataObjects:fromConnection:)]) {
                ((void (*)(id, SEL, id, NSArray *, id))objc_msgSend)(
                    delegate, @selector(captureOutput:didOutputMetadataObjects:fromConnection:),
                    output, objects, connection);
            }
        });
    }
}

- (void)start {
    dispatch_async(_pumpQueue, ^{
        self->_startRequested = YES;
        [self startOnQueueIfReady];
    });
}

- (void)startIfReady {
    dispatch_async(_pumpQueue, ^{ [self startOnQueueIfReady]; });
}

// Runs only on _pumpQueue, so it is serialized against deliverFrame and stop; no extra lock
// needed for _sourcePixels/_frameClient/_timer.
- (void)startOnQueueIfReady {
    if (_timer || !_startRequested || ![self hasConsumer]) return;

    if (_sourcePixels) { free(_sourcePixels); _sourcePixels = NULL; }
    if (_frameClient) { faux_frame_client_destroy(_frameClient); _frameClient = NULL; }
    _usesHostSocket = NO;
    _frameWidth = faux_config_width();
    _frameHeight = faux_config_height();
    _framesPerSecond = faux_config_fps();

    OSType outputFormat = self.requestedPixelFormat ?: kCVPixelFormatType_32BGRA;
    _bufferFactory = [[FauxBufferFactory alloc] initWithWidth:_frameWidth height:_frameHeight framesPerSecond:_framesPerSecond pixelFormat:outputFormat];
    if (!_bufferFactory) return;
    [self buildSourcePixels];
    [self connectHostSocket];

    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _pumpQueue);
    uint64_t interval = (uint64_t)NSEC_PER_SEC / (uint64_t)_framesPerSecond;
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0), interval, interval / 10);
    __weak FauxFramePump *weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf deliverFrame]; });
    dispatch_resume(_timer);
    os_log(fauxSessionLog(), "frame pump started %dx%d fps=%d", _frameWidth, _frameHeight, _framesPerSecond);
}

- (void)stop {
    NSArray<FauxPreviewTarget *> *targets;
    @synchronized(self) {
        targets = [_previewTargets copy];
        [_previewTargets removeAllObjects];
        [_metadataTargets removeAllObjects];
    }
    if (targets.count > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            for (FauxPreviewTarget *target in targets) {
                [target.displayLayer removeFromSuperlayer];
            }
        });
    }
    // Tear down native state on _pumpQueue so it serializes against deliverFrame/startOnQueueIfReady.
    dispatch_async(_pumpQueue, ^{
        self->_startRequested = NO;
        self->_hasPhotoConsumer = NO;
        if (self->_timer) {
            dispatch_source_cancel(self->_timer);
            self->_timer = nil;
        }
        if (self->_frameClient) {
            faux_frame_client_destroy(self->_frameClient);
            self->_frameClient = NULL;
        }
        @synchronized(self) {
            if (self->_latestImageBuffer) {
                CVPixelBufferRelease(self->_latestImageBuffer);
                self->_latestImageBuffer = NULL;
            }
        }
    });
}

- (void)buildSourcePixels {
    _sourceBytesPerRow = (size_t)_frameWidth * 4;
    size_t total = _sourceBytesPerRow * (size_t)_frameHeight;
    _sourcePixels = malloc(total);
    if (!_sourcePixels) return;
    for (size_t offset = 0; offset < total; offset += 4) {
        _sourcePixels[offset] = kSourcePixelBlue;
        _sourcePixels[offset + 1] = kSourcePixelGreen;
        _sourcePixels[offset + 2] = kSourcePixelRed;
        _sourcePixels[offset + 3] = kSourcePixelAlpha;
    }
}

- (void)connectHostSocket {
    // Tier A (per-app launch) sets FAUXCAM_SOCKET. Auto-mode injects via the LLDB stop-hook
    // with no env, so fall back to the shared auto-injection server's well-known socket.
    const char *socketPath = getenv("FAUXCAM_SOCKET");
    if (!socketPath || socketPath[0] == '\0') socketPath = FAUX_AUTO_SOCKET;
    _frameClient = faux_frame_client_create();
    if (_frameClient
        && faux_frame_client_connect(_frameClient, socketPath) == 0
        && faux_frame_client_send_hello(_frameClient) == 0) {
        _usesHostSocket = YES;
        os_log(fauxSessionLog(), "frame pump connected to host socket");
        return;
    }
    if (_frameClient) {
        faux_frame_client_destroy(_frameClient);
        _frameClient = NULL;
    }
    os_log(fauxSessionLog(), "frame pump host socket unavailable, using synthetic frames");
}

- (void)deliverFrame {
    if (_usesHostSocket) {
        [self deliverHostFrame];
    } else {
        [self deliverSyntheticFrame];
    }
}

// A single slow/missed host frame must NOT permanently kill host video; only give up after many
// consecutive failures (host really gone). Each failed tick still shows a synthetic frame.
- (void)hostFrameFailed {
    _hostFailures++;
    if (_hostFailures >= 30) {
        [self handleHostSocketFailure];
        _hostFailures = 0;
    }
    [self deliverSyntheticFrame];
}

- (void)deliverHostFrame {
    if (!_frameClient) { [self deliverSyntheticFrame]; return; }
    uint32_t position = self.frontCamera ? FAUX_POSITION_FRONT : FAUX_POSITION_BACK;
    if (faux_frame_client_send_demand(_frameClient, position, (uint32_t)_frameWidth, (uint32_t)_frameHeight, (uint32_t)_framesPerSecond, FAUX_PIXEL_FORMAT_BGRA32) != 0) {
        [self hostFrameFailed];
        return;
    }
    faux_received_frame received;
    if (faux_frame_client_recv_frame(_frameClient, &received) != 0) {
        [self hostFrameFailed];
        return;
    }
    _hostFailures = 0;
    CMSampleBufferRef sampleBuffer = NULL;
    if (received.payload) {
        sampleBuffer = [_bufferFactory newSampleBufferFromBGRABytes:received.payload
                                                 sourceBytesPerRow:received.header.bytesPerRow
                                                      sourceLength:received.header.payloadLen];
    }
    faux_received_frame_free(&received);
    if (sampleBuffer) {
        [self deliverSampleBuffer:sampleBuffer];
        CFRelease(sampleBuffer);
    }
}

- (void)deliverSyntheticFrame {
    if (!_sourcePixels) return;
    CMSampleBufferRef sampleBuffer = [_bufferFactory newSampleBufferFromBGRABytes:_sourcePixels
                                                               sourceBytesPerRow:_sourceBytesPerRow
                                                                    sourceLength:_sourceBytesPerRow * (size_t)_frameHeight];
    if (sampleBuffer) {
        [self deliverSampleBuffer:sampleBuffer];
        CFRelease(sampleBuffer);
    }
}

- (void)deliverSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    _sequence++;
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (imageBuffer) {
        @synchronized(self) {
            CVPixelBufferRef previous = _latestImageBuffer;
            _latestImageBuffer = (CVPixelBufferRef)CVPixelBufferRetain((CVPixelBufferRef)imageBuffer);
            if (previous) CVPixelBufferRelease(previous);
        }
    }
    NSArray<FauxPreviewTarget *> *previewTargets;
    @synchronized(self) {
        previewTargets = _previewTargets.count > 0 ? [_previewTargets copy] : nil;
    }
    if (previewTargets) {
        // Set the display-immediately attachment once on the pump thread, before any dispatch,
        // so the buffer shared with the data-output delegate is never mutated cross-queue.
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, YES);
        if (attachments && CFArrayGetCount(attachments) > 0) {
            CFMutableDictionaryRef attachment = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
            CFDictionarySetValue(attachment, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        }
    }

    // Consistent snapshot of the delivery quartet + mirroring under one lock; these are written
    // from setSampleBufferDelegate:queue:/addOutput: on the app's thread.
    id delegate, output, connection;
    dispatch_queue_t queue;
    BOOL mirrored;
    @synchronized(self) {
        delegate = self.sampleBufferDelegate;
        queue = self.deliveryQueue;
        output = self.captureOutput;
        connection = self.captureConnection;
        mirrored = self.frontCamera;
    }
    if (delegate && queue) {
        CFRetain(sampleBuffer);
        dispatch_async(queue, ^{
            ((void (*)(id, SEL, id, CMSampleBufferRef, id))objc_msgSend)(
                delegate, @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
                output, sampleBuffer, connection);
            CFRelease(sampleBuffer);
        });
    }

    if (previewTargets) [self deliverToPreviewLayers:sampleBuffer targets:previewTargets mirrored:mirrored];
    [self scanMetadataIfNeeded];
}

- (void)deliverToPreviewLayers:(CMSampleBufferRef)sampleBuffer targets:(NSArray<FauxPreviewTarget *> *)targets mirrored:(BOOL)mirrored {
    if (!_loggedPreviewDelivery) {
        _loggedPreviewDelivery = YES;
        os_log(fauxSessionLog(), "preview frame enqueued mirrored=%d", mirrored);
    }
    CFRetain(sampleBuffer);
    dispatch_async(dispatch_get_main_queue(), ^{
        for (FauxPreviewTarget *target in targets) {
            [target enqueue:sampleBuffer mirrored:mirrored];
        }
        CFRelease(sampleBuffer);
    });
}

- (void)handleHostSocketFailure {
    _usesHostSocket = NO;
    if (_frameClient) {
        faux_frame_client_destroy(_frameClient);
        _frameClient = NULL;
    }
    os_log(fauxSessionLog(), "host socket failed, falling back to synthetic frames");
}

- (CVPixelBufferRef)copyLatestImageBuffer CF_RETURNS_RETAINED {
    @synchronized(self) {
        return _latestImageBuffer ? (CVPixelBufferRef)CVPixelBufferRetain(_latestImageBuffer) : NULL;
    }
}

- (void)dealloc {
    // Refcount is 0: no other thread holds the pump, so tear down synchronously (no dispatch/[self stop]
    // which would resurrect self). The timer block holds only a weak ref.
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
    if (_sourcePixels) free(_sourcePixels);
    if (_frameClient) faux_frame_client_destroy(_frameClient);
    if (_latestImageBuffer) CVPixelBufferRelease(_latestImageBuffer);
}

@end

// MARK: - Pump lookup

static long fauxConnectionVideoOrientation(id self, SEL _cmd) { return 1; }
static BOOL fauxConnectionNo(id self, SEL _cmd) { return NO; }
static BOOL fauxConnectionYes(id self, SEL _cmd) { return YES; }
static BOOL fauxConnectionYesArg(id self, SEL _cmd, double arg) { return YES; }
static id fauxConnectionEmptyArray(id self, SEL _cmd) { return @[]; }
static id fauxConnectionNilObject(id self, SEL _cmd) { return nil; }
static double fauxConnectionZeroDouble(id self, SEL _cmd) { return 0; }
static long fauxConnectionZeroLong(id self, SEL _cmd) { return 0; }
static NSString *fauxConnectionDescription(id self, SEL _cmd) { return @"<FauxCaptureConnection>"; }
static void fauxConnectionSetLong(id self, SEL _cmd, long v) { }
static void fauxConnectionSetDouble(id self, SEL _cmd, double v) { }
static void fauxConnectionSetBool(id self, SEL _cmd, BOOL v) { }

static const void *kConnPreviewLayerKey = &kConnPreviewLayerKey;
static id fauxConnectionVideoPreviewLayer(id self, SEL _cmd) { return objc_getAssociatedObject(self, kConnPreviewLayerKey); }

// Safety net: any selector NOT explicitly overridden (and not a real-superclass method) resolves
// to a benign nil/zero return instead of crashing. (Inherited real methods still dispatch normally;
// the explicit overrides above cover the ones that touch zeroed internal ivars.)
static NSMethodSignature *fauxFwdMethodSignature(id self, SEL _cmd, SEL sel) {
    return [NSMethodSignature signatureWithObjCTypes:"@@:"];
}
static void fauxFwdInvocation(id self, SEL _cmd, NSInvocation *invocation) {
    id nilValue = nil;
    @try { [invocation setReturnValue:&nilValue]; } @catch (__unused id e) { }
}
static void fauxInstallForwardingNet(Class cls) {
    if (!cls) return;
    class_addMethod(cls, @selector(methodSignatureForSelector:), (IMP)fauxFwdMethodSignature, "@@::");
    class_addMethod(cls, @selector(forwardInvocation:), (IMP)fauxFwdInvocation, "v@:@");
}

static Class fauxConnectionClass(void) {
    static Class connectionClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class superClass = objc_getClass("AVCaptureConnection");
        if (!superClass) return;
        connectionClass = objc_getClass("FauxCaptureConnection");
        if (connectionClass) return;
        connectionClass = objc_allocateClassPair(superClass, "FauxCaptureConnection", 0);
        if (!connectionClass) return;
        class_addMethod(connectionClass, @selector(videoOrientation), (IMP)fauxConnectionVideoOrientation, "q@:");
        class_addMethod(connectionClass, @selector(setVideoOrientation:), (IMP)fauxConnectionSetLong, "v@:q");
        class_addMethod(connectionClass, @selector(isVideoOrientationSupported), (IMP)fauxConnectionYes, "B@:");
        class_addMethod(connectionClass, @selector(videoRotationAngle), (IMP)fauxConnectionZeroDouble, "d@:");
        class_addMethod(connectionClass, @selector(setVideoRotationAngle:), (IMP)fauxConnectionSetDouble, "v@:d");
        class_addMethod(connectionClass, @selector(isVideoRotationAngleSupported:), (IMP)fauxConnectionYesArg, "B@:d");
        class_addMethod(connectionClass, @selector(isVideoMirrored), (IMP)fauxConnectionNo, "B@:");
        class_addMethod(connectionClass, @selector(setVideoMirrored:), (IMP)fauxConnectionSetBool, "v@:B");
        class_addMethod(connectionClass, @selector(isVideoMirroringSupported), (IMP)fauxConnectionYes, "B@:");
        class_addMethod(connectionClass, @selector(automaticallyAdjustsVideoMirroring), (IMP)fauxConnectionNo, "B@:");
        class_addMethod(connectionClass, @selector(setAutomaticallyAdjustsVideoMirroring:), (IMP)fauxConnectionSetBool, "v@:B");
        class_addMethod(connectionClass, @selector(isEnabled), (IMP)fauxConnectionYes, "B@:");
        class_addMethod(connectionClass, @selector(setEnabled:), (IMP)fauxConnectionSetBool, "v@:B");
        class_addMethod(connectionClass, @selector(isActive), (IMP)fauxConnectionYes, "B@:");
        class_addMethod(connectionClass, @selector(preferredVideoStabilizationMode), (IMP)fauxConnectionZeroLong, "q@:");
        class_addMethod(connectionClass, @selector(setPreferredVideoStabilizationMode:), (IMP)fauxConnectionSetLong, "v@:q");
        class_addMethod(connectionClass, @selector(activeVideoStabilizationMode), (IMP)fauxConnectionZeroLong, "q@:");
        class_addMethod(connectionClass, @selector(videoScaleAndCropFactor), (IMP)fauxConnectionZeroDouble, "d@:");
        class_addMethod(connectionClass, @selector(setVideoScaleAndCropFactor:), (IMP)fauxConnectionSetDouble, "v@:d");
        class_addMethod(connectionClass, @selector(inputPorts), (IMP)fauxConnectionEmptyArray, "@@:");
        class_addMethod(connectionClass, @selector(output), (IMP)fauxConnectionNilObject, "@@:");
        class_addMethod(connectionClass, @selector(videoPreviewLayer), (IMP)fauxConnectionVideoPreviewLayer, "@@:");
        class_addMethod(connectionClass, @selector(description), (IMP)fauxConnectionDescription, "@@:");
        objc_registerClassPair(connectionClass);
        fauxInstallForwardingNet(connectionClass);
    });
    return connectionClass;
}

/// A single shared fake AVCaptureConnection handed to app delegates as the `fromConnection:`
/// argument. Never-freed singleton so the zeroed-ivar real dealloc never runs.
static id fauxMakeConnection(void) {
    static id connection;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = fauxConnectionClass();
        if (cls) connection = class_createInstance(cls, 0);
    });
    return connection;
}

// Per-instance fake connection carrying a preview layer (used by the manual NoConnections preview
// path: AVCaptureConnection(inputPort:videoPreviewLayer:)).
static id fauxMakeConnectionWithPreviewLayer(id previewLayer) {
    Class cls = fauxConnectionClass();
    if (!cls) return nil;
    id connection = class_createInstance(cls, 0);
    if (previewLayer) objc_setAssociatedObject(connection, kConnPreviewLayerKey, previewLayer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return connection;
}

static FauxFramePump *fauxPumpForSession(id session) {
    FauxFramePump *pump = objc_getAssociatedObject(session, kSessionPumpKey);
    if (!pump) {
        pump = [[FauxFramePump alloc] init];
        pump.captureConnection = fauxMakeConnection();
        objc_setAssociatedObject(session, kSessionPumpKey, pump, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return pump;
}

// MARK: - Swizzled implementations

static id fauxInputInitWithDevice(id self, SEL _cmd, id device, NSError **error) {
    if (FauxIsFakeDevice(device)) {
        id initialized = ((id (*)(id, SEL))fauxNSObjectInit)(self, @selector(init));
        if (initialized) {
            objc_setAssociatedObject(initialized, kFakeInputDeviceKey, device, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (error) *error = nil;
        return initialized;
    }
    if (fauxOriginalInputInit) {
        return ((id (*)(id, SEL, id, NSError **))fauxOriginalInputInit)(self, _cmd, device, error);
    }
    return nil;
}

static OSType fauxOutputRequestedFormat(id output) {
    NSNumber *fmt = objc_getAssociatedObject(output, kVideoFormatKey);
    return fmt ? (OSType)fmt.unsignedIntValue : 0;
}

static void fauxSetVideoSettings(id self, SEL _cmd, NSDictionary *settings) {
    // Store the requested pixel format / settings; do NOT call the original (no real graph exists
    // to validate against). The pump converts BGRA to the requested 420 format.
    objc_setAssociatedObject(self, kVideoSettingsKey, settings, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSNumber *fmt = settings[(NSString *)kCVPixelBufferPixelFormatTypeKey];
    if (fmt) {
        objc_setAssociatedObject(self, kVideoFormatKey, fmt, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        FauxFramePump *pump = objc_getAssociatedObject(self, kVideoPumpKey);
        if (pump) pump.requestedPixelFormat = (OSType)fmt.unsignedIntValue;
    }
}
static NSDictionary *fauxGetVideoSettings(id self, SEL _cmd) {
    return objc_getAssociatedObject(self, kVideoSettingsKey) ?: @{};
}
static NSArray *fauxAvailableVideoCVPixelFormatTypes(id self, SEL _cmd) {
    return @[ @(kCVPixelFormatType_32BGRA),
              @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
              @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) ];
}

static void fauxSetSampleBufferDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    objc_setAssociatedObject(self, kOutputDelegateKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kOutputQueueKey, queue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Ordering-robust: if the output was already added to a session, bind the delegate to the
    // pump now (apps such as Flutter / vision-camera v3 set the delegate AFTER addOutput:).
    FauxFramePump *pump = objc_getAssociatedObject(self, kVideoPumpKey);
    if (pump && delegate && queue) {
        @synchronized(pump) {
            pump.captureOutput = self;
            pump.sampleBufferDelegate = delegate;
            pump.deliveryQueue = queue;
        }
        OSType fmt = fauxOutputRequestedFormat(self);
        if (fmt) pump.requestedPixelFormat = fmt;
        [pump startIfReady];
    }
}

static void fauxSetMetadataDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    objc_setAssociatedObject(self, kMetadataDelegateKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kMetadataQueueKey, queue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    FauxFramePump *pump = objc_getAssociatedObject(self, kMetadataPumpKey);
    if (pump && delegate && queue) {
        [pump registerMetadataDelegate:delegate queue:queue output:self connection:fauxMakeConnection()];
    }
}

static NSArray *fauxMetadataAvailableTypes(id self, SEL _cmd) {
    // Advertise every machine-readable code type so apps can freely set metadataObjectTypes
    // without the real setter throwing "unsupported type" (which it validates against this list).
    static NSArray *types;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *candidates = @[
            AVMetadataObjectTypeQRCode, AVMetadataObjectTypeEAN8Code, AVMetadataObjectTypeEAN13Code,
            AVMetadataObjectTypePDF417Code, AVMetadataObjectTypeUPCECode, AVMetadataObjectTypeCode39Code,
            AVMetadataObjectTypeCode93Code, AVMetadataObjectTypeCode128Code, AVMetadataObjectTypeCode39Mod43Code,
            AVMetadataObjectTypeAztecCode, AVMetadataObjectTypeITF14Code, AVMetadataObjectTypeDataMatrixCode,
            AVMetadataObjectTypeInterleaved2of5Code
        ];
        NSMutableArray *valid = [NSMutableArray array];
        for (AVMetadataObjectType type in candidates) {
            if (type) [valid addObject:type];
        }
        types = [valid copy];
    });
    return types;
}

static void fauxInvokePhotoDelegate(id delegate, SEL selector, id output, id argument) {
    if ([delegate respondsToSelector:selector]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, selector, output, argument);
    }
}

static void fauxCapturePhotoWithSettings(id self, SEL _cmd, id settings, id delegate) {
    FauxFramePump *pump = objc_getAssociatedObject(self, kPhotoPumpKey);
    int64_t uniqueID = 0;
    if ([settings respondsToSelector:@selector(uniqueID)]) {
        uniqueID = ((int64_t (*)(id, SEL))objc_msgSend)(settings, @selector(uniqueID));
    }
    id output = self;

    // Return immediately (matching native async semantics) and do the JPEG encode + fake-object
    // construction off the caller's (typically main) thread.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        CVPixelBufferRef buffer = pump ? [pump copyLatestImageBuffer] : NULL;
        int32_t width = buffer ? (int32_t)CVPixelBufferGetWidth(buffer) : 0;
        int32_t height = buffer ? (int32_t)CVPixelBufferGetHeight(buffer) : 0;
        id resolvedSettings = fauxMakeResolvedSettings(uniqueID, width, height);
        id photo = buffer ? fauxMakePhoto(buffer, resolvedSettings) : nil;
        if (buffer) CVPixelBufferRelease(buffer);

        fauxInvokePhotoDelegate(delegate, @selector(captureOutput:willBeginCaptureForResolvedSettings:), output, resolvedSettings);
        fauxInvokePhotoDelegate(delegate, @selector(captureOutput:willCapturePhotoForResolvedSettings:), output, resolvedSettings);
        fauxInvokePhotoDelegate(delegate, @selector(captureOutput:didCapturePhotoForResolvedSettings:), output, resolvedSettings);

        NSError *captureError = nil;
        if (photo) {
            if ([delegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
                ((void (*)(id, SEL, id, id, id))objc_msgSend)(delegate, @selector(captureOutput:didFinishProcessingPhoto:error:), output, photo, nil);
            }
        } else {
            // No frame yet: report a real error instead of silently signalling success.
            captureError = [NSError errorWithDomain:@"com.fauxcam" code:-1
                                           userInfo:@{ NSLocalizedDescriptionKey: @"FauxCam: no frame available yet" }];
        }
        if ([delegate respondsToSelector:@selector(captureOutput:didFinishCaptureForResolvedSettings:error:)]) {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(delegate, @selector(captureOutput:didFinishCaptureForResolvedSettings:error:), output, resolvedSettings, captureError);
        }
        os_log(fauxSessionLog(), "photo captured (%dx%d) ok=%d", width, height, photo != nil);
    });
}

static BOOL fauxInputIsFake(id input) {
    return objc_getAssociatedObject(input, kFakeInputDeviceKey) != nil;
}

/// A fake AVCaptureDeviceInput has zeroed internals, so the real `-ports` (and the connection-building
/// that calls it — e.g. AVCaptureVideoPreviewLayer.setSession: → _connectionsForNewVideoPreviewLayer:)
/// dereferences garbage and crashes. Return no ports for fakes so no real connection graph is built.
static id fauxInputPorts(id self, SEL _cmd) {
    if (fauxInputIsFake(self)) return @[];
    if (fauxOriginalInputPorts) return ((id (*)(id, SEL))fauxOriginalInputPorts)(self, _cmd);
    return @[];
}

// Synthetic session graph bookkeeping so apps that read session.inputs/.outputs (a common
// "already added?" guard) get sane answers even though we never build the real graph.
static NSMutableArray *fauxSessionList(id session, const void *key) {
    NSMutableArray *list = objc_getAssociatedObject(session, key);
    if (!list) { list = [NSMutableArray array]; objc_setAssociatedObject(session, key, list, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    return list;
}
static void fauxSessionListAdd(id session, const void *key, id obj) {
    if (!obj) return;
    NSMutableArray *list = fauxSessionList(session, key);
    @synchronized(list) { if (![list containsObject:obj]) [list addObject:obj]; }
}
static void fauxSessionListRemove(id session, const void *key, id obj) {
    NSMutableArray *list = objc_getAssociatedObject(session, key);
    if (list && obj) { @synchronized(list) { [list removeObject:obj]; } }
}

static void fauxSessionRegisterInput(id self, id input) {
    fauxSessionListAdd(self, kSessionInputsKey, input);
    if (fauxInputIsFake(input)) {
        FauxFramePump *pump = fauxPumpForSession(self);
        id device = objc_getAssociatedObject(input, kFakeInputDeviceKey);
        pump.frontCamera = (FauxFakeDevicePosition(device) == AVCaptureDevicePositionFront);
    }
    // Non-fake inputs are accepted and ignored: the simulator has no real device, and the real
    // addInput: would build a connection graph that does not exist (crash risk). The faux pump
    // is the source regardless.
}

static void fauxSessionAddInput(id self, SEL _cmd, id input) {
    os_log(fauxSessionLog(), "addInput class=%{public}s fake=%d", object_getClassName(input), fauxInputIsFake(input) ? 1 : 0);
    fauxSessionRegisterInput(self, input);
}

static void fauxSessionAddInputWithNoConnections(id self, SEL _cmd, id input) {
    os_log(fauxSessionLog(), "addInputWithNoConnections fake=%d", fauxInputIsFake(input) ? 1 : 0);
    fauxSessionRegisterInput(self, input);
}

static BOOL fauxIsKnownOutputClass(id output, const char *className) {
    Class cls = objc_getClass(className);
    return cls && [output isKindOfClass:cls];
}

static void fauxSessionRegisterOutput(id self, id output) {
    fauxSessionListAdd(self, kSessionOutputsKey, output);
    if (fauxIsKnownOutputClass(output, "AVCaptureVideoDataOutput")) {
        FauxFramePump *pump = fauxPumpForSession(self);
        // Store the pump on the output so a later setSampleBufferDelegate:queue: can bind it
        // (delegate may be set before OR after addOutput:).
        objc_setAssociatedObject(output, kVideoPumpKey, pump, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        OSType fmt = fauxOutputRequestedFormat(output);
        if (fmt) pump.requestedPixelFormat = fmt;
        id delegate = objc_getAssociatedObject(output, kOutputDelegateKey);
        dispatch_queue_t queue = objc_getAssociatedObject(output, kOutputQueueKey);
        if (delegate && queue) {
            @synchronized(pump) {
                pump.captureOutput = output;
                pump.sampleBufferDelegate = delegate;
                pump.deliveryQueue = queue;
            }
        }
        [pump startIfReady];
        return;
    }
    if (fauxIsKnownOutputClass(output, "AVCaptureMetadataOutput")) {
        FauxFramePump *pump = fauxPumpForSession(self);
        objc_setAssociatedObject(output, kMetadataPumpKey, pump, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        id delegate = objc_getAssociatedObject(output, kMetadataDelegateKey);
        dispatch_queue_t queue = objc_getAssociatedObject(output, kMetadataQueueKey);
        if (delegate && queue) {
            [pump registerMetadataDelegate:delegate queue:queue output:output connection:fauxMakeConnection()];
        }
        return;
    }
    if (fauxIsKnownOutputClass(output, "AVCapturePhotoOutput")) {
        FauxFramePump *pump = fauxPumpForSession(self);
        objc_setAssociatedObject(output, kPhotoPumpKey, pump, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [pump markPhotoConsumer];
        return;
    }
    // AVCaptureMovieFileOutput / AudioDataOutput / DepthDataOutput and any other output: accept and
    // ignore. The real addOutput: over a faux (connectionless) input graph would crash, so we must
    // NOT fall through to the original. These simply produce no frames (safe no-op).
}

static void fauxSessionAddOutput(id self, SEL _cmd, id output) {
    os_log(fauxSessionLog(), "addOutput class=%{public}s", object_getClassName(output));
    fauxSessionRegisterOutput(self, output);
}

static void fauxSessionAddOutputWithNoConnections(id self, SEL _cmd, id output) {
    os_log(fauxSessionLog(), "addOutputWithNoConnections class=%{public}s", object_getClassName(output));
    fauxSessionRegisterOutput(self, output);
}

// isRunning is modeled via an associated flag + manual KVO on "running" so apps that observe
// session.isRunning (SwiftUI/Combine/RN readiness gating) advance their state machine.
static void fauxSessionSetRunning(id self, BOOL running) {
    NSNumber *current = objc_getAssociatedObject(self, kSessionRunningKey);
    if (current.boolValue == running) return;
    ((void (*)(id, SEL, NSString *))objc_msgSend)(self, @selector(willChangeValueForKey:), @"running");
    objc_setAssociatedObject(self, kSessionRunningKey, @(running), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, NSString *))objc_msgSend)(self, @selector(didChangeValueForKey:), @"running");
}
static BOOL fauxSessionIsRunning(id self, SEL _cmd) {
    return [(NSNumber *)objc_getAssociatedObject(self, kSessionRunningKey) boolValue];
}

static void fauxSessionStartRunning(id self, SEL _cmd) {
    FauxFramePump *pump = fauxPumpForSession(self);
    NSHashTable *previewLayers = objc_getAssociatedObject(self, kSessionPreviewLayersKey);
    os_log(fauxSessionLog(), "startRunning intercepted pumpExists=%d previewLayers=%lu", pump != nil, (unsigned long)previewLayers.count);
    for (CALayer *previewLayer in previewLayers) {
        [pump registerPreviewLayer:previewLayer];
    }
    [pump start];
    fauxSessionSetRunning(self, YES);
}

// Registers an app-owned preview layer with its session's pump so it receives faux frames.
// Shared by every way an app can attach a session to a preview layer.
static void fauxPreviewRegister(id layer, id session) {
    if (!layer || !session) return;
    NSHashTable *previewLayers = objc_getAssociatedObject(session, kSessionPreviewLayersKey);
    if (!previewLayers) {
        previewLayers = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(session, kSessionPreviewLayersKey, previewLayers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [previewLayers addObject:layer];
    FauxFramePump *pump = fauxPumpForSession(session);
    os_log(fauxSessionLog(), "preview registered pumpExists=%d", pump != nil);
    [pump registerPreviewLayer:layer];
}

// We do NOT forward setSession: to the real implementation. On the simulator the session has no real
// capture graph, so AVFoundation's -[AVCaptureSession _connectionsForNewVideoPreviewLayer:] walks the
// fake input/connection objects (zeroed internals) and crashes (EXC_BAD_ACCESS). We don't need it: the
// pump overlays its own AVSampleBufferDisplayLayer on the preview layer to show frames. The layer
// stays a valid object; only the (unused, crash-prone) real wiring is skipped.
static void fauxPreviewSetSession(id self, SEL _cmd, id session) {
    fauxPreviewRegister(self, session);
}

static void fauxPreviewSetSessionWithNoConnection(id self, SEL _cmd, id session) {
    fauxPreviewRegister(self, session);
}

static id fauxPreviewInitWithSession(id self, SEL _cmd, id session) {
    // Initialize the layer WITHOUT a session (nil → no graph wiring, no crash), then register it for
    // faux frames. Returns a valid AVCaptureVideoPreviewLayer.
    id result = self;
    if (fauxOriginalPreviewInitWithSession) {
        result = ((id (*)(id, SEL, id))fauxOriginalPreviewInitWithSession)(self, _cmd, nil);
    }
    fauxPreviewRegister(result ?: self, session);
    return result;
}

static void fauxSessionStopRunning(id self, SEL _cmd) {
    FauxFramePump *pump = objc_getAssociatedObject(self, kSessionPumpKey);
    if (pump) [pump stop];
    fauxSessionSetRunning(self, NO);
}

static void fauxSessionRemoveInput(id self, SEL _cmd, id input) {
    fauxSessionListRemove(self, kSessionInputsKey, input);
    // front/back is re-derived on the next addInput:.
}

static void fauxSessionRemoveOutput(id self, SEL _cmd, id output) {
    fauxSessionListRemove(self, kSessionOutputsKey, output);
    FauxFramePump *pump = objc_getAssociatedObject(self, kSessionPumpKey);
    if (pump) [pump detachOutput:output];
}

static id fauxSessionInputs(id self, SEL _cmd) {
    NSMutableArray *list = objc_getAssociatedObject(self, kSessionInputsKey);
    if (!list) return @[];
    @synchronized(list) { return [list copy]; }
}
static id fauxSessionOutputs(id self, SEL _cmd) {
    NSMutableArray *list = objc_getAssociatedObject(self, kSessionOutputsKey);
    if (!list) return @[];
    @synchronized(list) { return [list copy]; }
}
static id fauxSessionConnections(id self, SEL _cmd) {
    FauxFramePump *pump = objc_getAssociatedObject(self, kSessionPumpKey);
    id conn = pump ? pump.captureConnection : nil;
    return conn ? @[conn] : @[];
}

// AVCaptureConnection manual construction (vision-camera v4 / NoConnections preview wiring): return a
// faux connection instead of letting the real init run over a faux/zeroed input port.
static id fauxConnInitWithInputPortVideoPreviewLayer(id self, SEL _cmd, id port, id previewLayer) {
    return fauxMakeConnectionWithPreviewLayer(previewLayer);
}
static id fauxConnInitWithInputPortsOutput(id self, SEL _cmd, NSArray *ports, id output) {
    return fauxMakeConnection();
}

static BOOL fauxSessionCanAddInput(id self, SEL _cmd, id input) { return YES; }
static BOOL fauxSessionCanAddOutput(id self, SEL _cmd, id output) { return YES; }
static BOOL fauxSessionCanAddConnection(id self, SEL _cmd, id connection) { return YES; }
static void fauxSessionVoidNoArg(id self, SEL _cmd) { }

static void fauxSessionAddConnection(id self, SEL _cmd, id connection) {
    // Real connections don't exist on the simulator; the faux pump already fans out. If the
    // connection carries a preview layer (NoConnections preview path), register it.
    if (connection && [connection respondsToSelector:@selector(videoPreviewLayer)]) {
        id layer = ((id (*)(id, SEL))objc_msgSend)(connection, @selector(videoPreviewLayer));
        if (layer) fauxPreviewRegister(layer, self);
    }
}

static void fauxSessionSetPreset(id self, SEL _cmd, NSString *preset) {
    if (preset) objc_setAssociatedObject(self, kSessionPresetKey, preset, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static NSString *fauxSessionGetPreset(id self, SEL _cmd) {
    NSString *preset = objc_getAssociatedObject(self, kSessionPresetKey);
    return preset ?: AVCaptureSessionPresetHigh;
}
static BOOL fauxSessionCanSetPreset(id self, SEL _cmd, NSString *preset) { return YES; }

static void fauxMetadataSetObjectTypes(id self, SEL _cmd, NSArray *types) {
    // Store only; the real setter validates against connection-derived available types and throws
    // (NSInvalidArgumentException) for any unsupported type when the graph is faux/empty.
    objc_setAssociatedObject(self, kMetadataTypesKey, types, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static NSArray *fauxMetadataGetObjectTypes(id self, SEL _cmd) {
    NSArray *types = objc_getAssociatedObject(self, kMetadataTypesKey);
    return types ?: @[];
}

// MARK: - Installation

static IMP fauxReplaceInstanceMethod(Class targetClass, SEL selector, IMP implementation, const char *fallbackTypes) {
    Method existing = class_getInstanceMethod(targetClass, selector);
    const char *types = existing ? method_getTypeEncoding(existing) : fallbackTypes;
    IMP original = existing ? method_getImplementation(existing) : NULL;
    if (!class_addMethod(targetClass, selector, implementation, types)) {
        original = method_setImplementation(class_getInstanceMethod(targetClass, selector), implementation);
    }
    return original;
}

static void fauxVoidTwoArg(id self, SEL _cmd, id a, id b) { }

// Installs every session-level swizzle on a given session class. Called for both AVCaptureSession
// and AVCaptureMultiCamSession (a subclass that overrides these selectors, so it does NOT inherit
// the swizzle and must be installed directly).
static void fauxInstallSessionClass(Class sessionClass) {
    if (!sessionClass) return;
    fauxReplaceInstanceMethod(sessionClass, @selector(addInput:), (IMP)fauxSessionAddInput, "v@:@");
    fauxReplaceInstanceMethod(sessionClass, @selector(addOutput:), (IMP)fauxSessionAddOutput, "v@:@");
    fauxReplaceInstanceMethod(sessionClass, @selector(addInputWithNoConnections:), (IMP)fauxSessionAddInputWithNoConnections, "v@:@");
    fauxReplaceInstanceMethod(sessionClass, @selector(addOutputWithNoConnections:), (IMP)fauxSessionAddOutputWithNoConnections, "v@:@");
    fauxReplaceInstanceMethod(sessionClass, @selector(addConnection:), (IMP)fauxSessionAddConnection, "v@:@");
    fauxReplaceInstanceMethod(sessionClass, @selector(canAddConnection:), (IMP)fauxSessionCanAddConnection, "B@:@");
    fauxReplaceInstanceMethod(sessionClass, @selector(startRunning), (IMP)fauxSessionStartRunning, "v@:");
    fauxReplaceInstanceMethod(sessionClass, @selector(stopRunning), (IMP)fauxSessionStopRunning, "v@:");
    fauxReplaceInstanceMethod(sessionClass, @selector(canAddInput:), (IMP)fauxSessionCanAddInput, "B@:@");
    fauxReplaceInstanceMethod(sessionClass, @selector(canAddOutput:), (IMP)fauxSessionCanAddOutput, "B@:@");
    fauxReplaceInstanceMethod(sessionClass, @selector(beginConfiguration), (IMP)fauxSessionVoidNoArg, "v@:");
    fauxReplaceInstanceMethod(sessionClass, @selector(commitConfiguration), (IMP)fauxSessionVoidNoArg, "v@:");
    fauxReplaceInstanceMethod(sessionClass, @selector(setSessionPreset:), (IMP)fauxSessionSetPreset, "v@:@");
    fauxReplaceInstanceMethod(sessionClass, @selector(sessionPreset), (IMP)fauxSessionGetPreset, "@@:");
    fauxReplaceInstanceMethod(sessionClass, @selector(canSetSessionPreset:), (IMP)fauxSessionCanSetPreset, "B@:@");
    fauxReplaceInstanceMethod(sessionClass, @selector(removeInput:), (IMP)fauxSessionRemoveInput, "v@:@");
    fauxReplaceInstanceMethod(sessionClass, @selector(removeOutput:), (IMP)fauxSessionRemoveOutput, "v@:@");
    fauxReplaceInstanceMethod(sessionClass, @selector(inputs), (IMP)fauxSessionInputs, "@@:");
    fauxReplaceInstanceMethod(sessionClass, @selector(outputs), (IMP)fauxSessionOutputs, "@@:");
    fauxReplaceInstanceMethod(sessionClass, @selector(connections), (IMP)fauxSessionConnections, "@@:");
    fauxReplaceInstanceMethod(sessionClass, @selector(isRunning), (IMP)fauxSessionIsRunning, "B@:");
}

// Success-gated (not dispatch_once): if AVFoundation isn't loaded yet at __attribute__((constructor))
// time (Flutter/Unity dlopen it lazily), this returns without marking done so the dyld add-image
// retry can install once the framework appears. dyld serializes image-load callbacks, so no lock.
void FauxInstallCaptureSession(void) {
    static BOOL sInstalled = NO;
    if (sInstalled) return;
    Class sessionClass = objc_getClass("AVCaptureSession");
    if (!sessionClass) return;
    {
        Method nsObjectInit = class_getInstanceMethod([NSObject class], @selector(init));
        fauxNSObjectInit = method_getImplementation(nsObjectInit);

        Class inputClass = objc_getClass("AVCaptureDeviceInput");
        if (inputClass) {
            fauxOriginalInputInit = fauxReplaceInstanceMethod(inputClass, @selector(initWithDevice:error:), (IMP)fauxInputInitWithDevice, "@@:@^@");
            fauxOriginalInputPorts = fauxReplaceInstanceMethod(inputClass, @selector(ports), (IMP)fauxInputPorts, "@@:");
        }
        Class outputClass = objc_getClass("AVCaptureVideoDataOutput");
        if (outputClass) {
            fauxReplaceInstanceMethod(outputClass, @selector(setSampleBufferDelegate:queue:), (IMP)fauxSetSampleBufferDelegate, "v@:@@");
            fauxReplaceInstanceMethod(outputClass, @selector(setVideoSettings:), (IMP)fauxSetVideoSettings, "v@:@");
            fauxReplaceInstanceMethod(outputClass, @selector(videoSettings), (IMP)fauxGetVideoSettings, "@@:");
            fauxReplaceInstanceMethod(outputClass, @selector(availableVideoCVPixelFormatTypes), (IMP)fauxAvailableVideoCVPixelFormatTypes, "@@:");
        }

        fauxInstallSessionClass(objc_getClass("AVCaptureSession"));
        fauxInstallSessionClass(objc_getClass("AVCaptureMultiCamSession"));

        Class previewClass = objc_getClass("AVCaptureVideoPreviewLayer");
        if (previewClass) {
            fauxOriginalPreviewSetSession = fauxReplaceInstanceMethod(previewClass, @selector(setSession:), (IMP)fauxPreviewSetSession, "v@:@");
            fauxOriginalPreviewSetSessionNoConn = fauxReplaceInstanceMethod(previewClass, @selector(setSessionWithNoConnection:), (IMP)fauxPreviewSetSessionWithNoConnection, "v@:@");
            fauxOriginalPreviewInitWithSession = fauxReplaceInstanceMethod(previewClass, @selector(initWithSession:), (IMP)fauxPreviewInitWithSession, "@@:@");
        }
        Class metadataClass = objc_getClass("AVCaptureMetadataOutput");
        if (metadataClass) {
            fauxReplaceInstanceMethod(metadataClass, @selector(setMetadataObjectsDelegate:queue:), (IMP)fauxSetMetadataDelegate, "v@:@@");
            fauxReplaceInstanceMethod(metadataClass, @selector(availableMetadataObjectTypes), (IMP)fauxMetadataAvailableTypes, "@@:");
            fauxReplaceInstanceMethod(metadataClass, @selector(setMetadataObjectTypes:), (IMP)fauxMetadataSetObjectTypes, "v@:@");
            fauxReplaceInstanceMethod(metadataClass, @selector(metadataObjectTypes), (IMP)fauxMetadataGetObjectTypes, "@@:");
        }
        Class photoClass = objc_getClass("AVCapturePhotoOutput");
        if (photoClass) {
            fauxReplaceInstanceMethod(photoClass, @selector(capturePhotoWithSettings:delegate:), (IMP)fauxCapturePhotoWithSettings, "v@:@@");
        }
        Class movieClass = objc_getClass("AVCaptureMovieFileOutput");
        if (movieClass) {
            // No-op recording so apps that add a movie output don't drive the (absent) real graph.
            fauxReplaceInstanceMethod(movieClass, @selector(startRecordingToOutputFileURL:recordingDelegate:), (IMP)fauxVoidTwoArg, "v@:@@");
            fauxReplaceInstanceMethod(movieClass, @selector(stopRecording), (IMP)fauxSessionVoidNoArg, "v@:");
        }
        // Ensure the fake connection class exists, then intercept manual AVCaptureConnection
        // construction so apps wiring connections by hand (vision-camera v4 / NoConnections) get a
        // safe faux connection instead of a real one over a faux input port.
        fauxConnectionClass();
        Class connClass = objc_getClass("AVCaptureConnection");
        if (connClass) {
            fauxReplaceInstanceMethod(connClass, @selector(initWithInputPort:videoPreviewLayer:), (IMP)fauxConnInitWithInputPortVideoPreviewLayer, "@@:@@");
            fauxReplaceInstanceMethod(connClass, @selector(initWithInputPorts:output:), (IMP)fauxConnInitWithInputPortsOutput, "@@:@@");
        }
        os_log(fauxSessionLog(), "capture session interception installed");
        sInstalled = YES;
    }
}
