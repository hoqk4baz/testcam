#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

// ─────────────────────────────────────────────
//  Globals
// ─────────────────────────────────────────────
static id  _injector       = nil;
static id  _proxy          = nil;
static id  _pickerDelegate = nil;

// ─────────────────────────────────────────────
//  CIFrameInjector
// ─────────────────────────────────────────────
@interface CIFrameInjector : NSObject
@property (nonatomic, strong) AVAsset                  *asset;
@property (nonatomic, strong) AVAssetReader            *reader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *trackOut;
@property (nonatomic, strong) dispatch_queue_t          q;
@property (nonatomic, weak)   id<AVCaptureVideoDataOutputSampleBufferDelegate> realDelegate;
@property (nonatomic, weak)   AVCaptureOutput          *capOut;
@property (nonatomic, weak)   AVCaptureConnection      *conn;
@property (nonatomic, assign) BOOL                      running;
@property (nonatomic, assign) CMTime                    frameDur;
- (void)startWithURL:(NSURL *)url;
- (void)stop;
@end

@implementation CIFrameInjector
- (instancetype)init {
    self = [super init];
    _q = dispatch_queue_create("ci.inject", DISPATCH_QUEUE_SERIAL);
    _frameDur = CMTimeMake(1, 30);
    return self;
}
- (BOOL)buildReader {
    AVAssetTrack *track = [self.asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!track) return NO;
    float fps = track.nominalFrameRate;
    if (fps > 1) self.frameDur = CMTimeMake(1, (int32_t)fps);
    NSError *e = nil;
    self.reader = [AVAssetReader assetReaderWithAsset:self.asset error:&e];
    if (!self.reader) return NO;
    self.trackOut = [AVAssetReaderTrackOutput
        assetReaderTrackOutputWithTrack:track
        outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];
    self.trackOut.supportsRandomAccess = YES;
    [self.reader addOutput:self.trackOut];
    return [self.reader startReading];
}
- (void)startWithURL:(NSURL *)url {
    [self stop];
    self.asset = [AVAsset assetWithURL:url];
    if (![self buildReader]) { NSLog(@"[CI] ❌ reader failed"); return; }
    self.running = YES;
    NSLog(@"[CI] ▶ injection started");
    dispatch_async(self.q, ^{ [self loop]; });
}
- (void)loop {
    while (self.running) {
        if (!self.realDelegate || !self.capOut) {
            [NSThread sleepForTimeInterval:0.05]; continue;
        }
        CMSampleBufferRef s = [self.trackOut copyNextSampleBuffer];
        if (!s) { [self buildReader]; continue; }
        if ([self.realDelegate respondsToSelector:
             @selector(captureOutput:didOutputSampleBuffer:fromConnection:)])
            [self.realDelegate captureOutput:self.capOut
                       didOutputSampleBuffer:s
                              fromConnection:self.conn];
        CFRelease(s);
        [NSThread sleepForTimeInterval:CMTimeGetSeconds(self.frameDur)];
    }
}
- (void)stop {
    self.running = NO;
    [self.reader cancelReading];
    self.reader = nil; self.trackOut = nil;
    self.capOut = nil; self.conn = nil;
}
@end

// ─────────────────────────────────────────────
//  Proxy delegate
// ─────────────────────────────────────────────
@interface CIProxyDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> real;
@end
@implementation CIProxyDelegate
- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)b fromConnection:(AVCaptureConnection *)c {
    CIFrameInjector *inj = (CIFrameInjector *)_injector;
    if (inj.running) {
        if (!inj.capOut) inj.capOut = o;
        if (!inj.conn)   inj.conn   = c;
        return; // kamera frame'ini yut
    }
    if ([self.real respondsToSelector:_cmd])
        [self.real captureOutput:o didOutputSampleBuffer:b fromConnection:c];
}
- (void)captureOutput:(AVCaptureOutput *)o didDropSampleBuffer:(CMSampleBufferRef)b fromConnection:(AVCaptureConnection *)c {
    if ([self.real respondsToSelector:_cmd])
        [self.real captureOutput:o didDropSampleBuffer:b fromConnection:c];
}
- (BOOL)respondsToSelector:(SEL)s { return [super respondsToSelector:s]||[self.real respondsToSelector:s]; }
- (id)forwardingTargetForSelector:(SEL)s { return self.real; }
@end

