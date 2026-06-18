#include "SessionSwizzle.h"
#include "AVSwizzle.h"
#include "FrameClient.h"
#import "FauxBufferFactory.h"

@import Foundation;
@import ObjectiveC.runtime;
@import ObjectiveC.message;
@import os.log;
@import AVFoundation;
@import CoreMedia;
@import QuartzCore;

static const int32_t kFrameWidth = 1280;
static const int32_t kFrameHeight = 720;
static const int32_t kFramesPerSecond = 10;
static const uint8_t kSourcePixelBlue = 255;
static const uint8_t kSourcePixelGreen = 0;
static const uint8_t kSourcePixelRed = 255;
static const uint8_t kSourcePixelAlpha = 255;

static const void *kSessionPumpKey = &kSessionPumpKey;
static const void *kFakeInputDeviceKey = &kFakeInputDeviceKey;
static const void *kOutputDelegateKey = &kOutputDelegateKey;
static const void *kOutputQueueKey = &kOutputQueueKey;
static const void *kSessionPreviewLayersKey = &kSessionPreviewLayersKey;

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
    if (self.displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        [self.displayLayer flush];
    }
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, YES);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef attachment = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(attachment, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    }
    [self.displayLayer enqueueSampleBuffer:sampleBuffer];
}
@end

// MARK: - Frame pump

@interface FauxFramePump : NSObject
@property (nonatomic, weak) id sampleBufferDelegate;
@property (nonatomic, strong) dispatch_queue_t deliveryQueue;
@property (nonatomic, strong) id captureOutput;
@property (nonatomic, strong) id captureConnection;
- (void)start;
- (void)stop;
- (void)registerPreviewLayer:(CALayer *)previewLayer;
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
    NSMutableArray<FauxPreviewTarget *> *_previewTargets;
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
}

- (void)start {
    if (_timer) return;
    if (_sourcePixels) { free(_sourcePixels); _sourcePixels = NULL; }
    if (_frameClient) { faux_frame_client_destroy(_frameClient); _frameClient = NULL; }
    _usesHostSocket = NO;

    _bufferFactory = [[FauxBufferFactory alloc] initWithWidth:kFrameWidth height:kFrameHeight framesPerSecond:kFramesPerSecond];
    if (!_bufferFactory) return;
    [self buildSourcePixels];
    [self connectHostSocket];

    if (!_pumpQueue) {
        _pumpQueue = dispatch_queue_create("com.fauxcam.pump", DISPATCH_QUEUE_SERIAL);
    }
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _pumpQueue);
    uint64_t interval = (uint64_t)NSEC_PER_SEC / (uint64_t)kFramesPerSecond;
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0), interval, interval / 10);
    __weak FauxFramePump *weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf deliverFrame]; });
    dispatch_resume(_timer);
    os_log(fauxSessionLog(), "frame pump started fps=%d", kFramesPerSecond);
}

- (void)stop {
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
}

- (void)buildSourcePixels {
    _sourceBytesPerRow = (size_t)kFrameWidth * 4;
    size_t total = _sourceBytesPerRow * (size_t)kFrameHeight;
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
    if (faux_frame_client_send_demand(_frameClient, FAUX_POSITION_BACK, (uint32_t)kFrameWidth, (uint32_t)kFrameHeight, (uint32_t)kFramesPerSecond, FAUX_PIXEL_FORMAT_BGRA32) != 0) {
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
                                                                    sourceLength:_sourceBytesPerRow * (size_t)kFrameHeight];
    if (sampleBuffer) {
        [self deliverSampleBuffer:sampleBuffer];
        CFRelease(sampleBuffer);
    }
}

- (void)deliverSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    _sequence++;
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
    [self deliverToPreviewLayers:sampleBuffer];
}

- (void)deliverToPreviewLayers:(CMSampleBufferRef)sampleBuffer {
    NSArray<FauxPreviewTarget *> *targets;
    @synchronized(self) {
        if (_previewTargets.count == 0) return;
        targets = [_previewTargets copy];
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

- (void)dealloc {
    [self stop];
    if (_sourcePixels) free(_sourcePixels);
    if (_frameClient) faux_frame_client_destroy(_frameClient);
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
        os_log(fauxSessionLog(), "capture session interception installed");
    });
}
