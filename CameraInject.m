#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>

static id  _injector       = nil;
static id  _proxy          = nil;
static id  _pickerDelegate = nil;

@interface CIBubbleWindow : UIWindow
@property (nonatomic, strong) UIButton *bubbleBtn;
+ (instancetype)shared;
- (void)setInjecting:(BOOL)on;
- (void)log:(NSString *)msg;
@end

// ─────────────────────────────────────────────
//  CIFrameInjector
// ─────────────────────────────────────────────
@interface CIFrameInjector : NSObject
@property (nonatomic, strong) NSURL                    *videoURL;
@property (nonatomic, strong) AVAsset                  *asset;
@property (nonatomic, strong) AVAssetReader            *reader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *trackOut;
@property (nonatomic, strong) dispatch_queue_t          q;
@property (nonatomic, strong) id<AVCaptureVideoDataOutputSampleBufferDelegate> realDelegate;
@property (nonatomic, strong) AVCaptureOutput          *capOut;
@property (nonatomic, strong) AVCaptureConnection      *conn;
@property (nonatomic, strong) dispatch_semaphore_t      camLock;
@property (nonatomic, assign) CMSampleBufferRef         lastCamBuffer;
@property (nonatomic, assign) BOOL                      running;
@property (nonatomic, assign) int64_t                   frameNs;
@property (nonatomic, assign) CGFloat                   zoom; // 1.0=normal 2.0=2x yakın
- (void)startWithURL:(NSURL *)url;
- (void)stop;
- (void)updateCamBuffer:(CMSampleBufferRef)buf;
@end

@implementation CIFrameInjector

- (instancetype)init {
    self = [super init];
    _q       = dispatch_queue_create("ci.inject", DISPATCH_QUEUE_SERIAL);
    _camLock = dispatch_semaphore_create(1);
    _frameNs = (int64_t)(NSEC_PER_SEC / 30);
    _zoom    = 1.5; // varsayılan 1.5x — yüz yakın gelsin
    return self;
}

- (void)updateCamBuffer:(CMSampleBufferRef)buf {
    dispatch_semaphore_wait(self.camLock, DISPATCH_TIME_FOREVER);
    CMSampleBufferRef old = self.lastCamBuffer;
    if (buf) CFRetain(buf);
    self.lastCamBuffer = buf;
    if (old) CFRelease(old);
    dispatch_semaphore_signal(self.camLock);
}

- (BOOL)openReader {
    [self.reader cancelReading];
    self.reader = nil; self.trackOut = nil;

    self.asset = [AVURLAsset URLAssetWithURL:self.videoURL options:nil];
    AVAssetTrack *track = [self.asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!track) return NO;

    float fps = track.nominalFrameRate;
    if (fps > 1 && fps < 120) self.frameNs = (int64_t)(NSEC_PER_SEC / fps);

    NSError *err = nil;
    self.reader = [AVAssetReader assetReaderWithAsset:self.asset error:&err];
    if (!self.reader) return NO;

    // BGRA ile okuyoruz — sonra kamera buffer boyutuna scale edip YUV'a çevireceğiz
    self.trackOut = [AVAssetReaderTrackOutput
        assetReaderTrackOutputWithTrack:track
        outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
    [self.reader addOutput:self.trackOut];
    return [self.reader startReading];
}

- (void)startWithURL:(NSURL *)url {
    [self stop];
    self.videoURL = url;
    self.running  = YES;
    [[CIBubbleWindow shared] log:@"⏳ kamera bekleniyor..."];

    __weak typeof(self) w = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5*NSEC_PER_SEC)), self.q, ^{
        int tries = 0;
        while (!w.lastCamBuffer && tries < 60) {
            [NSThread sleepForTimeInterval:0.05]; tries++;
        }
        if (!w.lastCamBuffer) {
            [[CIBubbleWindow shared] log:@"❌ kamera frame gelmedi"]; w.running = NO; return;
        }
        if (![w openReader]) {
            [[CIBubbleWindow shared] log:@"❌ reader açılamadı"]; w.running = NO; return;
        }
        [[CIBubbleWindow shared] log:@"▶ injection başladı"];
        [w scheduleNext];
    });
}

- (void)scheduleNext {
    if (!self.running) return;
    __weak typeof(self) w = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, self.frameNs), self.q, ^{ [w sendFrame]; });
}

