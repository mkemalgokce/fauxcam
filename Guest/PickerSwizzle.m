#include "PickerSwizzle.h"
#include "FrameClient.h"
#include "FauxConfig.h"
#include "../Shared/faux_wire.h"

@import UIKit;
@import os.log;
@import ObjectiveC.runtime;
@import ObjectiveC.message;

#include <unistd.h>

static os_log_t fauxPickerLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.fauxcam", "picker"); });
    return log;
}

static UIImage *fauxImageFromBGRA(const uint8_t *bytes, uint32_t width, uint32_t height, uint32_t bytesPerRow) {
    if (!bytes || width == 0 || height == 0) return nil;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate((void *)bytes, width, height, 8, bytesPerRow, colorSpace,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(colorSpace);
    if (!context) return nil;
    CGImageRef cgImage = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (!cgImage) return nil;
    UIImage *image = [UIImage imageWithCGImage:cgImage];
    CGImageRelease(cgImage);
    return image;
}

// MARK: - Live capture overlay

/// A full-cover view dropped onto a `.camera` UIImagePickerController. It streams frames from the
/// FauxCam socket into a preview and hands the current frame back through `onCapture` (or `onCancel`),
/// hiding the Simulator's absent hardware camera entirely.
@interface FauxCameraOverlayView : UIView
@property (nonatomic, copy) void (^onCapture)(UIImage *image);
@property (nonatomic, copy) void (^onCancel)(void);
- (void)startStreaming;
- (void)stopStreaming;
@end

@implementation FauxCameraOverlayView {
    UIImageView *_previewImageView;
    UILabel *_waitingLabel;
    UIButton *_shutterButton;
    UIButton *_cancelButton;
    UIImage *_latestImage;
    faux_frame_client *_frameClient;
    BOOL _streaming;
    BOOL _loggedFirstFrame;
    int32_t _width;
    int32_t _height;
    int32_t _framesPerSecond;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _width = faux_config_width();
        _height = faux_config_height();
        _framesPerSecond = faux_config_fps();
        self.backgroundColor = UIColor.blackColor;

        _previewImageView = [[UIImageView alloc] init];
        _previewImageView.contentMode = UIViewContentModeScaleAspectFit;
        _previewImageView.backgroundColor = UIColor.blackColor;
        [self addSubview:_previewImageView];

        _waitingLabel = [[UILabel alloc] init];
        _waitingLabel.text = @"Waiting for FauxCam…";
        _waitingLabel.textColor = UIColor.whiteColor;
        _waitingLabel.textAlignment = NSTextAlignmentCenter;
        [self addSubview:_waitingLabel];

        _shutterButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _shutterButton.backgroundColor = UIColor.whiteColor;
        _shutterButton.layer.cornerRadius = 34;
        _shutterButton.layer.borderColor = UIColor.lightGrayColor.CGColor;
        _shutterButton.layer.borderWidth = 4;
        [_shutterButton addTarget:self action:@selector(handleCapture) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_shutterButton];

        _cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_cancelButton setTitle:@"Cancel" forState:UIControlStateNormal];
        [_cancelButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        _cancelButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        [_cancelButton addTarget:self action:@selector(handleCancel) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_cancelButton];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    _previewImageView.frame = bounds;
    [_waitingLabel sizeToFit];
    _waitingLabel.center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    UIEdgeInsets safe = self.safeAreaInsets;
    CGFloat shutterSize = 68;
    _shutterButton.frame = CGRectMake((bounds.size.width - shutterSize) / 2,
                                      bounds.size.height - safe.bottom - shutterSize - 28,
                                      shutterSize, shutterSize);
    _cancelButton.frame = CGRectMake(16, safe.top + 8, 88, 36);
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) [self stopStreaming];
}

- (void)startStreaming {
    if (_streaming) return;
    _streaming = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [self pumpLoop]; });
}

- (void)stopStreaming {
    _streaming = NO;
}

