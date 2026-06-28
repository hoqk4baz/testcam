#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>

// ─────────────────────────────────────────────
//  Globals
// ─────────────────────────────────────────────
static id  _injector        = nil;
static id  _proxy           = nil;
static id  _pickerDelegate  = nil;

@interface CIBubbleWindow : UIWindow
@property (nonatomic, strong) UIButton *bubbleBtn;
+ (instancetype)shared;
- (void)setInjecting:(BOOL)on;
- (void)log:(NSString *)msg;
@end

// ─────────────────────────────────────────────
//  CMSampleBuffer yeniden paketle
//  Kamera buffer'ının TÜM attachment'larını kopyala
//  (orientation, color space, vs.) — sadece pixel data değiştir
// ─────────────────────────────────────────────
static CMSampleBufferRef CIRepackBuffer(CVPixelBufferRef srcPx,
                                        CMSampleBufferRef refBuf) {
    CMFormatDescriptionRef newFmt = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, srcPx, &newFmt);

    CMSampleTimingInfo timing;
    CMSampleBufferGetSampleTimingInfo(refBuf, 0, &timing);
    timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock());
    timing.decodeTimeStamp       = kCMTimeInvalid;
    timing.duration              = kCMTimeInvalid;

    CMSampleBufferRef newBuf = NULL;
    CMSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault,
        srcPx,
        true,
        NULL, NULL,
        newFmt,
        &timing,
        &newBuf
    );
    if (newFmt) CFRelease(newFmt);
    if (!newBuf) return NULL;

    // Kamera buffer'ının attachment'larını kopyala
    // (kCMSampleBufferAttachmentKey_DisplayImmediately, orientation, vb.)
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(refBuf, false);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef srcDict = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFArrayRef dstArr = CMSampleBufferGetSampleAttachmentsArray(newBuf, true);
        if (dstArr && CFArrayGetCount(dstArr) > 0) {
            CFMutableDictionaryRef dstDict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(dstArr, 0);
            CFDictionaryApplyFunction(srcDict, ^(const void *k, const void *v, void *ctx){
                CFMutableDictionaryRef d = (CFMutableDictionaryRef)ctx;
                CFDictionarySetValue(d, k, v);
            }, dstDict);
        }
    }

    // CVImageBuffer attachment'larını da kopyala (renk uzayı, orientation)
    CVImageBufferRef refPx = CMSampleBufferGetImageBuffer(refBuf);
    if (refPx) {
        // Orientation
        CFTypeRef orient = CVBufferCopyAttachment(refPx, kCVImageBufferFieldDetailKey, NULL);
        if (orient) { CVBufferSetAttachment(srcPx, kCVImageBufferFieldDetailKey, orient, kCVAttachmentMode_ShouldPropagate); CFRelease(orient); }

        // Color space
        CFTypeRef cs = CVBufferCopyAttachment(refPx, kCVImageBufferCGColorSpaceKey, NULL);
        if (cs) { CVBufferSetAttachment(srcPx, kCVImageBufferCGColorSpaceKey, cs, kCVAttachmentMode_ShouldPropagate); CFRelease(cs); }

        // YCbCr matrix
        CFTypeRef ycbcr = CVBufferCopyAttachment(refPx, kCVImageBufferYCbCrMatrixKey, NULL);
        if (ycbcr) { CVBufferSetAttachment(srcPx, kCVImageBufferYCbCrMatrixKey, ycbcr, kCVAttachmentMode_ShouldPropagate); CFRelease(ycbcr); }

        // Color primaries
        CFTypeRef cp = CVBufferCopyAttachment(refPx, kCVImageBufferColorPrimariesKey, NULL);
        if (cp) { CVBufferSetAttachment(srcPx, kCVImageBufferColorPrimariesKey, cp, kCVAttachmentMode_ShouldPropagate); CFRelease(cp); }

        // Transfer function
        CFTypeRef tf = CVBufferCopyAttachment(refPx, kCVImageBufferTransferFunctionKey, NULL);
        if (tf) { CVBufferSetAttachment(srcPx, kCVImageBufferTransferFunctionKey, tf, kCVAttachmentMode_ShouldPropagate); CFRelease(tf); }
    }

    return newBuf;
}

