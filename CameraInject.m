#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

// ─────────────────────────────────────────────
//  Forward
// ─────────────────────────────────────────────
@class CIFrameInjector;
static CIFrameInjector *_injector = nil;
static UIWindow        *_floatWin = nil;

// ─────────────────────────────────────────────
//  CIFrameInjector
// ─────────────────────────────────────────────
@interface CIFrameInjector : NSObject
@property (nonatomic, strong) AVAssetReader             *reader;
@property (nonatomic, strong) AVAssetReaderTrackOutput  *trackOutput;
@property (nonatomic, strong) AVAsset                   *asset;
@property (nonatomic, strong) dispatch_queue_t           queue;
@property (nonatomic, weak)   id<AVCaptureVideoDataOutputSampleBufferDelegate> realDelegate;
@property (nonatomic, weak)   AVCaptureOutput           *captureOutput;
@property (nonatomic, weak)   AVCaptureConnection       *connection;
@property (nonatomic, assign) BOOL                       running;
@property (nonatomic, assign) CMTime                     frameDuration;
- (void)startWithURL:(NSURL *)url;
- (void)stop;
@end

@implementation CIFrameInjector

- (instancetype)init {
    self = [super init];
    _queue = dispatch_queue_create("ci.inject", DISPATCH_QUEUE_SERIAL);
    _frameDuration = CMTimeMake(1, 30);
    return self;
}

- (BOOL)setupReaderForAsset:(AVAsset *)asset {
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!track) return NO;

    float fps = track.nominalFrameRate;
    if (fps > 1) self.frameDuration = CMTimeMake(1, (int32_t)fps);

    NSError *err = nil;
    self.reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
    if (err || !self.reader) return NO;

    self.trackOutput = [AVAssetReaderTrackOutput
                        assetReaderTrackOutputWithTrack:track
                        outputSettings:@{(NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
    self.trackOutput.supportsRandomAccess = YES;
    [self.reader addOutput:self.trackOutput];
    return [self.reader startReading];
}

- (void)startWithURL:(NSURL *)url {
    [self stop];
    self.asset = [AVAsset assetWithURL:url];
    if (![self setupReaderForAsset:self.asset]) {
        NSLog(@"[CI] ❌ Reader kurulamadı"); return;
    }
    self.running = YES;
    NSLog(@"[CI] ✅ Injection başladı");
    [self pump];
}

- (void)pump {
    dispatch_async(self.queue, ^{
        while (self.running) {
            if (!self.realDelegate || !self.captureOutput) {
                [NSThread sleepForTimeInterval:0.05]; continue;
            }

            CMSampleBufferRef sample = [self.trackOutput copyNextSampleBuffer];

            if (!sample) {
                // Bitti → başa sar
                if (![self setupReaderForAsset:self.asset]) {
                    [NSThread sleepForTimeInterval:0.1];
                }
                continue;
            }

            if ([self.realDelegate respondsToSelector:
                 @selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
                [self.realDelegate captureOutput:self.captureOutput
                           didOutputSampleBuffer:sample
                                  fromConnection:self.connection];
            }
            CFRelease(sample);
            [NSThread sleepForTimeInterval:CMTimeGetSeconds(self.frameDuration)];
        }
    });
}

- (void)stop {
    self.running = NO;
    [self.reader cancelReading];
    self.reader = nil; self.trackOutput = nil;
    self.captureOutput = nil; self.connection = nil;
}
@end

// ─────────────────────────────────────────────
//  Proxy delegate
// ─────────────────────────────────────────────
@interface CIProxyDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> real;
@end
@implementation CIProxyDelegate
- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)buf
       fromConnection:(AVCaptureConnection *)conn {
    if (_injector.running) {
        if (!_injector.captureOutput) _injector.captureOutput = output;
        if (!_injector.connection)    _injector.connection    = conn;
        return; // kamera frame'ini yut
    }
    if ([self.real respondsToSelector:_cmd])
        [self.real captureOutput:output didOutputSampleBuffer:buf fromConnection:conn];
}
- (void)captureOutput:(AVCaptureOutput *)o didDropSampleBuffer:(CMSampleBufferRef)b fromConnection:(AVCaptureConnection *)c {
    if ([self.real respondsToSelector:_cmd])
        [self.real captureOutput:o didDropSampleBuffer:b fromConnection:c];
}
- (BOOL)respondsToSelector:(SEL)s { return [super respondsToSelector:s]||[self.real respondsToSelector:s]; }
- (id)forwardingTargetForSelector:(SEL)s { return self.real; }
@end

static CIProxyDelegate *_proxy = nil;

@interface AVCaptureVideoDataOutput (CI) @end
@implementation AVCaptureVideoDataOutput (CI)
- (void)ci_setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)del queue:(dispatch_queue_t)q {
    if (del && ![del isKindOfClass:[CIProxyDelegate class]]) {
        if (!_proxy) _proxy = [CIProxyDelegate new];
        _proxy.real = del;
        _injector.realDelegate = del;
        [self ci_setSampleBufferDelegate:_proxy queue:q];
    } else {
        [self ci_setSampleBufferDelegate:del queue:q];
    }
}
+ (void)load {
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        Method o = class_getInstanceMethod(self, @selector(setSampleBufferDelegate:queue:));
        Method s = class_getInstanceMethod(self, @selector(ci_setSampleBufferDelegate:queue:));
        if (o&&s) method_exchangeImplementations(o,s);
    });
}
@end

// ─────────────────────────────────────────────
//  Video picker delegate (strong ref)
// ─────────────────────────────────────────────
@interface CIFloatBubble : NSObject
+ (void)show;
+ (void)updateState;
@end

