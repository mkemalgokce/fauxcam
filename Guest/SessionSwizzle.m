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

static IMP fauxNSObjectInit;
static IMP fauxOriginalInputInit;
static IMP fauxOriginalAddInput;
static IMP fauxOriginalAddOutput;
static IMP fauxOriginalPreviewSetSession;

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
- (void)enqueue:(CMSampleBufferRef)sampleBuffer;
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

- (void)enqueue:(CMSampleBufferRef)sampleBuffer {
    CALayer *preview = self.previewLayer;
    if (!preview) return;
    if (self.displayLayer.superlayer != preview) {
        [preview addSublayer:self.displayLayer];
    }
    self.displayLayer.frame = preview.bounds;
    if ([preview respondsToSelector:@selector(videoGravity)]) {
        AVLayerVideoGravity gravity = [(AVCaptureVideoPreviewLayer *)preview videoGravity];
        if (gravity && ![self.displayLayer.videoGravity isEqualToString:gravity]) {
            self.displayLayer.videoGravity = gravity;
        }
    }
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
        objc_registerClassPair(metadataClass);
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

// MARK: - Frame pump

@interface FauxFramePump : NSObject
@property (nonatomic, weak) id sampleBufferDelegate;
@property (nonatomic, strong) dispatch_queue_t deliveryQueue;
@property (nonatomic, strong) id captureOutput;
@property (nonatomic, strong) id captureConnection;
- (void)start;
- (void)startIfReady;
- (void)stop;
- (void)registerPreviewLayer:(CALayer *)previewLayer;
- (void)registerMetadataDelegate:(id)delegate queue:(dispatch_queue_t)queue output:(id)output connection:(id)connection;
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
    BOOL _startRequested;
    BOOL _loggedPreviewDelivery;
    BOOL _loggedMetadataDelivery;
    int32_t _frameWidth;
    int32_t _frameHeight;
    int32_t _framesPerSecond;
    CVPixelBufferRef _latestImageBuffer;
    NSMutableArray<FauxPreviewTarget *> *_previewTargets;
    NSMutableArray<FauxMetadataTarget *> *_metadataTargets;
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

- (BOOL)hasConsumer {
    if (self.sampleBufferDelegate && self.deliveryQueue) return YES;
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
    if (!buffer) { os_log(fauxSessionLog(), "metadata scan: no latest buffer"); return; }
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
    _startRequested = YES;
    [self startIfReady];
}

- (void)startIfReady {
    if (_timer || !_startRequested || ![self hasConsumer]) return;

    if (_sourcePixels) { free(_sourcePixels); _sourcePixels = NULL; }
    if (_frameClient) { faux_frame_client_destroy(_frameClient); _frameClient = NULL; }
    _usesHostSocket = NO;
    _frameWidth = faux_config_width();
    _frameHeight = faux_config_height();
    _framesPerSecond = faux_config_fps();

    _bufferFactory = [[FauxBufferFactory alloc] initWithWidth:_frameWidth height:_frameHeight framesPerSecond:_framesPerSecond];
    if (!_bufferFactory) return;
    [self buildSourcePixels];
    [self connectHostSocket];

    if (!_pumpQueue) {
        _pumpQueue = dispatch_queue_create("com.fauxcam.pump", DISPATCH_QUEUE_SERIAL);
    }
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _pumpQueue);
    uint64_t interval = (uint64_t)NSEC_PER_SEC / (uint64_t)_framesPerSecond;
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0), interval, interval / 10);
    __weak FauxFramePump *weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf deliverFrame]; });
    dispatch_resume(_timer);
    os_log(fauxSessionLog(), "frame pump started %dx%d fps=%d", _frameWidth, _frameHeight, _framesPerSecond);
}

- (void)stop {
    _startRequested = NO;
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
    NSArray<FauxPreviewTarget *> *targets;
    @synchronized(self) {
        targets = [_previewTargets copy];
        [_previewTargets removeAllObjects];
    }
    if (targets.count > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            for (FauxPreviewTarget *target in targets) {
                [target.displayLayer removeFromSuperlayer];
            }
        });
    }
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
    const char *socketPath = getenv("FAUXCAM_SOCKET");
    if (!socketPath || socketPath[0] == '\0') return;
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

