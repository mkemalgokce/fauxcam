#import "FauxBufferFactory.h"

@import ObjectiveC.runtime;
@import os.log;

static const OSType kFauxPixelFormat = kCVPixelFormatType_32BGRA;
static const size_t kFauxBytesPerPixel = 4;
static const int32_t kFauxMinimumFramesPerSecond = 1;

static os_log_t fauxBufferLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.fauxcam", "buffers"); });
    return log;
}

@implementation FauxBufferFactory {
    CVPixelBufferPoolRef _pixelBufferPool;
    int32_t _framesPerSecond;
    CMTime _frameDuration;
    CMClockRef _hostClock;
}

// MARK: - Lifecycle

- (nullable instancetype)initWithWidth:(int32_t)width
                                height:(int32_t)height
                       framesPerSecond:(int32_t)framesPerSecond {
    self = [super init];
    if (!self) return nil;
    if (width <= 0 || height <= 0 || framesPerSecond < kFauxMinimumFramesPerSecond) {
        os_log_error(fauxBufferLog(), "invalid dimensions w=%d h=%d fps=%d", width, height, framesPerSecond);
        return nil;
    }

    _width = width;
    _height = height;
    _framesPerSecond = framesPerSecond;
    _frameDuration = CMTimeMake(1, framesPerSecond);
    _hostClock = CMClockGetHostTimeClock();

    _pixelBufferPool = [self newPixelBufferPoolWithWidth:width height:height];
    if (!_pixelBufferPool) {
        os_log_error(fauxBufferLog(), "pixel buffer pool create failed");
        return nil;
    }
    return self;
}

- (void)dealloc {
    if (_pixelBufferPool) {
        CVPixelBufferPoolRelease(_pixelBufferPool);
        _pixelBufferPool = NULL;
    }
}

// MARK: - Sample buffer construction

- (nullable CMSampleBufferRef)newSampleBufferFromBGRABytes:(const uint8_t *)sourceBytes
                                        sourceBytesPerRow:(size_t)sourceBytesPerRow {
    if (!sourceBytes) return NULL;

    CVPixelBufferRef pixelBuffer = [self newFilledPixelBufferFromBGRABytes:sourceBytes
                                                        sourceBytesPerRow:sourceBytesPerRow];
    if (!pixelBuffer) return NULL;

    CMVideoFormatDescriptionRef formatDescription = NULL;
    OSStatus formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                                        pixelBuffer,
                                                                        &formatDescription);
    if (formatStatus != noErr || !formatDescription) {
        os_log_error(fauxBufferLog(), "format description create failed status=%d", (int)formatStatus);
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }

    CMSampleTimingInfo timing = [self nextSampleTimingInfo];

    CMSampleBufferRef sampleBuffer = NULL;
    OSStatus sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                                                    pixelBuffer,
                                                                    formatDescription,
                                                                    &timing,
                                                                    &sampleBuffer);

    CFRelease(formatDescription);
    CVPixelBufferRelease(pixelBuffer);

    if (sampleStatus != noErr || !sampleBuffer) {
        os_log_error(fauxBufferLog(), "sample buffer create failed status=%d", (int)sampleStatus);
        return NULL;
    }
    return sampleBuffer;
}

// MARK: - Pixel buffer construction

- (nullable CVPixelBufferRef)newFilledPixelBufferFromBGRABytes:(const uint8_t *)sourceBytes
                                            sourceBytesPerRow:(size_t)sourceBytesPerRow CF_RETURNS_RETAINED {
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn createStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pixelBufferPool, &pixelBuffer);
    if (createStatus != kCVReturnSuccess || !pixelBuffer) {
        os_log_error(fauxBufferLog(), "pool create pixel buffer failed status=%d", (int)createStatus);
        return NULL;
    }

    CVReturn lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    if (lockStatus != kCVReturnSuccess) {
        os_log_error(fauxBufferLog(), "lock base address failed status=%d", (int)lockStatus);
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }

    uint8_t *destinationBytes = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t destinationBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    size_t copyableBytesPerRow = MIN(sourceBytesPerRow, destinationBytesPerRow);
    size_t rowCount = (size_t)_height;

    for (size_t row = 0; row < rowCount; row++) {
        memcpy(destinationBytes + row * destinationBytesPerRow,
               sourceBytes + row * sourceBytesPerRow,
               copyableBytesPerRow);
    }

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return pixelBuffer;
}

- (nullable CVPixelBufferPoolRef)newPixelBufferPoolWithWidth:(int32_t)width
                                                     height:(int32_t)height CF_RETURNS_RETAINED {
    NSDictionary *pixelBufferAttributes = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey : @(kFauxPixelFormat),
        (NSString *)kCVPixelBufferWidthKey : @(width),
        (NSString *)kCVPixelBufferHeightKey : @(height),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
        (NSString *)kCVPixelBufferBytesPerRowAlignmentKey : @(kFauxBytesPerPixel * (size_t)width),
    };
    CVPixelBufferPoolRef pool = NULL;
    CVReturn status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                              NULL,
                                              (__bridge CFDictionaryRef)pixelBufferAttributes,
                                              &pool);
    if (status != kCVReturnSuccess) {
        os_log_error(fauxBufferLog(), "pool create failed status=%d", (int)status);
        return NULL;
    }
    return pool;
}

// MARK: - Timing

- (CMSampleTimingInfo)nextSampleTimingInfo {
    CMSampleTimingInfo timing;
    timing.duration = _frameDuration;
    timing.presentationTimeStamp = CMClockGetTime(_hostClock);
    timing.decodeTimeStamp = kCMTimeInvalid;
    return timing;
}

@end
