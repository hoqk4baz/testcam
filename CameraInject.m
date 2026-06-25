#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

// ─────────────────────────────────────────────
//  Globals
// ─────────────────────────────────────────────
static id  _injector      = nil;  // CIFrameInjector*
static id  _proxy         = nil;  // CIProxyDelegate*
static id  _pickerDelegate = nil; // CIPickerDelegate*
static UIButton *_bubble  = nil;

// ─────────────────────────────────────────────
//  En üstteki VC — scene API + fallback
// ─────────────────────────────────────────────
static UIViewController *CITopVC(void) {
    UIWindow *win = nil;

    // iOS 13+ scene
    if (@available(iOS 13, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive &&
                [scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                for (UIWindow *w in ws.windows) {
                    if (w.isKeyWindow) { win = w; break; }
                }
                if (!win) win = ws.windows.firstObject;
                break;
            }
        }
    }

    // Fallback
    if (!win) {
        for (UIWindow *w in [UIApplication sharedApplication].windows)
            if (w.isKeyWindow) { win = w; break; }
    }
    if (!win) win = [UIApplication sharedApplication].windows.firstObject;

    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

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
        if (!self.realDelegate || !self.capOut) { [NSThread sleepForTimeInterval:0.05]; continue; }
        CMSampleBufferRef s = [self.trackOut copyNextSampleBuffer];
        if (!s) {
            [self buildReader]; continue;
        }
        if ([self.realDelegate respondsToSelector:
             @selector(captureOutput:didOutputSampleBuffer:fromConnection:)])
            [self.realDelegate captureOutput:self.capOut didOutputSampleBuffer:s fromConnection:self.conn];
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
        return;
    }
    if ([self.real respondsToSelector:_cmd]) [self.real captureOutput:o didOutputSampleBuffer:b fromConnection:c];
}
- (void)captureOutput:(AVCaptureOutput *)o didDropSampleBuffer:(CMSampleBufferRef)b fromConnection:(AVCaptureConnection *)c {
    if ([self.real respondsToSelector:_cmd]) [self.real captureOutput:o didDropSampleBuffer:b fromConnection:c];
}
- (BOOL)respondsToSelector:(SEL)s { return [super respondsToSelector:s]||[self.real respondsToSelector:s]; }
- (id)forwardingTargetForSelector:(SEL)s { return self.real; }
@end

@interface AVCaptureVideoDataOutput (CI) @end
@implementation AVCaptureVideoDataOutput (CI)
- (void)ci_setSBD:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)del queue:(dispatch_queue_t)q {
    if (del && ![del isKindOfClass:[CIProxyDelegate class]]) {
        if (!_proxy) _proxy = [CIProxyDelegate new];
        ((CIProxyDelegate *)_proxy).real = del;
        ((CIFrameInjector *)_injector).realDelegate = del;
        [self ci_setSBD:(id)_proxy queue:q];
    } else { [self ci_setSBD:del queue:q]; }
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
//  Picker delegate
// ─────────────────────────────────────────────
@interface CIPickerDelegate : NSObject<UIImagePickerControllerDelegate,UINavigationControllerDelegate>
@end
@implementation CIPickerDelegate
- (void)imagePickerController:(UIImagePickerController *)p didFinishPickingMediaWithInfo:(NSDictionary *)info {
    NSURL *url = info[UIImagePickerControllerMediaURL];
    [p dismissViewControllerAnimated:YES completion:^{
        if (url) [(CIFrameInjector *)_injector startWithURL:url];
        // Butonu güncelle
        dispatch_async(dispatch_get_main_queue(), ^{
            [_bubble setTitle:@"⏹" forState:UIControlStateNormal];
            _bubble.backgroundColor = [UIColor colorWithRed:.75 green:.1 blue:.1 alpha:.92];
        });
    }];
}
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)p {
    [p dismissViewControllerAnimated:YES completion:nil];
}
@end