// ─────────────────────────────────────────────
//  CIFrameInjector
// ─────────────────────────────────────────────
@interface CIFrameInjector : NSObject
@property (nonatomic, strong) AVAsset                  *asset;
@property (nonatomic, strong) AVAssetReader            *reader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *trackOut;
@property (nonatomic, strong) dispatch_queue_t          q;
@property (nonatomic, strong) id<AVCaptureVideoDataOutputSampleBufferDelegate> realDelegate;
@property (nonatomic, strong) AVCaptureOutput          *capOut;
@property (nonatomic, strong) AVCaptureConnection      *conn;
// Son kamera buffer'ı — format/timing referansı için
@property (nonatomic, assign) CMSampleBufferRef         lastCamBuffer;
@property (nonatomic, assign) BOOL                      running;
@property (nonatomic, assign) int64_t                   frameNs;
- (void)startWithURL:(NSURL *)url;
- (void)stop;
- (void)updateCamBuffer:(CMSampleBufferRef)buf;
@end

@implementation CIFrameInjector

- (instancetype)init {
    self = [super init];
    _q = dispatch_queue_create("ci.inject", DISPATCH_QUEUE_SERIAL);
    _frameNs = (int64_t)(NSEC_PER_SEC / 30);
    return self;
}

- (void)updateCamBuffer:(CMSampleBufferRef)buf {
    CMSampleBufferRef old = self.lastCamBuffer;
    if (buf) CFRetain(buf);
    self.lastCamBuffer = buf;
    if (old) CFRelease(old);
}

- (BOOL)openReader {
    [self.reader cancelReading];
    self.reader = nil; self.trackOut = nil;

    AVAssetTrack *track = [self.asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!track) return NO;
    float fps = track.nominalFrameRate;
    if (fps > 1 && fps < 120) self.frameNs = (int64_t)(NSEC_PER_SEC / fps);

    NSError *err = nil;
    self.reader = [AVAssetReader assetReaderWithAsset:self.asset error:&err];
    if (!self.reader) return NO;

    // Kamera'nın piksel formatını ve boyutunu birebir al
    OSType pixFmt = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    CGSize targetSize = CGSizeMake(480, 640); // portrait fallback
    if (self.lastCamBuffer) {
        CVImageBufferRef camPx = CMSampleBufferGetImageBuffer(self.lastCamBuffer);
        if (camPx) {
            pixFmt     = CVPixelBufferGetPixelFormatType(camPx);
            targetSize = CGSizeMake(CVPixelBufferGetWidth(camPx),
                                    CVPixelBufferGetHeight(camPx));
        }
    }

    [[CIBubbleWindow shared] log:[NSString stringWithFormat:
        @"fmt:%c%c%c%c\n%.0fx%.0f  %.0ffps",
        (char)(pixFmt>>24),(char)(pixFmt>>16),(char)(pixFmt>>8),(char)pixFmt,
        targetSize.width, targetSize.height, (double)NSEC_PER_SEC/self.frameNs]];

    self.trackOut = [AVAssetReaderTrackOutput
        assetReaderTrackOutputWithTrack:track
        outputSettings:@{
            (id)kCVPixelBufferPixelFormatTypeKey: @(pixFmt),
            (id)kCVPixelBufferWidthKey:           @(targetSize.width),
            (id)kCVPixelBufferHeightKey:          @(targetSize.height),
        }];
    [self.reader addOutput:self.trackOut];
    return [self.reader startReading];
}