// ─────────────────────────────────────────────
//  AVCaptureVideoDataOutput hook
//  Proxy'yi her seferinde yeniden bağla
// ─────────────────────────────────────────────
@interface AVCaptureVideoDataOutput (CI) @end
@implementation AVCaptureVideoDataOutput (CI)
- (void)ci_setSBD:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)del queue:(dispatch_queue_t)q {
    if (del && ![del isKindOfClass:[CIProxyDelegate class]]) {
        NSLog(@"[CI] 🔗 setSampleBufferDelegate: %@", NSStringFromClass([del class]));
        CIProxyDelegate *p = (CIProxyDelegate *)_proxy;
        p.real = del;
        ((CIFrameInjector *)_injector).realDelegate = del;
        [self ci_setSBD:p queue:q];
    } else {
        [self ci_setSBD:del queue:q];
    }
}
+ (void)load {
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        Method o = class_getInstanceMethod(self, @selector(setSampleBufferDelegate:queue:));
        Method s = class_getInstanceMethod(self, @selector(ci_setSBD:queue:));
        if (o&&s) method_exchangeImplementations(o,s);
    });
}
@end

// ─────────────────────────────────────────────
//  En üstteki VC
// ─────────────────────────────────────────────
static UIViewController *CITopVC(void) {
    UIWindow *win = nil;
    if (@available(iOS 13,*)) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]] &&
                sc.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in ((UIWindowScene *)sc).windows)
                    if (w.isKeyWindow) { win = w; break; }
                if (!win) win = ((UIWindowScene *)sc).windows.firstObject;
                break;
            }
        }
    }
    if (!win) for (UIWindow *w in [UIApplication sharedApplication].windows)
        if (w.isKeyWindow) { win = w; break; }
    if (!win) win = [UIApplication sharedApplication].windows.firstObject;

    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

// ─────────────────────────────────────────────
//  Picker delegate
// ─────────────────────────────────────────────
@interface CIBubbleWindow : UIWindow
+ (instancetype)shared;
- (void)setInjecting:(BOOL)on;
@end

@interface CIPickerDelegate : NSObject<UIImagePickerControllerDelegate,UINavigationControllerDelegate>
@end
@implementation CIPickerDelegate
- (void)imagePickerController:(UIImagePickerController *)p
didFinishPickingMediaWithInfo:(NSDictionary *)info {
    NSURL *url = info[UIImagePickerControllerMediaURL];
    NSLog(@"[CI] 🎬 Video seçildi: %@", url);
    [p dismissViewControllerAnimated:YES completion:^{
        if (url) [(CIFrameInjector *)_injector startWithURL:url];
        [[CIBubbleWindow shared] setInjecting:YES];
    }];
}
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)p {
    [p dismissViewControllerAnimated:YES completion:nil];
}
@end

// ─────────────────────────────────────────────
//  Pan target
// ─────────────────────────────────────────────
@interface CIPanTarget : NSObject
- (void)pan:(UIPanGestureRecognizer *)g;
@end

static CGPoint _panStartLoc;
static CGPoint _panStartOrigin;

@implementation CIPanTarget
- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint loc = [g locationInView:v.superview];
    if (g.state == UIGestureRecognizerStateBegan) {
        _panStartLoc    = loc;
        _panStartOrigin = v.frame.origin;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGFloat dx = loc.x - _panStartLoc.x;
        CGFloat dy = loc.y - _panStartLoc.y;
        CGRect f = v.frame;
        f.origin.x = _panStartOrigin.x + dx;
        f.origin.y = _panStartOrigin.y + dy;
        CGSize sc = v.superview.bounds.size;
        f.origin.x = MAX(4, MIN(sc.width  - f.size.width  - 4, f.origin.x));
        f.origin.y = MAX(20,MIN(sc.height - f.size.height - 4, f.origin.y));
        [UIView performWithoutAnimation:^{ v.frame = f; }];
    }
}
@end

static CIPanTarget *_panTarget = nil;

// ─────────────────────────────────────────────
//  CIBubbleWindow — ayrı UIWindow, her zaman üstte
//  Balon kaybolma sorunu: windowLevel çok yüksek +
//  didBecomeVisible notification'da yeniden öne çek
// ─────────────────────────────────────────────
@interface CIBubbleWindow : UIWindow
@property (nonatomic, strong) UIButton *btn;
+ (instancetype)shared;
- (void)setInjecting:(BOOL)on;
@end

@implementation CIBubbleWindow

+ (instancetype)shared {
    static CIBubbleWindow *w;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ w = [[CIBubbleWindow alloc] initBubble]; });
    return w;
}