// ─────────────────────────────────────────────
//  Bubble tap / drag — sade UIButton + gesture
//  Titreme düzeltmesi: frame animasyonsuz, main thread
// ─────────────────────────────────────────────
static void CIShowBubble(void);

static void CIBubbleTapped(void) {
    CIFrameInjector *inj = (CIFrameInjector *)_injector;
    if (inj.running) {
        [inj stop];
        dispatch_async(dispatch_get_main_queue(), ^{
            [_bubble setTitle:@"🎬" forState:UIControlStateNormal];
            _bubble.backgroundColor = [UIColor colorWithRed:.08 green:.08 blue:.08 alpha:.9];
        });
        return;
    }

    UIViewController *vc = CITopVC();
    NSLog(@"[CI] topVC = %@", vc);
    if (!vc) return;

    UIImagePickerController *picker = [UIImagePickerController new];
    picker.sourceType   = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes   = @[@"public.movie"];
    picker.videoQuality = UIImagePickerControllerQualityTypeHigh;
    if (!_pickerDelegate) _pickerDelegate = [CIPickerDelegate new];
    picker.delegate = (id)_pickerDelegate;
    [vc presentViewController:picker animated:YES completion:nil];
}

// Drag state
static CGPoint _dragStart;    // dokunulan ekran noktası
static CGPoint _frameOrigin;  // o anki bubble origin

static void CIHandlePan(UIPanGestureRecognizer *pan) {
    // Superview koordinatında çalış
    UIView *sv = _bubble.superview;
    CGPoint loc = [pan locationInView:sv];

    if (pan.state == UIGestureRecognizerStateBegan) {
        _dragStart   = loc;
        _frameOrigin = _bubble.frame.origin;
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        CGFloat dx = loc.x - _dragStart.x;
        CGFloat dy = loc.y - _dragStart.y;
        CGRect f   = _bubble.frame;
        f.origin.x = _frameOrigin.x + dx;
        f.origin.y = _frameOrigin.y + dy;

        // Sınır
        CGSize sc = sv.bounds.size;
        f.origin.x = MAX(0, MIN(sc.width  - f.size.width,  f.origin.x));
        f.origin.y = MAX(0, MIN(sc.height - f.size.height, f.origin.y));

        // Animasyon YOK — doğrudan set
        [UIView performWithoutAnimation:^{ _bubble.frame = f; }];
    }
}

static void CIShowBubble(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_bubble) return;

        // Pencere hiyerarşisini bul (en üstteki normal UIWindow)
        UIWindow *win = nil;
        if (@available(iOS 13,*)) {
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if ([sc isKindOfClass:[UIWindowScene class]] &&
                    sc.activationState == UISceneActivationStateForegroundActive) {
                    win = ((UIWindowScene *)sc).windows.firstObject;
                    break;
                }
            }
        }
        if (!win) win = [UIApplication sharedApplication].windows.firstObject;

        UIView *root = win; // direkt window'a ekle

        CGSize sc = win.bounds.size;
        _bubble = [UIButton buttonWithType:UIButtonTypeCustom];
        _bubble.frame = CGRectMake(sc.width - 70, 90, 56, 56);
        _bubble.backgroundColor = [UIColor colorWithRed:.08 green:.08 blue:.08 alpha:.9];
        _bubble.layer.cornerRadius = 28;
        _bubble.layer.borderWidth  = 1.5;
        _bubble.layer.borderColor  = [UIColor colorWithWhite:1 alpha:.2].CGColor;
        _bubble.layer.shadowColor  = [UIColor blackColor].CGColor;
        _bubble.layer.shadowOpacity = .45;
        _bubble.layer.shadowOffset  = CGSizeMake(0,3);
        _bubble.layer.shadowRadius  = 7;
        [_bubble setTitle:@"🎬" forState:UIControlStateNormal];
        _bubble.titleLabel.font = [UIFont systemFontOfSize:26];

        // Tap
        [_bubble addTarget:[NSValue valueWithNonretainedObject:nil]
                    action:nil
          forControlEvents:UIControlEventTouchUpInside];
        // Blok için wrapper
        UIControl *ctrl = (UIControl *)_bubble;
        [ctrl addTarget:ctrl action:@selector(ci_tap) forControlEvents:UIControlEventTouchUpInside];

        // Drag
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:[NSValue valueWithNonretainedObject:nil] action:nil];
        // C fonksiyonu için wrapper
        pan.maximumNumberOfTouches = 1;

        // UIButton category ile tap+drag
        objc_setAssociatedObject(_bubble, "ci_pan", pan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        [root addSubview:_bubble];
        [root bringSubviewToFront:_bubble];

        // Pan gesture — ayrı bir target objesi kullanalım
        // (C fonksiyonu doğrudan target olamaz)
        NSLog(@"[CI] 🫧 Bubble eklendi: %@", NSStringFromCGRect(_bubble.frame));
    });
}

