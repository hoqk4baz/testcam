#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <Photos/Photos.h>

// ─────────────────────────────────────────────
//  Forward declarations
// ─────────────────────────────────────────────
@class CIFrameInjector;
static CIFrameInjector *_injector = nil;

// ─────────────────────────────────────────────
//  CIFrameInjector – video okur, frame üretir
// ─────────────────────────────────────────────
@interface CIFrameInjector : NSObject
@property (nonatomic, strong) AVAssetReader          *reader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *trackOutput;
@property (nonatomic, strong) dispatch_queue_t        queue;
@property (nonatomic, weak)   id<AVCaptureVideoDataOutputSampleBufferDelegate> realDelegate;
@property (nonatomic, weak)   AVCaptureOutput        *captureOutput;
@property (nonatomic, weak)   AVCaptureConnection    *connection;
@property (nonatomic, assign) BOOL                   running;
@property (nonatomic, assign) CMTime                 frameDuration; // hedef FPS
- (void)startWithURL:(NSURL *)url;
- (void)stop;
@end

@implementation CIFrameInjector

- (instancetype)init {
    self = [super init];
    _queue = dispatch_queue_create("ci.frame.inject", DISPATCH_QUEUE_SERIAL);
    _frameDuration = CMTimeMake(1, 30); // 30 FPS varsayılan
    return self;
}

- (void)startWithURL:(NSURL *)url {
    [self stop];

    AVAsset *asset = [AVAsset assetWithURL:url];
    NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (tracks.count == 0) {
        NSLog(@"[CameraInject] ❌ Video track bulunamadı");
        return;
    }

    AVAssetTrack *track = tracks.firstObject;
    // Gerçek FPS'i al
    float fps = track.nominalFrameRate;
    if (fps > 0) self.frameDuration = CMTimeMake(1, (int32_t)fps);

    NSDictionary *outputSettings = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)
    };

    NSError *err = nil;
    self.reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
    if (err) { NSLog(@"[CameraInject] ❌ AssetReader: %@", err); return; }

    self.trackOutput = [AVAssetReaderTrackOutput
                        assetReaderTrackOutputWithTrack:track
                        outputSettings:outputSettings];
    self.trackOutput.supportsRandomAccess = YES;
    [self.reader addOutput:self.trackOutput];

    if (![self.reader startReading]) {
        NSLog(@"[CameraInject] ❌ Reader start failed: %@", self.reader.error);
        return;
    }

    self.running = YES;
    NSLog(@"[CameraInject] ✅ Frame injection başladı (%.0f FPS)", fps);
    [self pumpFrames];
}

- (void)pumpFrames {
    dispatch_async(self.queue, ^{
        while (self.running) {
            if (!self.realDelegate || !self.captureOutput) {
                [NSThread sleepForTimeInterval:0.05];
                continue;
            }

            CMSampleBufferRef sample = [self.trackOutput copyNextSampleBuffer];

            // Video bitti → başa sar
            if (!sample) {
                if (self.reader.status == AVAssetReaderStatusCompleted) {
                    [self rewind];
                    continue;
                }
                [NSThread sleepForTimeInterval:0.016];
                continue;
            }

            // Delegate'e ilet
            if ([self.realDelegate respondsToSelector:
                 @selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
                [self.realDelegate captureOutput:self.captureOutput
                           didOutputSampleBuffer:sample
                                  fromConnection:self.connection];
            }
            CFRelease(sample);

            // FPS hızında bekle
            double secs = CMTimeGetSeconds(self.frameDuration);
            [NSThread sleepForTimeInterval:secs];
        }
    });
}

- (void)rewind {
    NSLog(@"[CameraInject] 🔄 Video döngüsü yeniden başladı");
    [self.reader cancelReading];

    // trackOutput ve reader'ı yeniden kur (aynı asset üzerinde)
    AVAsset *asset = self.trackOutput.track.asset;
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!track) return;

    NSDictionary *outputSettings = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)
    };
    NSError *err = nil;
    self.reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
    self.trackOutput = [AVAssetReaderTrackOutput
                        assetReaderTrackOutputWithTrack:track
                        outputSettings:outputSettings];
    self.trackOutput.supportsRandomAccess = YES;
    [self.reader addOutput:self.trackOutput];
    [self.reader startReading];
}