- (void)pumpLoop {
    while (_streaming) {
        if (!_frameClient && ![self connectFrameClient]) {
            usleep(200000);
            continue;
        }
        if (faux_frame_client_send_demand(_frameClient, FAUX_POSITION_BACK,
                                          (uint32_t)_width, (uint32_t)_height,
                                          (uint32_t)_framesPerSecond, FAUX_PIXEL_FORMAT_BGRA32) != 0) {
            [self dropFrameClient];
            continue;
        }
        faux_received_frame received;
        if (faux_frame_client_recv_frame(_frameClient, &received) != 0) {
            [self dropFrameClient];
            continue;
        }
        UIImage *image = fauxImageFromBGRA(received.payload, received.header.width,
                                           received.header.height, received.header.bytesPerRow);
        faux_received_frame_free(&received);
        if (!image) continue;
        if (!_loggedFirstFrame) {
            _loggedFirstFrame = YES;
            os_log(fauxPickerLog(), "overlay first frame %ux%u", received.header.width, received.header.height);
        }
        @synchronized(self) { _latestImage = image; }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_previewImageView.image = image;
            self->_waitingLabel.hidden = YES;
        });
    }
    [self dropFrameClient];
}

- (BOOL)connectFrameClient {
    const char *socketPath = getenv("FAUXCAM_SOCKET");
    if (!socketPath || socketPath[0] == '\0') socketPath = FAUX_AUTO_SOCKET;
    _frameClient = faux_frame_client_create();
    if (_frameClient
        && faux_frame_client_connect(_frameClient, socketPath) == 0
        && faux_frame_client_send_hello(_frameClient) == 0) {
        os_log(fauxPickerLog(), "overlay connected to %{public}s", socketPath);
        return YES;
    }
    [self dropFrameClient];
    return NO;
}

- (void)dropFrameClient {
    if (_frameClient) {
        faux_frame_client_destroy(_frameClient);
        _frameClient = NULL;
    }
}

- (void)handleCapture {
    UIImage *image;
    @synchronized(self) { image = _latestImage; }
    if (!image) return;
    [self stopStreaming];
    os_log(fauxPickerLog(), "overlay capture (%.0fx%.0f)", image.size.width, image.size.height);
    if (self.onCapture) self.onCapture(image);
}

- (void)handleCancel {
    [self stopStreaming];
    if (self.onCancel) self.onCancel();
}

- (void)dealloc {
    [self dropFrameClient];
}

@end

// MARK: - Swizzles

static const void *kOverlayInstalledKey = &kOverlayInstalledKey;

static IMP fauxOriginalIsSourceTypeAvailable;
static IMP fauxOriginalAvailableMediaTypes;
static IMP fauxOriginalPickerViewDidAppear;

static BOOL fauxIsSourceTypeAvailable(id self, SEL _cmd, NSInteger sourceType) {
    if (sourceType == UIImagePickerControllerSourceTypeCamera) return YES;
    if (fauxOriginalIsSourceTypeAvailable) {
        return ((BOOL (*)(id, SEL, NSInteger))fauxOriginalIsSourceTypeAvailable)(self, _cmd, sourceType);
    }
    return NO;
}

static id fauxAvailableMediaTypes(id self, SEL _cmd, NSInteger sourceType) {
    id result = nil;
    if (fauxOriginalAvailableMediaTypes) {
        result = ((id (*)(id, SEL, NSInteger))fauxOriginalAvailableMediaTypes)(self, _cmd, sourceType);
    }
    if (sourceType == UIImagePickerControllerSourceTypeCamera && [result count] == 0) {
        return @[ @"public.image", @"public.movie" ];
    }
    return result;
}