// Video BGRA → kamera pixel buffer'ına (YUV veya BGRA) CoreImage ile scale + convert
- (BOOL)copyVideoPixels:(CVPixelBufferRef)srcBGRA intoCamBuffer:(CVPixelBufferRef)camPx {
    // CoreImage ile hem scale hem renk dönüşümü
    CIImage *img = [CIImage imageWithCVPixelBuffer:srcBGRA];

    size_t dw = CVPixelBufferGetWidth(camPx);
    size_t dh = CVPixelBufferGetHeight(camPx);
    size_t sw = CVPixelBufferGetWidth(srcBGRA);
    size_t sh = CVPixelBufferGetHeight(srcBGRA);

    // Scale — aspect fill + zoom
    CGFloat scaleX = (CGFloat)dw / sw;
    CGFloat scaleY = (CGFloat)dh / sh;
    CGFloat scale  = MAX(scaleX, scaleY) * self.zoom; // zoom ile yakınlaştır

    CGFloat newW = sw * scale;
    CGFloat newH = sh * scale;
    CGFloat offX = (dw - newW) / 2.0;
    CGFloat offY = (dh - newH) / 2.0;

    CGAffineTransform t = CGAffineTransformIdentity;
    t = CGAffineTransformTranslate(t, offX, offY);
    t = CGAffineTransformScale(t, scale, scale);
    img = [img imageByApplyingTransform:t];

    static CIContext *ctx = nil;
    if (!ctx) ctx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];

    CVPixelBufferLockBaseAddress(camPx, 0);
    [ctx render:img toCVPixelBuffer:camPx];
    CVPixelBufferUnlockBaseAddress(camPx, 0);
    return YES;
}

- (void)sendFrame {
    if (!self.running) return;

    if (!self.capOut || !self.conn || !self.realDelegate) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC/20), self.q, ^{ [self sendFrame]; });
        return;
    }

    // Kamera buffer'ını kilitle — race condition yok
    dispatch_semaphore_wait(self.camLock, DISPATCH_TIME_FOREVER);
    CMSampleBufferRef camBuf = self.lastCamBuffer;
    if (camBuf) CFRetain(camBuf);
    dispatch_semaphore_signal(self.camLock);

    if (!camBuf) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC/20), self.q, ^{ [self sendFrame]; });
        return;
    }

    CMSampleBufferRef videoSample = [self.trackOut copyNextSampleBuffer];
    if (!videoSample) {
        CFRelease(camBuf);
        [[CIBubbleWindow shared] log:@"🔄 rewind"];
        if ([self openReader]) [self scheduleNext];
        else [[CIBubbleWindow shared] log:@"❌ rewind başarısız"];
        return;
    }

    CVImageBufferRef videoPx = CMSampleBufferGetImageBuffer(videoSample);
    CVImageBufferRef camPx   = CMSampleBufferGetImageBuffer(camBuf);

    if (videoPx && camPx) {
        [self copyVideoPixels:videoPx intoCamBuffer:camPx];

        // Timing güncelle — eski timestamp reddedilebilir
        CMSampleTimingInfo timing;
        CMSampleBufferGetSampleTimingInfo(camBuf, 0, &timing);
        timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock());
        timing.decodeTimeStamp       = kCMTimeInvalid;

        // Yeni buffer oluştur — aynı camPx, güncel timing
        CMFormatDescriptionRef fmt = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, camPx, &fmt);

        CMSampleBufferRef outBuf = NULL;
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, camPx, true,
                                           NULL, NULL, fmt, &timing, &outBuf);
        if (fmt) CFRelease(fmt);

        if (outBuf) {
            if ([self.realDelegate respondsToSelector:
                 @selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
                [self.realDelegate captureOutput:self.capOut
                           didOutputSampleBuffer:outBuf
                                  fromConnection:self.conn];
            }
            CFRelease(outBuf);
        }
    }

    CFRelease(videoSample);
    CFRelease(camBuf);
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
    [inj updateCamBuffer:b];
    if (inj.running) return;
    if ([self.real respondsToSelector:_cmd])
        [self.real captureOutput:o didOutputSampleBuffer:b fromConnection:c];
}
- (void)captureOutput:(AVCaptureOutput *)o didDropSampleBuffer:(CMSampleBufferRef)b fromConnection:(AVCaptureConnection *)c {
    if ([self.real respondsToSelector:_cmd]) [self.real captureOutput:o didDropSampleBuffer:b fromConnection:c];
}
- (BOOL)respondsToSelector:(SEL)s { return [super respondsToSelector:s]||[self.real respondsToSelector:s]; }
- (id)forwardingTargetForSelector:(SEL)s { return self.real; }
@end