- (instancetype)initBubble {
    if (@available(iOS 13,*)) {
        // Aktif scene'i bul
        UIWindowScene *ws = nil;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes)
            if ([sc isKindOfClass:[UIWindowScene class]] &&
                sc.activationState == UISceneActivationStateForegroundActive)
            { ws = (UIWindowScene *)sc; break; }
        if (ws) self = [super initWithWindowScene:ws];
        else    self = [super initWithFrame:[UIScreen mainScreen].bounds];
    } else {
        self = [super initWithFrame:[UIScreen mainScreen].bounds];
    }
    if (!self) return nil;

    // Yüksek windowLevel — alert'lerin de üstünde
    self.windowLevel = UIWindowLevelAlert + 9999;
    self.backgroundColor = [UIColor clearColor];
    self.userInteractionEnabled = YES;

    // Sahte rootVC — window gösterebilmek için gerekli
    self.rootViewController = [UIViewController new];
    self.rootViewController.view.backgroundColor = [UIColor clearColor];

    CGSize sz = [UIScreen mainScreen].bounds.size;
    self.btn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.btn.frame = CGRectMake(sz.width - 70, 90, 56, 56);
    self.btn.backgroundColor = [UIColor colorWithRed:.08 green:.08 blue:.1 alpha:.92];
    self.btn.layer.cornerRadius  = 28;
    self.btn.layer.borderWidth   = 1.5;
    self.btn.layer.borderColor   = [UIColor colorWithWhite:1 alpha:.25].CGColor;
    self.btn.layer.shadowColor   = [UIColor blackColor].CGColor;
    self.btn.layer.shadowOpacity = .5;
    self.btn.layer.shadowOffset  = CGSizeMake(0,3);
    self.btn.layer.shadowRadius  = 8;
    [self.btn setTitle:@"🎬" forState:UIControlStateNormal];
    self.btn.titleLabel.font = [UIFont systemFontOfSize:26];
    [self.btn addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];

    // Pan — butona ekliyoruz, superview = window.rootVC.view
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:_panTarget action:@selector(pan:)];
    pan.maximumNumberOfTouches = 1;
    pan.delaysTouchesBegan = NO;
    pan.delaysTouchesEnded = NO;
    [self.btn addGestureRecognizer:pan];

    [self.rootViewController.view addSubview:self.btn];
    [self makeKeyAndVisible];

    // Diğer window'lar öne geçtiğinde biz de öne geç
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(keepOnTop)
        name:UIWindowDidBecomeVisibleNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(keepOnTop)
        name:UIWindowDidBecomeKeyNotification object:nil];

    return self;
}

- (void)keepOnTop {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self makeKeyAndVisible];
        // Ana app window'unu da key tut (picker sunabilmek için)
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w != self) { [w makeKeyWindow]; break; }
        }
    });
}

- (void)tapped {
    CIFrameInjector *inj = (CIFrameInjector *)_injector;
    if (inj.running) {
        [inj stop];
        [self setInjecting:NO];
        return;
    }
    // Picker sun
    UIViewController *vc = CITopVC();
    NSLog(@"[CI] 🎬 tap — topVC: %@", vc);
    if (!vc) { NSLog(@"[CI] ❌ VC bulunamadı"); return; }

    UIImagePickerController *picker = [UIImagePickerController new];
    picker.sourceType   = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes   = @[@"public.movie"];
    picker.videoQuality = UIImagePickerControllerQualityTypeHigh;
    if (!_pickerDelegate) _pickerDelegate = [CIPickerDelegate new];
    picker.delegate = (id)_pickerDelegate;
    [vc presentViewController:picker animated:YES completion:nil];
}

- (void)setInjecting:(BOOL)on {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (on) {
            [self.btn setTitle:@"⏹" forState:UIControlStateNormal];
            self.btn.backgroundColor = [UIColor colorWithRed:.75 green:.1 blue:.1 alpha:.92];
        } else {
            [self.btn setTitle:@"🎬" forState:UIControlStateNormal];
            self.btn.backgroundColor = [UIColor colorWithRed:.08 green:.08 blue:.1 alpha:.92];
        }
    });
}

// Sadece kendi butonuna hit-test, dışarısı app'e gitsin
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    CGPoint bp = [self convertPoint:p toView:self.btn];
    if (CGRectContainsPoint(self.btn.bounds, bp)) return self.btn;
    return nil;
}

@end

// ─────────────────────────────────────────────
//  Constructor
// ─────────────────────────────────────────────
__attribute__((constructor))
static void CIInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.2*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        _injector      = [CIFrameInjector new];
        _proxy         = [CIProxyDelegate new];
        _pickerDelegate = [CIPickerDelegate new];
        _panTarget     = [CIPanTarget new];
        [CIBubbleWindow shared]; // oluştur ve göster
        NSLog(@"[CI] ✅ CameraInject hazır");
    });
}