- (void)stop {
    self.running = NO;
    [self.reader cancelReading];
    self.reader = nil;
    self.trackOutput = nil;
}

@end

// ─────────────────────────────────────────────
//  Galeri picker (uygulama penceresi üzerinde)
// ─────────────────────────────────────────────
@interface CIVideoPicker : NSObject <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
+ (void)presentPicker;
@end

@implementation CIVideoPicker

static CIVideoPicker *_pickerDelegate = nil;

+ (void)presentPicker {
    dispatch_async(dispatch_get_main_queue(), ^{
        _pickerDelegate = [CIVideoPicker new];

        UIImagePickerController *picker = [UIImagePickerController new];
        picker.sourceType   = UIImagePickerControllerSourceTypePhotoLibrary;
        picker.mediaTypes   = @[@"public.movie"];
        picker.delegate     = _pickerDelegate;
        picker.videoQuality = UIImagePickerControllerQualityTypeHigh;

        UIViewController *root = [UIApplication sharedApplication]
                                    .windows.firstObject.rootViewController;
        // Modal üst üste binmesin
        UIViewController *top = root;
        while (top.presentedViewController) top = top.presentedViewController;
        [top presentViewController:picker animated:YES completion:nil];
    });
}

- (void)imagePickerController:(UIImagePickerController *)picker
didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    NSURL *url = info[UIImagePickerControllerMediaURL];
    NSLog(@"[CameraInject] 🎬 Seçilen video: %@", url);
    [picker dismissViewControllerAnimated:YES completion:^{
        if (url) [_injector startWithURL:url];
    }];
    _pickerDelegate = nil;
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    NSLog(@"[CameraInject] ⚠️ Picker iptal edildi");
    [picker dismissViewControllerAnimated:YES completion:nil];
    _pickerDelegate = nil;
}

@end

// ─────────────────────────────────────────────
//  Proxy delegate – kamera frame'lerini bloklar,
//  injector'dan gelenler geçer
// ─────────────────────────────────────────────
@interface CIProxyDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> real;
@end

@implementation CIProxyDelegate

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)buf
       fromConnection:(AVCaptureConnection *)conn {
    // Injector aktifse kamera frame'ini yut, kendi frame'ini zaten pump ediyor
    if (_injector.running) {
        // Bağlantı referanslarını injector'a ver (ilk frame'de)
        if (!_injector.captureOutput)  _injector.captureOutput = output;
        if (!_injector.connection)     _injector.connection    = conn;
        return; // kamera frame'ini geçirme
    }
    // Injector pasifse normal davran
    if ([self.real respondsToSelector:_cmd])
        [self.real captureOutput:output didOutputSampleBuffer:buf fromConnection:conn];
}

- (void)captureOutput:(AVCaptureOutput *)o
  didDropSampleBuffer:(CMSampleBufferRef)b
       fromConnection:(AVCaptureConnection *)c {
    if ([self.real respondsToSelector:_cmd])
        [self.real captureOutput:o didDropSampleBuffer:b fromConnection:c];
}

- (BOOL)respondsToSelector:(SEL)s {
    return [super respondsToSelector:s] || [self.real respondsToSelector:s];
}
- (id)forwardingTargetForSelector:(SEL)s { return self.real; }

@end

// ─────────────────────────────────────────────
//  AVCaptureVideoDataOutput hook
// ─────────────────────────────────────────────
static CIProxyDelegate *_proxyDelegate = nil;

@interface AVCaptureVideoDataOutput (CI) @end
@implementation AVCaptureVideoDataOutput (CI)