/// Once a `.camera` picker is on screen, cover it with the FauxCam overlay and route the overlay's
/// result through the picker's own delegate — passing the real picker so the app's
/// `picker.dismiss(animated:completion:)` (and its completion block) behave exactly as with a device.
static void fauxPickerViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (fauxOriginalPickerViewDidAppear) {
        ((void (*)(id, SEL, BOOL))fauxOriginalPickerViewDidAppear)(self, _cmd, animated);
    }
    NSInteger sourceType = ((NSInteger (*)(id, SEL))objc_msgSend)(self, @selector(sourceType));
    if (sourceType != UIImagePickerControllerSourceTypeCamera) return;
    if (objc_getAssociatedObject(self, kOverlayInstalledKey)) return;
    objc_setAssociatedObject(self, kOverlayInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *contentView = ((UIView * (*)(id, SEL))objc_msgSend)(self, @selector(view));
    FauxCameraOverlayView *overlay = [[FauxCameraOverlayView alloc] initWithFrame:contentView.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    __weak id weakPicker = self;
    overlay.onCapture = ^(UIImage *image) {
        id picker = weakPicker;
        if (!picker) return;
        id delegate = ((id (*)(id, SEL))objc_msgSend)(picker, @selector(delegate));
        NSDictionary *info = @{
            UIImagePickerControllerOriginalImage: image,
            UIImagePickerControllerMediaType: @"public.image"
        };
        if ([delegate respondsToSelector:@selector(imagePickerController:didFinishPickingMediaWithInfo:)]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(
                delegate, @selector(imagePickerController:didFinishPickingMediaWithInfo:), picker, info);
        } else {
            ((void (*)(id, SEL, BOOL, id))objc_msgSend)(
                picker, @selector(dismissViewControllerAnimated:completion:), YES, (id)nil);
        }
    };
    overlay.onCancel = ^{
        id picker = weakPicker;
        if (!picker) return;
        id delegate = ((id (*)(id, SEL))objc_msgSend)(picker, @selector(delegate));
        if ([delegate respondsToSelector:@selector(imagePickerControllerDidCancel:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(delegate, @selector(imagePickerControllerDidCancel:), picker);
        } else {
            ((void (*)(id, SEL, BOOL, id))objc_msgSend)(
                picker, @selector(dismissViewControllerAnimated:completion:), YES, (id)nil);
        }
    };

    [contentView addSubview:overlay];
    objc_setAssociatedObject(self, kOverlayInstalledKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [overlay startStreaming];
    os_log(fauxPickerLog(), "camera overlay installed on UIImagePickerController");
}

static IMP fauxReplaceInstanceMethod(Class targetClass, SEL selector, IMP implementation, const char *fallbackTypes) {
    Method existing = class_getInstanceMethod(targetClass, selector);
    const char *types = existing ? method_getTypeEncoding(existing) : fallbackTypes;
    IMP original = existing ? method_getImplementation(existing) : NULL;
    if (!class_addMethod(targetClass, selector, implementation, types)) {
        original = method_setImplementation(class_getInstanceMethod(targetClass, selector), implementation);
    }
    return original;
}

static IMP fauxReplaceClassMethod(Class targetClass, SEL selector, IMP implementation, const char *fallbackTypes) {
    Class metaClass = object_getClass((id)targetClass);
    Method existing = class_getClassMethod(targetClass, selector);
    const char *types = existing ? method_getTypeEncoding(existing) : fallbackTypes;
    IMP original = existing ? method_getImplementation(existing) : NULL;
    if (!class_addMethod(metaClass, selector, implementation, types)) {
        original = method_setImplementation(class_getClassMethod(targetClass, selector), implementation);
    }
    return original;
}

// Success-gated so the dyld add-image retry can install once UIKit loads.
void FauxInstallImagePickerCamera(void) {
    static BOOL sInstalled = NO;
    if (sInstalled) return;
    Class pickerClass = objc_getClass("UIImagePickerController");
    if (!pickerClass) return;
    fauxOriginalIsSourceTypeAvailable = fauxReplaceClassMethod(pickerClass, @selector(isSourceTypeAvailable:), (IMP)fauxIsSourceTypeAvailable, "B@:q");
    fauxOriginalAvailableMediaTypes = fauxReplaceClassMethod(pickerClass, @selector(availableMediaTypesForSourceType:), (IMP)fauxAvailableMediaTypes, "@@:q");
    fauxOriginalPickerViewDidAppear = fauxReplaceInstanceMethod(pickerClass, @selector(viewDidAppear:), (IMP)fauxPickerViewDidAppear, "v@:B");
    os_log(fauxPickerLog(), "UIImagePickerController camera interception installed");
    sInstalled = YES;
}
