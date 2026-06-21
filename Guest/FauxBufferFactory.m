#import "FauxBufferFactory.h"

@import ObjectiveC.runtime;
@import os.log;
@import CoreImage;

static const OSType kFauxPixelFormat = kCVPixelFormatType_32BGRA;
static const size_t kFauxBytesPerPixel = 4;
static const int32_t kFauxMinimumFramesPerSecond = 1;

static os_log_t fauxBufferLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.fauxcam", "buffers"); });
    return log;
}

static BOOL fauxIsSupportedOutputFormat(OSType format) {
    return format == kCVPixelFormatType_32BGRA
        || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
}

@implementation FauxBufferFactory {
    OSType _pixelFormat;            // requested output format
    CVPixelBufferPoolRef _bgraPool; // staging pool (source bytes are always BGRA)
    CVPixelBufferPoolRef _targetPool; // output pool in _pixelFormat (== _bgraPool when BGRA)
    CIContext *_ciContext;          // only for non-BGRA conversion
    int32_t _framesPerSecond;
    CMTime _frameDuration;
    CMClockRef _hostClock;
}

// MARK: - Lifecycle

- (nullable instancetype)initWithWidth:(int32_t)width
                                height:(int32_t)height
                       framesPerSecond:(int32_t)framesPerSecond {
    return [self initWithWidth:width height:height framesPerSecond:framesPerSecond pixelFormat:kFauxPixelFormat];
}

- (nullable instancetype)initWithWidth:(int32_t)width
                                height:(int32_t)height
                       framesPerSecond:(int32_t)framesPerSecond
                           pixelFormat:(OSType)pixelFormat {
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
    _pixelFormat = fauxIsSupportedOutputFormat(pixelFormat) ? pixelFormat : kFauxPixelFormat;

    _bgraPool = [self newPixelBufferPoolWithFormat:kFauxPixelFormat width:width height:height];
    if (!_bgraPool) {
        os_log_error(fauxBufferLog(), "BGRA pixel buffer pool create failed");
        return nil;
    }
    if (_pixelFormat == kFauxPixelFormat) {
        _targetPool = (CVPixelBufferPoolRef)CVPixelBufferPoolRetain(_bgraPool);
    } else {
        _targetPool = [self newPixelBufferPoolWithFormat:_pixelFormat width:width height:height];
        if (!_targetPool) {
            os_log_error(fauxBufferLog(), "target pool create failed, falling back to BGRA");
            _pixelFormat = kFauxPixelFormat;
            _targetPool = (CVPixelBufferPoolRef)CVPixelBufferPoolRetain(_bgraPool);
        } else {
            _ciContext = [CIContext contextWithOptions:nil];
        }
    }
    return self;
}

- (void)dealloc {
    if (_bgraPool) { CVPixelBufferPoolRelease(_bgraPool); _bgraPool = NULL; }
    if (_targetPool) { CVPixelBufferPoolRelease(_targetPool); _targetPool = NULL; }
}

// MARK: - Sample buffer construction

- (nullable CMSampleBufferRef)newSampleBufferFromBGRABytes:(const uint8_t *)sourceBytes
                                        sourceBytesPerRow:(size_t)sourceBytesPerRow
                                             sourceLength:(size_t)sourceLength {
    if (!sourceBytes) return NULL;
    if (sourceBytesPerRow == 0 || sourceBytesPerRow * (size_t)_height > sourceLength) {
        os_log_error(fauxBufferLog(), "source too small w=%d h=%d stride=%zu length=%zu", _width, _height, sourceBytesPerRow, sourceLength);
        return NULL;
    }

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
    CVPixelBufferRef bgraBuffer = NULL;
    CVReturn createStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _bgraPool, &bgraBuffer);
    if (createStatus != kCVReturnSuccess || !bgraBuffer) {
        os_log_error(fauxBufferLog(), "pool create pixel buffer failed status=%d", (int)createStatus);
        return NULL;
    }

    CVReturn lockStatus = CVPixelBufferLockBaseAddress(bgraBuffer, 0);
    if (lockStatus != kCVReturnSuccess) {
        os_log_error(fauxBufferLog(), "lock base address failed status=%d", (int)lockStatus);
        CVPixelBufferRelease(bgraBuffer);
        return NULL;
    }

    uint8_t *destinationBytes = CVPixelBufferGetBaseAddress(bgraBuffer);
    size_t destinationBytesPerRow = CVPixelBufferGetBytesPerRow(bgraBuffer);
    size_t copyableBytesPerRow = MIN(sourceBytesPerRow, destinationBytesPerRow);
    size_t rowCount = (size_t)_height;

    for (size_t row = 0; row < rowCount; row++) {
        memcpy(destinationBytes + row * destinationBytesPerRow,
               sourceBytes + row * sourceBytesPerRow,
               copyableBytesPerRow);
    }

    CVPixelBufferUnlockBaseAddress(bgraBuffer, 0);

    if (_pixelFormat == kFauxPixelFormat) {
        return bgraBuffer;
    }

    // Convert BGRA -> requested (4:2:0) format via CoreImage.
    CVPixelBufferRef targetBuffer = NULL;
    CVReturn targetStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _targetPool, &targetBuffer);
    if (targetStatus != kCVReturnSuccess || !targetBuffer) {
        os_log_error(fauxBufferLog(), "target pool create failed status=%d", (int)targetStatus);
        return bgraBuffer; // fall back to BGRA rather than dropping the frame
    }
    CIImage *image = [CIImage imageWithCVPixelBuffer:bgraBuffer];
    [_ciContext render:image toCVPixelBuffer:targetBuffer];
    CVPixelBufferRelease(bgraBuffer);
    return targetBuffer;
}

- (nullable CVPixelBufferPoolRef)newPixelBufferPoolWithFormat:(OSType)format
                                                       width:(int32_t)width
                                                      height:(int32_t)height CF_RETURNS_RETAINED {
    NSMutableDictionary *pixelBufferAttributes = [@{
        (NSString *)kCVPixelBufferPixelFormatTypeKey : @(format),
        (NSString *)kCVPixelBufferWidthKey : @(width),
        (NSString *)kCVPixelBufferHeightKey : @(height),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
    } mutableCopy];
    if (format == kCVPixelFormatType_32BGRA) {
        pixelBufferAttributes[(NSString *)kCVPixelBufferBytesPerRowAlignmentKey] = @(kFauxBytesPerPixel * (size_t)width);
    }
    CVPixelBufferPoolRef pool = NULL;
    CVReturn status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                              NULL,
                                              (__bridge CFDictionaryRef)pixelBufferAttributes,
                                              &pool);
    if (status != kCVReturnSuccess) {
        os_log_error(fauxBufferLog(), "pool create failed status=%d format=%u", (int)status, (unsigned)format);
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