- (void)startWithURL:(NSURL *)url {
    [self stop];
    self.asset = [AVAsset assetWithURL:url];
    self.running = YES; // önce running=YES, proxy kamera frame'lerini beklemeye devam etsin
    [[CIBubbleWindow shared] log:@"⏳ kamera formatı bekleniyor..."];

    // İlk kamera buffer'ı gelene kadar bekle (max 3sn)
    __weak typeof(self) w = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5*NSEC_PER_SEC)), self.q, ^{
        int tries = 0;
        while (!w.lastCamBuffer && tries < 60) {
            [NSThread sleepForTimeInterval:0.05];
            tries++;
        }
        if (![w openReader]) {
            [[CIBubbleWindow shared] log:@"❌ Reader açılamadı"];
            w.running = NO; return;
        }
        [[CIBubbleWindow shared] log:@"▶ injection başladı"];
        [w scheduleNext];
    });
}

- (void)scheduleNext {
    if (!self.running) return;
    __weak typeof(self) w = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, self.frameNs), self.q, ^{
        [w sendFrame];
    });
}

- (void)sendFrame {
    if (!self.running) return;

    if (!self.capOut || !self.conn || !self.realDelegate || !self.lastCamBuffer) {
        // Henüz hazır değil — kısa bekle
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC/20), self.q, ^{
            [self sendFrame];
        });
        return;
    }

    CMSampleBufferRef videoSample = [self.trackOut copyNextSampleBuffer];
    if (!videoSample) {
        [self openReader];
        [self scheduleNext];
        return;
    }

    // Pixel buffer'ı al
    CVImageBufferRef px = CMSampleBufferGetImageBuffer(videoSample);

    // Orijinal kamera buffer'ının format+timing'iyle yeniden paketle
    CMSampleBufferRef repacked = CIRepackBuffer(px, self.lastCamBuffer);
    CFRelease(videoSample);

    if (repacked) {
        if ([self.realDelegate respondsToSelector:
             @selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            [self.realDelegate captureOutput:self.capOut
                       didOutputSampleBuffer:repacked
                              fromConnection:self.conn];
        }
        CFRelease(repacked);
    }

    [self scheduleNext];
}

- (void)stop {
    self.running = NO;
    [self.reader cancelReading];
    self.reader = nil; self.trackOut = nil;
    self.capOut = nil; self.conn = nil;
    [self updateCamBuffer:NULL];
}

- (void)dealloc {
    if (_lastCamBuffer) CFRelease(_lastCamBuffer);
}

@end

// ─────────────────────────────────────────────
//  Proxy delegate
//  — kamera frame gelince lastCamBuffer güncelle
//  — injector çalışıyorsa frame'i yut
// ─────────────────────────────────────────────
@interface CIProxyDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) id<AVCaptureVideoDataOutputSampleBufferDelegate> real;
@end

@implementation CIProxyDelegate
- (void)captureOutput:(AVCaptureOutput *)o
didOutputSampleBuffer:(CMSampleBufferRef)b
       fromConnection:(AVCaptureConnection *)c {
    CIFrameInjector *inj = (CIFrameInjector *)_injector;
    inj.capOut = o;
    inj.conn   = c;
    [inj updateCamBuffer:b]; // her zaman güncelle — format referansı için

    if (inj.running) return; // kamera frame'ini yut

    if ([self.real respondsToSelector:_cmd])
        [self.real captureOutput:o didOutputSampleBuffer:b fromConnection:c];
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
@interface AVCaptureVideoDataOutput (CI) @end
@implementation AVCaptureVideoDataOutput (CI)
- (void)ci_setSBD:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)del
            queue:(dispatch_queue_t)q {
    if (del && ![del isKindOfClass:[CIProxyDelegate class]]) {
        [[CIBubbleWindow shared] log:[NSString stringWithFormat:
            @"🔗 %@", NSStringFromClass([del class])]];
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
        if (o && s) method_exchangeImplementations(o, s);
    });
}
@end

