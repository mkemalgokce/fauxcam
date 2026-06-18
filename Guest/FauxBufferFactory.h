#ifndef FAUX_BUFFER_FACTORY_H
#define FAUX_BUFFER_FACTORY_H

@import Foundation;
@import CoreMedia;
@import CoreVideo;

NS_ASSUME_NONNULL_BEGIN

@interface FauxBufferFactory : NSObject

- (nullable instancetype)initWithWidth:(int32_t)width
                                height:(int32_t)height
                       framesPerSecond:(int32_t)framesPerSecond;

- (nullable CMSampleBufferRef)newSampleBufferFromBGRABytes:(const uint8_t *)sourceBytes
                                        sourceBytesPerRow:(size_t)sourceBytesPerRow
                                             sourceLength:(size_t)sourceLength
    CF_RETURNS_RETAINED;

@property (nonatomic, readonly) int32_t width;
@property (nonatomic, readonly) int32_t height;

@end

NS_ASSUME_NONNULL_END

#endif