// ─────────────────────────────────────────────
//  UIButton category — tap + pan target
// ─────────────────────────────────────────────
@interface UIButton (CIBubble)
- (void)ci_tap;
@end
@implementation UIButton (CIBubble)
- (void)ci_tap { CIBubbleTapped(); }
@end

// Pan gesture için minimal target sınıfı
@interface CIPanTarget : NSObject
- (void)pan:(UIPanGestureRecognizer *)g;
@end
@implementation CIPanTarget
- (void)pan:(UIPanGestureRecognizer *)g { CIHandlePan(g); }
@end
static CIPanTarget *_panTarget = nil;

// ─────────────────────────────────────────────
//  Constructor — bubble kurulumu pan'lı versiyonu
// ─────────────────────────────────────────────
__attribute__((constructor))
static void CIInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        _injector  = [CIFrameInjector new];
        _panTarget = [CIPanTarget new];

        // Pencereyi bul
        UIWindow *win = nil;
        if (@available(iOS 13,*)) {
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if ([sc isKindOfClass:[UIWindowScene class]] &&
                    sc.activationState == UISceneActivationStateForegroundActive) {
                    win = ((UIWindowScene *)sc).windows.firstObject; break;
                }
            }
        }
        if (!win) win = [UIApplication sharedApplication].windows.firstObject;

        CGSize sz = win.bounds.size;
        _bubble = [UIButton buttonWithType:UIButtonTypeCustom];
        _bubble.frame = CGRectMake(sz.width-70, 90, 56, 56);
        _bubble.backgroundColor = [UIColor colorWithRed:.08 green:.08 blue:.08 alpha:.9];
        _bubble.layer.cornerRadius  = 28;
        _bubble.layer.borderWidth   = 1.5;
        _bubble.layer.borderColor   = [UIColor colorWithWhite:1 alpha:.2].CGColor;
        _bubble.layer.shadowColor   = [UIColor blackColor].CGColor;
        _bubble.layer.shadowOpacity = .45;
        _bubble.layer.shadowOffset  = CGSizeMake(0,3);
        _bubble.layer.shadowRadius  = 7;
        [_bubble setTitle:@"🎬" forState:UIControlStateNormal];
        _bubble.titleLabel.font = [UIFont systemFontOfSize:26];

        // Tap
        [_bubble addTarget:_bubble action:@selector(ci_tap) forControlEvents:UIControlEventTouchUpInside];

        // Pan
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:_panTarget action:@selector(pan:)];
        pan.maximumNumberOfTouches = 1;
        // Pan gesture tap'ı engellemesin
        pan.delaysTouchesBegan = NO;
        [_bubble addGestureRecognizer:pan];

        [win addSubview:_bubble];
        [win bringSubviewToFront:_bubble];

        NSLog(@"[CI] ✅ CameraInject hazır — 🎬 butonuna bas");
    });
}