// ─────────────────────────────────────────────
//  AVCaptureSession hook
// ─────────────────────────────────────────────
@interface AVCaptureSession (CI) @end
@implementation AVCaptureSession (CI)
- (void)ci_startRunning {
    [self ci_startRunning];
    CIFrameInjector *inj = (CIFrameInjector *)_injector;
    if (!inj) return;
    for (AVCaptureOutput *out in self.outputs) {
        if (![out isKindOfClass:[AVCaptureVideoDataOutput class]]) continue;
        AVCaptureVideoDataOutput *vdo = (AVCaptureVideoDataOutput *)out;
        AVCaptureConnection *conn = [vdo connectionWithMediaType:AVMediaTypeVideo];
        if (conn) { inj.capOut = out; inj.conn = conn; }
        id del = vdo.sampleBufferDelegate;
        if (del && ![del isKindOfClass:[CIProxyDelegate class]]) {
            ((CIProxyDelegate *)_proxy).real = del;
            inj.realDelegate = del;
        } else if ([del isKindOfClass:[CIProxyDelegate class]]) {
            inj.realDelegate = ((CIProxyDelegate *)del).real;
        }
        [[CIBubbleWindow shared] log:[NSString stringWithFormat:
            @"✅ startRunning\ndelegate: %@", NSStringFromClass([inj.realDelegate class])]];
        break;
    }
}
+ (void)load {
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        Method o = class_getInstanceMethod(self, @selector(startRunning));
        Method s = class_getInstanceMethod(self, @selector(ci_startRunning));
        if (o && s) method_exchangeImplementations(o, s);
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
                UIWindowScene *ws = (UIWindowScene *)sc;
                for (UIWindow *w in ws.windows) if (w.isKeyWindow) { win = w; break; }
                if (!win) win = ws.windows.firstObject;
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
@interface CIPickerDelegate : NSObject
    <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@end
@implementation CIPickerDelegate
- (void)imagePickerController:(UIImagePickerController *)p
didFinishPickingMediaWithInfo:(NSDictionary *)info {
    NSURL *url = info[UIImagePickerControllerMediaURL];
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
static CGPoint _panStart, _originStart;
@implementation CIPanTarget
- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view, *sv = v.superview;
    CGPoint loc = [g locationInView:sv];
    if (g.state == UIGestureRecognizerStateBegan) {
        _panStart = loc; _originStart = v.frame.origin;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGRect f = v.frame;
        f.origin.x = _originStart.x + (loc.x - _panStart.x);
        f.origin.y = _originStart.y + (loc.y - _panStart.y);
        CGSize sc = sv.bounds.size;
        f.origin.x = MAX(4, MIN(sc.width - f.size.width - 4, f.origin.x));
        f.origin.y = MAX(24, MIN(sc.height - f.size.height - 4, f.origin.y));
        [UIView performWithoutAnimation:^{ v.frame = f; }];
    }
}
@end
static CIPanTarget *_panTarget = nil;

// ─────────────────────────────────────────────
//  CIBubbleWindow
// ─────────────────────────────────────────────
@implementation CIBubbleWindow {
    UILabel *_logLabel;
}

+ (instancetype)shared {
    static CIBubbleWindow *w;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ w = [[CIBubbleWindow alloc] initBubble]; });
    return w;
}