// ─────────────────────────────────────────────
//  AVCaptureVideoDataOutput hook
// ─────────────────────────────────────────────
@interface AVCaptureVideoDataOutput (CI) @end
@implementation AVCaptureVideoDataOutput (CI)
- (void)ci_setSBD:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)del queue:(dispatch_queue_t)q {
    if (del && ![del isKindOfClass:[CIProxyDelegate class]]) {
        CIProxyDelegate *p = (CIProxyDelegate *)_proxy;
        p.real = del;
        ((CIFrameInjector *)_injector).realDelegate = del;
        [self ci_setSBD:p queue:q];
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
            ((CIProxyDelegate *)_proxy).real = del; inj.realDelegate = del;
        } else if ([del isKindOfClass:[CIProxyDelegate class]]) {
            inj.realDelegate = ((CIProxyDelegate *)del).real;
        }
        [[CIBubbleWindow shared] log:[NSString stringWithFormat:@"✅ %@", NSStringFromClass([inj.realDelegate class])]];
        break;
    }
}
+ (void)load {
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        Method o = class_getInstanceMethod(self, @selector(startRunning));
        Method s = class_getInstanceMethod(self, @selector(ci_startRunning));
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
                UIWindowScene *ws = (UIWindowScene *)sc;
                for (UIWindow *w in ws.windows) if (w.isKeyWindow) { win=w; break; }
                if (!win) win = ws.windows.firstObject;
                break;
            }
        }
    }
    if (!win) for (UIWindow *w in [UIApplication sharedApplication].windows) if (w.isKeyWindow) { win=w; break; }
    if (!win) win = [UIApplication sharedApplication].windows.firstObject;
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

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
    UIView *v=g.view, *sv=v.superview;
    CGPoint loc=[g locationInView:sv];
    if (g.state==UIGestureRecognizerStateBegan) { _panStart=loc; _originStart=v.frame.origin; }
    else if (g.state==UIGestureRecognizerStateChanged) {
        CGRect f=v.frame;
        f.origin.x=_originStart.x+(loc.x-_panStart.x);
        f.origin.y=_originStart.y+(loc.y-_panStart.y);
        CGSize sc=sv.bounds.size;
        f.origin.x=MAX(4,MIN(sc.width-f.size.width-4,f.origin.x));
        f.origin.y=MAX(24,MIN(sc.height-f.size.height-4,f.origin.y));
        [UIView performWithoutAnimation:^{ v.frame=f; }];
    }
}
@end
static CIPanTarget *_panTarget = nil;

// ─────────────────────────────────────────────
//  CIBubbleWindow
// ─────────────────────────────────────────────
@implementation CIBubbleWindow { UILabel *_logLabel; }

+ (instancetype)shared {
    static CIBubbleWindow *w; static dispatch_once_t t;
    dispatch_once(&t, ^{ w=[[CIBubbleWindow alloc] initBubble]; });
    return w;
}

- (instancetype)initBubble {
    if (@available(iOS 13,*)) {
        UIWindowScene *ws=nil;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes)
            if ([sc isKindOfClass:[UIWindowScene class]] && sc.activationState==UISceneActivationStateForegroundActive)
            { ws=(UIWindowScene *)sc; break; }
        self = ws ? [super initWithWindowScene:ws] : [super initWithFrame:[UIScreen mainScreen].bounds];
    } else { self=[super initWithFrame:[UIScreen mainScreen].bounds]; }
    if (!self) return nil;

    self.windowLevel=UIWindowLevelAlert+9999;
    self.backgroundColor=[UIColor clearColor];
    self.rootViewController=[UIViewController new];
    self.rootViewController.view.backgroundColor=[UIColor clearColor];

    CGSize sz=[UIScreen mainScreen].bounds.size;
    self.bubbleBtn=[UIButton buttonWithType:UIButtonTypeCustom];
    self.bubbleBtn.frame=CGRectMake(sz.width-70,90,56,56);
    self.bubbleBtn.backgroundColor=[UIColor colorWithRed:.08 green:.08 blue:.1 alpha:.92];
    self.bubbleBtn.layer.cornerRadius=28;
    self.bubbleBtn.layer.borderWidth=1.5;
    self.bubbleBtn.layer.borderColor=[UIColor colorWithWhite:1 alpha:.25].CGColor;
    self.bubbleBtn.layer.shadowColor=[UIColor blackColor].CGColor;
    self.bubbleBtn.layer.shadowOpacity=.5;
    self.bubbleBtn.layer.shadowOffset=CGSizeMake(0,3);
    self.bubbleBtn.layer.shadowRadius=8;
    [self.bubbleBtn setTitle:@"🎬" forState:UIControlStateNormal];
    self.bubbleBtn.titleLabel.font=[UIFont systemFontOfSize:26];
    [self.bubbleBtn addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan=[[UIPanGestureRecognizer alloc] initWithTarget:_panTarget action:@selector(pan:)];
    pan.maximumNumberOfTouches=1; pan.delaysTouchesBegan=NO; pan.delaysTouchesEnded=NO;
    [self.bubbleBtn addGestureRecognizer:pan];

    _logLabel=[[UILabel alloc] initWithFrame:CGRectMake(sz.width-185,150,175,60)];
    _logLabel.numberOfLines=3; _logLabel.font=[UIFont systemFontOfSize:9];
    _logLabel.textColor=[UIColor colorWithRed:.2 green:1 blue:.4 alpha:1];
    _logLabel.backgroundColor=[UIColor colorWithWhite:0 alpha:.65];
    _logLabel.layer.cornerRadius=6; _logLabel.layer.masksToBounds=YES;

    [self.rootViewController.view addSubview:self.bubbleBtn];
    [self.rootViewController.view addSubview:_logLabel];

    // Zoom butonları — balonun altında
    UIButton *zoomIn  = [UIButton buttonWithType:UIButtonTypeCustom];
    UIButton *zoomOut = [UIButton buttonWithType:UIButtonTypeCustom];
    for (UIButton *b in @[zoomIn, zoomOut]) {
        b.backgroundColor = [UIColor colorWithWhite:0 alpha:.75];
        b.layer.cornerRadius = 14;
        b.titleLabel.font = [UIFont boldSystemFontOfSize:18];
        [self.rootViewController.view addSubview:b];
    }
    zoomIn.frame  = CGRectMake(sz.width-70, 154, 28, 28);
    zoomOut.frame = CGRectMake(sz.width-38, 154, 28, 28);
    [zoomIn  setTitle:@"+" forState:UIControlStateNormal];
    [zoomOut setTitle:@"−" forState:UIControlStateNormal];
    [zoomIn  addTarget:self action:@selector(zoomIn)  forControlEvents:UIControlEventTouchUpInside];
    [zoomOut addTarget:self action:@selector(zoomOut) forControlEvents:UIControlEventTouchUpInside];

    self.hidden=NO;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(bringToFront)
        name:UIWindowDidBecomeVisibleNotification object:nil];
    return self;
}