- (void)deliverHostFrame {
    if (faux_frame_client_send_demand(_frameClient, FAUX_POSITION_BACK, (uint32_t)_frameWidth, (uint32_t)_frameHeight, (uint32_t)_framesPerSecond, FAUX_PIXEL_FORMAT_BGRA32) != 0) {
        [self handleHostSocketFailure];
        return;
    }
    faux_received_frame received;
    if (faux_frame_client_recv_frame(_frameClient, &received) != 0) {
        [self handleHostSocketFailure];
        return;
    }
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

    id delegate = self.sampleBufferDelegate;
    dispatch_queue_t queue = self.deliveryQueue;
    if (delegate && queue) {
        id output = self.captureOutput;
        id connection = self.captureConnection;
        CFRetain(sampleBuffer);
        dispatch_async(queue, ^{
            ((void (*)(id, SEL, id, CMSampleBufferRef, id))objc_msgSend)(
                delegate, @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
                output, sampleBuffer, connection);
            CFRelease(sampleBuffer);
        });
    }

    if (previewTargets) [self deliverToPreviewLayers:sampleBuffer targets:previewTargets];
    [self scanMetadataIfNeeded];
}

- (void)deliverToPreviewLayers:(CMSampleBufferRef)sampleBuffer targets:(NSArray<FauxPreviewTarget *> *)targets {
    if (!_loggedPreviewDelivery) {
        _loggedPreviewDelivery = YES;
        os_log(fauxSessionLog(), "preview frame enqueued");
    }
    CFRetain(sampleBuffer);
    dispatch_async(dispatch_get_main_queue(), ^{
        for (FauxPreviewTarget *target in targets) {
            [target enqueue:sampleBuffer];
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

- (dispatch_queue_t)pumpQueue { return _pumpQueue; }

- (void)dealloc {
    [self stop];
    if (_sourcePixels) free(_sourcePixels);
    if (_frameClient) faux_frame_client_destroy(_frameClient);
    if (_latestImageBuffer) CVPixelBufferRelease(_latestImageBuffer);
}

@end

// MARK: - Pump lookup

static id fauxMakeConnection(void) {
    Class connectionClass = objc_getClass("AVCaptureConnection");
    return connectionClass ? class_createInstance(connectionClass, 0) : nil;
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

static void fauxSetSampleBufferDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    objc_setAssociatedObject(self, kOutputDelegateKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kOutputQueueKey, queue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    return @[ AVMetadataObjectTypeQRCode ];
}

static BOOL fauxInputIsFake(id input) {
    return objc_getAssociatedObject(input, kFakeInputDeviceKey) != nil;
}

static void fauxSessionAddInput(id self, SEL _cmd, id input) {
    if (fauxInputIsFake(input)) {
        (void)fauxPumpForSession(self);
        return;
    }
    if (fauxOriginalAddInput) {
        ((void (*)(id, SEL, id))fauxOriginalAddInput)(self, _cmd, input);
    }
}

static void fauxSessionAddOutput(id self, SEL _cmd, id output) {
    if ([output isKindOfClass:objc_getClass("AVCaptureVideoDataOutput")]) {
        FauxFramePump *pump = fauxPumpForSession(self);
        pump.captureOutput = output;
        pump.sampleBufferDelegate = objc_getAssociatedObject(output, kOutputDelegateKey);
        pump.deliveryQueue = objc_getAssociatedObject(output, kOutputQueueKey);
        objc_setAssociatedObject(output, kOutputDelegateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [pump startIfReady];
        return;
    }
    if ([output isKindOfClass:objc_getClass("AVCaptureMetadataOutput")]) {
        FauxFramePump *pump = fauxPumpForSession(self);
        objc_setAssociatedObject(output, kMetadataPumpKey, pump, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        id delegate = objc_getAssociatedObject(output, kMetadataDelegateKey);
        dispatch_queue_t queue = objc_getAssociatedObject(output, kMetadataQueueKey);
        if (delegate && queue) {
            [pump registerMetadataDelegate:delegate queue:queue output:output connection:fauxMakeConnection()];
        }
        return;
    }
    if (fauxOriginalAddOutput) {
        ((void (*)(id, SEL, id))fauxOriginalAddOutput)(self, _cmd, output);
    }
}

static void fauxSessionStartRunning(id self, SEL _cmd) {
    os_log(fauxSessionLog(), "startRunning intercepted (faux graph)");
    FauxFramePump *pump = objc_getAssociatedObject(self, kSessionPumpKey);
    if (!pump) return;
    NSHashTable *previewLayers = objc_getAssociatedObject(self, kSessionPreviewLayersKey);
    for (CALayer *previewLayer in previewLayers) {
        [pump registerPreviewLayer:previewLayer];
    }
    [pump start];
}

static void fauxPreviewSetSession(id self, SEL _cmd, id session) {
    if (fauxOriginalPreviewSetSession) {
        ((void (*)(id, SEL, id))fauxOriginalPreviewSetSession)(self, _cmd, session);
    }
    if (!session) return;
    NSHashTable *previewLayers = objc_getAssociatedObject(session, kSessionPreviewLayersKey);
    if (!previewLayers) {
        previewLayers = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(session, kSessionPreviewLayersKey, previewLayers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [previewLayers addObject:self];
    FauxFramePump *pump = objc_getAssociatedObject(session, kSessionPumpKey);
    if (pump) [pump registerPreviewLayer:self];
}

static void fauxSessionStopRunning(id self, SEL _cmd) {
    FauxFramePump *pump = objc_getAssociatedObject(self, kSessionPumpKey);
    if (pump) [pump stop];
}

static BOOL fauxSessionCanAddInput(id self, SEL _cmd, id input) { return YES; }
static BOOL fauxSessionCanAddOutput(id self, SEL _cmd, id output) { return YES; }

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

void FauxInstallCaptureSession(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Method nsObjectInit = class_getInstanceMethod([NSObject class], @selector(init));
        fauxNSObjectInit = method_getImplementation(nsObjectInit);

        Class inputClass = objc_getClass("AVCaptureDeviceInput");
        if (inputClass) {
            fauxOriginalInputInit = fauxReplaceInstanceMethod(inputClass, @selector(initWithDevice:error:), (IMP)fauxInputInitWithDevice, "@@:@^@");
        }
        Class outputClass = objc_getClass("AVCaptureVideoDataOutput");
        if (outputClass) {
            fauxReplaceInstanceMethod(outputClass, @selector(setSampleBufferDelegate:queue:), (IMP)fauxSetSampleBufferDelegate, "v@:@@");
        }
        Class sessionClass = objc_getClass("AVCaptureSession");
        if (sessionClass) {
            fauxOriginalAddInput = fauxReplaceInstanceMethod(sessionClass, @selector(addInput:), (IMP)fauxSessionAddInput, "v@:@");
            fauxOriginalAddOutput = fauxReplaceInstanceMethod(sessionClass, @selector(addOutput:), (IMP)fauxSessionAddOutput, "v@:@");
            fauxReplaceInstanceMethod(sessionClass, @selector(startRunning), (IMP)fauxSessionStartRunning, "v@:");
            fauxReplaceInstanceMethod(sessionClass, @selector(stopRunning), (IMP)fauxSessionStopRunning, "v@:");
            fauxReplaceInstanceMethod(sessionClass, @selector(canAddInput:), (IMP)fauxSessionCanAddInput, "B@:@");
            fauxReplaceInstanceMethod(sessionClass, @selector(canAddOutput:), (IMP)fauxSessionCanAddOutput, "B@:@");
        }
        Class previewClass = objc_getClass("AVCaptureVideoPreviewLayer");
        if (previewClass) {
            fauxOriginalPreviewSetSession = fauxReplaceInstanceMethod(previewClass, @selector(setSession:), (IMP)fauxPreviewSetSession, "v@:@");
        }
        Class metadataClass = objc_getClass("AVCaptureMetadataOutput");
        if (metadataClass) {
            fauxReplaceInstanceMethod(metadataClass, @selector(setMetadataObjectsDelegate:queue:), (IMP)fauxSetMetadataDelegate, "v@:@@");
            fauxReplaceInstanceMethod(metadataClass, @selector(availableMetadataObjectTypes), (IMP)fauxMetadataAvailableTypes, "@@:");
        }
        os_log(fauxSessionLog(), "capture session interception installed");
    });
}