- (instancetype)initBubble {
    if (@available(iOS 13,*)) {
        UIWindowScene *ws = nil;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes)
            if ([sc isKindOfClass:[UIWindowScene class]] &&
                sc.activationState == UISceneActivationStateForegroundActive)
            { ws = (UIWindowScene *)sc; break; }
        self = ws ? [super initWithWindowScene:ws]
                  : [super initWithFrame:[UIScreen mainScreen].bounds];
    } else {
        self = [super initWithFrame:[UIScreen mainScreen].bounds];
    }
    if (!self) return nil;

    self.windowLevel = UIWindowLevelAlert + 9999;
    self.backgroundColor = [UIColor clearColor];
    self.rootViewController = [UIViewController new];
    self.rootViewController.view.backgroundColor = [UIColor clearColor];

    CGSize sz = [UIScreen mainScreen].bounds.size;
    self.bubbleBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.bubbleBtn.frame = CGRectMake(sz.width-70, 90, 56, 56);
    self.bubbleBtn.backgroundColor     = [UIColor colorWithRed:.08 green:.08 blue:.1 alpha:.92];
    self.bubbleBtn.layer.cornerRadius  = 28;
    self.bubbleBtn.layer.borderWidth   = 1.5;
    self.bubbleBtn.layer.borderColor   = [UIColor colorWithWhite:1 alpha:.25].CGColor;
    self.bubbleBtn.layer.shadowColor   = [UIColor blackColor].CGColor;
    self.bubbleBtn.layer.shadowOpacity = .5;
    self.bubbleBtn.layer.shadowOffset  = CGSizeMake(0,3);
    self.bubbleBtn.layer.shadowRadius  = 8;
    [self.bubbleBtn setTitle:@"🎬" forState:UIControlStateNormal];
    self.bubbleBtn.titleLabel.font = [UIFont systemFontOfSize:26];
    [self.bubbleBtn addTarget:self action:@selector(tapped)
             forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:_panTarget action:@selector(pan:)];
    pan.maximumNumberOfTouches = 1;
    pan.delaysTouchesBegan = NO;
    pan.delaysTouchesEnded = NO;
    [self.bubbleBtn addGestureRecognizer:pan];

    _logLabel = [[UILabel alloc] initWithFrame:CGRectMake(sz.width-185, 150, 175, 60)];
    _logLabel.numberOfLines   = 3;
    _logLabel.font            = [UIFont systemFontOfSize:9];
    _logLabel.textColor       = [UIColor colorWithRed:.2 green:1 blue:.4 alpha:1];
    _logLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:.65];
    _logLabel.layer.cornerRadius  = 6;
    _logLabel.layer.masksToBounds = YES;

    [self.rootViewController.view addSubview:self.bubbleBtn];
    [self.rootViewController.view addSubview:_logLabel];
    // makeKeyAndVisible YOK — key window'u çalmıyoruz
    self.hidden = NO;

    // Sadece kendi window'umuzu öne al, key window'u çalma
    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(bringToFront)
        name:UIWindowDidBecomeVisibleNotification object:nil];
    return self;
}

- (void)log:(NSString *)msg {
    NSLog(@"[CI] %@", msg);
    dispatch_async(dispatch_get_main_queue(), ^{ _logLabel.text = msg; });
}

- (void)bringToFront {
    // makeKeyAndVisible çağırmıyoruz — klavye/popup window'larını ezmez
    // Sadece hidden değilse zaten görünür; windowLevel zaten yüksek
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.isHidden) self.hidden = NO;
    });
}

- (void)tapped {
    CIFrameInjector *inj = (CIFrameInjector *)_injector;
    if (inj.running) { [inj stop]; [self setInjecting:NO]; return; }
    UIViewController *vc = CITopVC();
    if (!vc) { [self log:@"❌ VC yok"]; return; }
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
            [self.bubbleBtn setTitle:@"⏹" forState:UIControlStateNormal];
            self.bubbleBtn.backgroundColor = [UIColor colorWithRed:.75 green:.1 blue:.1 alpha:.92];
        } else {
            [self.bubbleBtn setTitle:@"🎬" forState:UIControlStateNormal];
            self.bubbleBtn.backgroundColor = [UIColor colorWithRed:.08 green:.08 blue:.1 alpha:.92];
        }
    });
}

- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    for (UIView *sub in self.rootViewController.view.subviews) {
        CGPoint lp = [sub convertPoint:p fromView:self];
        if (!sub.hidden && CGRectContainsPoint(sub.bounds, lp)) return sub;
    }
    return nil;
}
@end

// ─────────────────────────────────────────────
//  Constructor
// ─────────────────────────────────────────────
__attribute__((constructor))
static void CIInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        _injector       = [CIFrameInjector new];
        _proxy          = [CIProxyDelegate new];
        _pickerDelegate = [CIPickerDelegate new];
        _panTarget      = [CIPanTarget new];
        [CIBubbleWindow shared];
        NSLog(@"[CI] ✅ hazır");
    });
}