- (void)log:(NSString *)msg {
    NSLog(@"[CI] %@",msg);
    dispatch_async(dispatch_get_main_queue(), ^{ _logLabel.text=msg; });
}
- (void)bringToFront {
    dispatch_async(dispatch_get_main_queue(), ^{ if(self.isHidden) self.hidden=NO; });
}
- (void)tapped {
    CIFrameInjector *inj=(CIFrameInjector *)_injector;
    if (inj.running) { [inj stop]; [self setInjecting:NO]; return; }
    UIViewController *vc=CITopVC();
    if (!vc) { [self log:@"❌ VC yok"]; return; }
    UIImagePickerController *picker=[UIImagePickerController new];
    picker.sourceType=UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes=@[@"public.movie"];
    picker.videoQuality=UIImagePickerControllerQualityTypeHigh;
    if (!_pickerDelegate) _pickerDelegate=[CIPickerDelegate new];
    picker.delegate=(id)_pickerDelegate;
    [vc presentViewController:picker animated:YES completion:nil];
}

- (void)zoomIn  { [(CIFrameInjector *)_injector setZoom:MIN(4.0, [(CIFrameInjector *)_injector zoom]+0.25)]; [self updateZoomLabel]; }
- (void)zoomOut { [(CIFrameInjector *)_injector setZoom:MAX(0.5, [(CIFrameInjector *)_injector zoom]-0.25)]; [self updateZoomLabel]; }
- (void)updateZoomLabel {
    CGFloat z = [(CIFrameInjector *)_injector zoom];
    [self log:[NSString stringWithFormat:@"🔍 zoom: %.2fx", z]];
}
- (void)setInjecting:(BOOL)on {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (on) { [self.bubbleBtn setTitle:@"⏹" forState:UIControlStateNormal];
            self.bubbleBtn.backgroundColor=[UIColor colorWithRed:.75 green:.1 blue:.1 alpha:.92];
        } else { [self.bubbleBtn setTitle:@"🎬" forState:UIControlStateNormal];
            self.bubbleBtn.backgroundColor=[UIColor colorWithRed:.08 green:.08 blue:.1 alpha:.92]; }
    });
}
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    for (UIView *sub in self.rootViewController.view.subviews) {
        CGPoint lp=[sub convertPoint:p fromView:self];
        if (!sub.hidden && CGRectContainsPoint(sub.bounds,lp)) return sub;
    }
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
        _injector=[CIFrameInjector new];
        _proxy=[CIProxyDelegate new];
        _pickerDelegate=[CIPickerDelegate new];
        _panTarget=[CIPanTarget new];
        [CIBubbleWindow shared];
        NSLog(@"[CI] ✅ hazır");
    });
}