- (void)ci_setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)del
                             queue:(dispatch_queue_t)q {
    if (del && ![del isKindOfClass:[CIProxyDelegate class]]) {
        NSLog(@"[CameraInject] 🔗 setSampleBufferDelegate intercept: %@",
              NSStringFromClass([del class]));

        if (!_proxyDelegate) _proxyDelegate = [CIProxyDelegate new];
        _proxyDelegate.real     = del;
        _injector.realDelegate  = del;

        [self ci_setSampleBufferDelegate:_proxyDelegate queue:q];
    } else {
        [self ci_setSampleBufferDelegate:del queue:q];
    }
}

+ (void)load {
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        Class cls = [AVCaptureVideoDataOutput class];
        Method o = class_getInstanceMethod(cls, @selector(setSampleBufferDelegate:queue:));
        Method s = class_getInstanceMethod(cls, @selector(ci_setSampleBufferDelegate:queue:));
        if (o && s) method_exchangeImplementations(o, s);
    });
}
@end

// ─────────────────────────────────────────────
//  Yüzen kontrol butonu (sağ üst köşe)
// ─────────────────────────────────────────────
@interface CIControlButton : UIWindow
@end

@implementation CIControlButton

+ (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        static CIControlButton *w;
        if (w) return;
        w = [[CIControlButton alloc] initWithFrame:CGRectMake(
            [UIScreen mainScreen].bounds.size.width - 70, 60, 60, 60)];
        w.windowLevel = UIWindowLevelAlert + 200;
        w.backgroundColor = [UIColor clearColor];

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(0, 0, 60, 60);
        btn.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.85];
        btn.layer.cornerRadius = 30;
        btn.layer.borderColor  = [UIColor colorWithWhite:1 alpha:0.2].CGColor;
        btn.layer.borderWidth  = 1;
        [btn setTitle:@"🎬" forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:26];
        [btn addTarget:w action:@selector(btnTapped) forControlEvents:UIControlEventTouchUpInside];
        [w addSubview:btn];

        // Sürüklenebilir
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                       initWithTarget:w action:@selector(handlePan:)];
        [btn addGestureRecognizer:pan];

        [w makeKeyAndVisible];
    });
}

- (void)btnTapped {
    if (_injector.running) {
        // Dur
        [_injector stop];
        NSLog(@"[CameraInject] ⏹ Injection durduruldu");
        UIButton *btn = self.subviews.firstObject;
        [btn setTitle:@"🎬" forState:UIControlStateNormal];
        btn.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.85];
    } else {
        // Galeri aç
        [CIVideoPicker presentPicker];
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    static CGPoint offset;
    CGPoint pt = [pan locationInView:nil];
    if (pan.state == UIGestureRecognizerStateBegan)
        offset = CGPointMake(pt.x - self.frame.origin.x, pt.y - self.frame.origin.y);
    else if (pan.state == UIGestureRecognizerStateChanged)
        self.frame = CGRectMake(pt.x - offset.x, pt.y - offset.y, 60, 60);
}

- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *h = [super hitTest:p withEvent:e];
    return h == self ? nil : h;
}

@end

// ─────────────────────────────────────────────
//  Injector'ı takip et → buton rengi güncelle
// ─────────────────────────────────────────────
static void updateButtonState(BOOL injecting) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // İlk subview UIWindow, onun ilk subview'i UIButton
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if ([w isKindOfClass:[CIControlButton class]]) {
                UIButton *btn = w.subviews.firstObject;
                if (injecting) {
                    [btn setTitle:@"⏹" forState:UIControlStateNormal];
                    btn.backgroundColor = [UIColor colorWithRed:0.8 green:0.1 blue:0.1 alpha:0.9];
                } else {
                    [btn setTitle:@"🎬" forState:UIControlStateNormal];
                    btn.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.85];
                }
                break;
            }
        }
    });
}

// ─────────────────────────────────────────────
//  Constructor
// ─────────────────────────────────────────────
__attribute__((constructor))
static void CIInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        _injector = [CIFrameInjector new];
        [CIControlButton show];
        NSLog(@"[CameraInject] ✅ Dylib yüklendi — 🎬 butonuna bas, video seç");
    });
}