@interface CIPickerDelegate : NSObject <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@end
@implementation CIPickerDelegate
- (void)imagePickerController:(UIImagePickerController *)picker
didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    NSURL *url = info[UIImagePickerControllerMediaURL];
    [picker dismissViewControllerAnimated:YES completion:^{
        if (url) [_injector startWithURL:url];
        [CIFloatBubble updateState];
    }];
}
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}
@end
static CIPickerDelegate *_pickerDelegate = nil;

// ─────────────────────────────────────────────
//  En üstteki VC'yi bul
// ─────────────────────────────────────────────
static UIViewController *topVC(void) {
    UIViewController *vc = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow && ![w isKindOfClass:NSClassFromString(@"CIFloatWindow")]) {
            vc = w.rootViewController; break;
        }
    }
    // Fallback: ilk normal window
    if (!vc) vc = [UIApplication sharedApplication].windows.firstObject.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

// ─────────────────────────────────────────────
//  Yüzen balon — ayrı UIWindow, drag düzeltildi
// ─────────────────────────────────────────────
@interface CIFloatWindow : UIWindow
@property (nonatomic, strong) UIButton  *btn;
@property (nonatomic, assign) CGPoint    touchOffset;  // dokunuş anındaki offset
@property (nonatomic, assign) BOOL       dragging;
@end

@implementation CIFloatWindow

- (instancetype)initBubble {
    CGSize sc = [UIScreen mainScreen].bounds.size;
    self = [super initWithFrame:CGRectMake(sc.width - 70, 80, 56, 56)];
    if (!self) return nil;
    self.windowLevel = UIWindowLevelAlert + 500;
    self.backgroundColor = [UIColor clearColor];
    self.layer.zPosition = 9999;

    self.btn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.btn.frame = self.bounds;
    self.btn.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.08 alpha:0.88];
    self.btn.layer.cornerRadius = 28;
    self.btn.layer.borderWidth  = 1.5;
    self.btn.layer.borderColor  = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    self.btn.layer.shadowColor  = [UIColor blackColor].CGColor;
    self.btn.layer.shadowOpacity = 0.4;
    self.btn.layer.shadowOffset  = CGSizeMake(0, 2);
    self.btn.layer.shadowRadius  = 6;
    [self.btn setTitle:@"🎬" forState:UIControlStateNormal];
    self.btn.titleLabel.font = [UIFont systemFontOfSize:24];
    // tap ve drag ayrı — UIButton'a dokunuş geçirme, window'dan yakala
    [self addSubview:self.btn];

    [self makeKeyAndVisible];
    // ana window'u tekrar key yap
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (![w isKindOfClass:[CIFloatWindow class]]) { [w makeKeyWindow]; break; }
        }
    });
    return self;
}

// Touch'ları window seviyesinde yakala → titreme yok
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    CGPoint loc = [t locationInView:nil]; // ekran koordinatı
    self.touchOffset = CGPointMake(loc.x - self.frame.origin.x,
                                   loc.y - self.frame.origin.y);
    self.dragging = NO;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    CGPoint loc = [t locationInView:nil];
    CGFloat newX = loc.x - self.touchOffset.x;
    CGFloat newY = loc.y - self.touchOffset.y;

    // Ekran sınırları içinde tut
    CGSize sc = [UIScreen mainScreen].bounds.size;
    newX = MAX(0, MIN(sc.width  - self.frame.size.width,  newX));
    newY = MAX(20, MIN(sc.height - self.frame.size.height, newY));

    self.frame = CGRectMake(newX, newY, self.frame.size.width, self.frame.size.height);
    self.dragging = YES;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!self.dragging) {
        // Tap
        [self handleTap];
    }
}

- (void)handleTap {
    if (_injector.running) {
        [_injector stop];
        [CIFloatBubble updateState];
    } else {
        UIViewController *vc = topVC();
        if (!vc) { NSLog(@"[CI] ❌ rootVC bulunamadı"); return; }

        UIImagePickerController *picker = [UIImagePickerController new];
        picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        picker.mediaTypes = @[@"public.movie"];
        picker.videoQuality = UIImagePickerControllerQualityTypeHigh;
        if (!_pickerDelegate) _pickerDelegate = [CIPickerDelegate new];
        picker.delegate = _pickerDelegate;
        [vc presentViewController:picker animated:YES completion:nil];
    }
}

// Sadece kendi subview'larına hit-test yap, dışarısı app'e gitsin
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // Kendi frame'i içindeyse self döndür (touch'ları biz yakalarız)
    if (CGRectContainsPoint(self.bounds, point)) return self;
    return nil;
}

@end

@implementation CIFloatBubble

static CIFloatWindow *_win = nil;

+ (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_win) return;
        _win = [[CIFloatWindow alloc] initBubble];
    });
}

+ (void)updateState {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!_win) return;
        if (_injector.running) {
            [_win.btn setTitle:@"⏹" forState:UIControlStateNormal];
            _win.btn.backgroundColor = [UIColor colorWithRed:0.75 green:0.1 blue:0.1 alpha:0.92];
        } else {
            [_win.btn setTitle:@"🎬" forState:UIControlStateNormal];
            _win.btn.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.08 alpha:0.88];
        }
    });
}

@end

// ─────────────────────────────────────────────
//  Constructor
// ─────────────────────────────────────────────
__attribute__((constructor))
static void CIInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        _injector = [CIFrameInjector new];
        [CIFloatBubble show];
        NSLog(@"[CI] ✅ CameraInject hazır — 🎬 butonuna bas");
    });
}
