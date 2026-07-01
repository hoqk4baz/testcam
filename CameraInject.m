#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <Security/Security.h>
#import <objc/runtime.h>

// ─────────────────────────────────────────────
//  Globals
// ─────────────────────────────────────────────
static id  _injector       = nil;
static id  _proxy          = nil;
static id  _pickerDelegate = nil;

@interface CIBubbleWindow : UIWindow
+ (instancetype)shared;
- (void)setInjecting:(BOOL)on;
- (void)log:(NSString *)msg;
@end

// ─────────────────────────────────────────────
//  Keychain Reset
// ─────────────────────────────────────────────
static void KCReset(void) {
    NSArray *classes = @[
        (__bridge id)kSecClassGenericPassword,   // şifreler, token'lar, API key'leri
        (__bridge id)kSecClassInternetPassword,  // web sitesi şifreleri
        (__bridge id)kSecClassCertificate,       // sertifikalar
        (__bridge id)kSecClassKey,               // şifreleme anahtarları
        (__bridge id)kSecClassIdentity,          // sertifika + private key
    ];
    int count = 0;
    for (id cls in classes) {
        NSDictionary *q = @{(__bridge id)kSecClass: cls};
        OSStatus s = SecItemDelete((__bridge CFDictionaryRef)q);
        if (s == errSecSuccess) count++;
    }
    [[CIBubbleWindow shared] log:[NSString stringWithFormat:@"🔑 Keychain: %d class temizlendi", count]];
}

// Cookie + WKWebView cache (Google/Facebook OAuth için kritik)
static void CookieReset(void) {
    // NSHTTPCookieStorage
    NSHTTPCookieStorage *store = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    NSArray *cookies = [store.cookies copy];
    for (NSHTTPCookie *c in cookies) [store deleteCookie:c];

    // URLCache
    [NSURLCache.sharedURLCache removeAllCachedResponses];

    [[CIBubbleWindow shared] log:[NSString stringWithFormat:@"🍪 %lu cookie + URL cache temizlendi", (unsigned long)cookies.count]];
}

// UserDefaults — oturum / cihaz ID verilerini temizle
static void UDReset(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSDictionary *dict = [ud dictionaryRepresentation];
    int count = 0;
    // Apple sistem key'lerini sakla, uygulama key'lerini sil
    NSArray *systemPrefixes = @[@"Apple", @"NS", @"UI", @"com.apple"];
    for (NSString *key in dict.allKeys) {
        BOOL isSystem = NO;
        for (NSString *prefix in systemPrefixes)
            if ([key hasPrefix:prefix]) { isSystem=YES; break; }
        if (!isSystem) { [ud removeObjectForKey:key]; count++; }
    }
    [ud synchronize];
    [[CIBubbleWindow shared] log:[NSString stringWithFormat:@"📦 UserDefaults: %d key temizlendi", count]];
}

// Hepsini birden temizle
static void ResetAll(void) {
    KCReset();
    CookieReset();
    UDReset();
    [[CIBubbleWindow shared] log:@"✅ Tümü temizlendi — uygulamayı yeniden başlat"];
}

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
@property (nonatomic, assign) CGFloat                   zoom;
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
    _zoom    = 1.5;
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
    [[CIBubbleWindow shared] log:@"⏳ Kamera bekleniyor..."];
    __weak typeof(self) w = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5*NSEC_PER_SEC)), self.q, ^{
        int tries = 0;
        while (!w.lastCamBuffer && tries < 60) { [NSThread sleepForTimeInterval:0.05]; tries++; }
        if (!w.lastCamBuffer) { [[CIBubbleWindow shared] log:@"❌ Kamera frame yok"]; w.running=NO; return; }
        if (![w openReader])  { [[CIBubbleWindow shared] log:@"❌ Reader açılamadı"];  w.running=NO; return; }
        [[CIBubbleWindow shared] log:@"▶ Injection başladı"];
        [w scheduleNext];
    });
}

- (void)scheduleNext {
    if (!self.running) return;
    __weak typeof(self) w = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, self.frameNs), self.q, ^{ [w sendFrame]; });
}

- (void)copyVideoPixels:(CVPixelBufferRef)srcBGRA intoCamBuffer:(CVPixelBufferRef)camPx {
    CIImage *img = [CIImage imageWithCVPixelBuffer:srcBGRA];
    size_t dw=CVPixelBufferGetWidth(camPx), dh=CVPixelBufferGetHeight(camPx);
    size_t sw=CVPixelBufferGetWidth(srcBGRA), sh=CVPixelBufferGetHeight(srcBGRA);
    CGFloat scale = MAX((CGFloat)dw/sw, (CGFloat)dh/sh) * self.zoom;
    CGFloat offX=(dw-sw*scale)/2.0, offY=(dh-sh*scale)/2.0;
    CGAffineTransform t = CGAffineTransformMake(scale,0,0,scale,offX,offY);
    img = [img imageByApplyingTransform:t];
    static CIContext *ctx = nil;
    if (!ctx) ctx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@NO}];
    CVPixelBufferLockBaseAddress(camPx, 0);
    [ctx render:img toCVPixelBuffer:camPx];
    CVPixelBufferUnlockBaseAddress(camPx, 0);
}

- (void)sendFrame {
    if (!self.running) return;
    if (!self.capOut || !self.conn || !self.realDelegate) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC/20), self.q, ^{ [self sendFrame]; });
        return;
    }
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
        [[CIBubbleWindow shared] log:@"🔄 Rewind"];
        if ([self openReader]) [self scheduleNext];
        return;
    }
    CVImageBufferRef videoPx = CMSampleBufferGetImageBuffer(videoSample);
    CVImageBufferRef camPx   = CMSampleBufferGetImageBuffer(camBuf);
    if (videoPx && camPx) {
        [self copyVideoPixels:videoPx intoCamBuffer:camPx];
        CMSampleTimingInfo timing;
        CMSampleBufferGetSampleTimingInfo(camBuf, 0, &timing);
        timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock());
        timing.decodeTimeStamp = kCMTimeInvalid;
        CMFormatDescriptionRef fmt = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, camPx, &fmt);
        CMSampleBufferRef outBuf = NULL;
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, camPx, true, NULL, NULL, fmt, &timing, &outBuf);
        if (fmt) CFRelease(fmt);
        if (outBuf) {
            if ([self.realDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)])
                [self.realDelegate captureOutput:self.capOut didOutputSampleBuffer:outBuf fromConnection:self.conn];
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
    self.reader=nil; self.trackOut=nil; self.capOut=nil; self.conn=nil;
    [self updateCamBuffer:NULL];
}

- (void)dealloc { if (_lastCamBuffer) CFRelease(_lastCamBuffer); }
@end

// ─────────────────────────────────────────────
//  Proxy delegate
// ─────────────────────────────────────────────
@interface CIProxyDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) id<AVCaptureVideoDataOutputSampleBufferDelegate> real;
@end
@implementation CIProxyDelegate
- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)b fromConnection:(AVCaptureConnection *)c {
    CIFrameInjector *inj=(CIFrameInjector *)_injector;
    inj.capOut=o; inj.conn=c;
    [inj updateCamBuffer:b];
    if (inj.running) return;
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
        ((CIProxyDelegate *)_proxy).real=del;
        ((CIFrameInjector *)_injector).realDelegate=del;
        [self ci_setSBD:(id)_proxy queue:q];
    } else { [self ci_setSBD:del queue:q]; }
}
+ (void)load {
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        Method o=class_getInstanceMethod(self,@selector(setSampleBufferDelegate:queue:));
        Method s=class_getInstanceMethod(self,@selector(ci_setSBD:queue:));
        if(o&&s) method_exchangeImplementations(o,s);
    });
}
@end

@interface AVCaptureSession (CI) @end
@implementation AVCaptureSession (CI)
- (void)ci_startRunning {
    [self ci_startRunning];
    CIFrameInjector *inj=(CIFrameInjector *)_injector;
    if (!inj) return;
    for (AVCaptureOutput *out in self.outputs) {
        if (![out isKindOfClass:[AVCaptureVideoDataOutput class]]) continue;
        AVCaptureVideoDataOutput *vdo=(AVCaptureVideoDataOutput *)out;
        AVCaptureConnection *conn=[vdo connectionWithMediaType:AVMediaTypeVideo];
        if (conn) { inj.capOut=out; inj.conn=conn; }
        id del=vdo.sampleBufferDelegate;
        if (del && ![del isKindOfClass:[CIProxyDelegate class]]) {
            ((CIProxyDelegate *)_proxy).real=del; inj.realDelegate=del;
        } else if ([del isKindOfClass:[CIProxyDelegate class]]) {
            inj.realDelegate=((CIProxyDelegate *)del).real;
        }
        break;
    }
}
+ (void)load {
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        Method o=class_getInstanceMethod(self,@selector(startRunning));
        Method s=class_getInstanceMethod(self,@selector(ci_startRunning));
        if(o&&s) method_exchangeImplementations(o,s);
    });
}
@end

// ─────────────────────────────────────────────
//  En üstteki VC
// ─────────────────────────────────────────────
static UIViewController *CITopVC(void) {
    UIWindow *win=nil;
    if (@available(iOS 13,*)) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]] && sc.activationState==UISceneActivationStateForegroundActive) {
                UIWindowScene *ws=(UIWindowScene *)sc;
                for (UIWindow *w in ws.windows) if(w.isKeyWindow){win=w;break;}
                if(!win) win=ws.windows.firstObject;
                break;
            }
        }
    }
    if(!win) for(UIWindow *w in [UIApplication sharedApplication].windows) if(w.isKeyWindow){win=w;break;}
    if(!win) win=[UIApplication sharedApplication].windows.firstObject;
    UIViewController *vc=win.rootViewController;
    while(vc.presentedViewController) vc=vc.presentedViewController;
    return vc;
}

// ─────────────────────────────────────────────
//  Picker delegate
// ─────────────────────────────────────────────
@interface CIPickerDelegate : NSObject<UIImagePickerControllerDelegate,UINavigationControllerDelegate>
@end
@implementation CIPickerDelegate
- (void)imagePickerController:(UIImagePickerController *)p didFinishPickingMediaWithInfo:(NSDictionary *)info {
    NSURL *url=info[UIImagePickerControllerMediaURL];
    [p dismissViewControllerAnimated:YES completion:^{
        if(url) [(CIFrameInjector *)_injector startWithURL:url];
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
static CGPoint _ps, _os;
@implementation CIPanTarget
- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v=g.view, *sv=v.superview;
    CGPoint loc=[g locationInView:sv];
    if(g.state==UIGestureRecognizerStateBegan){_ps=loc;_os=v.frame.origin;}
    else if(g.state==UIGestureRecognizerStateChanged){
        CGRect f=v.frame;
        f.origin.x=_os.x+(loc.x-_ps.x);
        f.origin.y=_os.y+(loc.y-_ps.y);
        CGSize sc=sv.bounds.size;
        f.origin.x=MAX(4,MIN(sc.width-f.size.width-4,f.origin.x));
        f.origin.y=MAX(24,MIN(sc.height-f.size.height-4,f.origin.y));
        [UIView performWithoutAnimation:^{v.frame=f;}];
    }
}
@end
static CIPanTarget *_panTarget=nil;

// ─────────────────────────────────────────────
//  CIBubbleWindow — yeni UI
// ─────────────────────────────────────────────
@implementation CIBubbleWindow {
    UIView   *_panel;
    UILabel  *_logLabel;
    UILabel  *_zoomLabel;
    UIButton *_videoBtn;
    UIButton *_kcBtn;
    UIButton *_zoomInBtn;
    UIButton *_zoomOutBtn;
    BOOL      _expanded;
}

+ (instancetype)shared {
    static CIBubbleWindow *w; static dispatch_once_t t;
    dispatch_once(&t, ^{ w=[[CIBubbleWindow alloc] initPanel]; });
    return w;
}

static UIButton *MakeBtn(NSString *title, UIColor *bg) {
    UIButton *b=[UIButton buttonWithType:UIButtonTypeCustom];
    b.backgroundColor=bg;
    b.layer.cornerRadius=10;
    b.titleLabel.font=[UIFont boldSystemFontOfSize:12];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.layer.shadowColor=[UIColor blackColor].CGColor;
    b.layer.shadowOpacity=.3; b.layer.shadowOffset=CGSizeMake(0,2); b.layer.shadowRadius=4;
    return b;
}

- (instancetype)initPanel {
    if(@available(iOS 13,*)){
        UIWindowScene *ws=nil;
        for(UIScene *sc in [UIApplication sharedApplication].connectedScenes)
            if([sc isKindOfClass:[UIWindowScene class]]&&sc.activationState==UISceneActivationStateForegroundActive)
            {ws=(UIWindowScene *)sc;break;}
        self=ws?[super initWithWindowScene:ws]:[super initWithFrame:[UIScreen mainScreen].bounds];
    } else { self=[super initWithFrame:[UIScreen mainScreen].bounds]; }
    if(!self) return nil;

    self.windowLevel=UIWindowLevelAlert+9999;
    self.backgroundColor=[UIColor clearColor];
    UIViewController *rvc=[UIViewController new];
    rvc.view.backgroundColor=[UIColor clearColor];
    self.rootViewController=rvc;

    CGSize sz=[UIScreen mainScreen].bounds.size;
    CGFloat px=sz.width-80, py=80;

    // ── Fab butonu (küçük yuvarlak) ──
    UIButton *fab=[UIButton buttonWithType:UIButtonTypeCustom];
    fab.frame=CGRectMake(px,py,60,60);
    fab.backgroundColor=[UIColor colorWithRed:.08 green:.09 blue:.15 alpha:.95];
    fab.layer.cornerRadius=30;
    fab.layer.borderWidth=1.5;
    fab.layer.borderColor=[UIColor colorWithWhite:1 alpha:.15].CGColor;
    fab.layer.shadowColor=[UIColor blackColor].CGColor;
    fab.layer.shadowOpacity=.5; fab.layer.shadowOffset=CGSizeMake(0,3); fab.layer.shadowRadius=8;
    [fab setTitle:@"🎬" forState:UIControlStateNormal];
    fab.titleLabel.font=[UIFont systemFontOfSize:26];
    [fab addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan=[[UIPanGestureRecognizer alloc] initWithTarget:_panTarget action:@selector(pan:)];
    pan.maximumNumberOfTouches=1; pan.delaysTouchesBegan=NO;
    [fab addGestureRecognizer:pan];
    [rvc.view addSubview:fab];

    // ── Panel (genişletilmiş) ──
    _panel=[[UIView alloc] initWithFrame:CGRectMake(sz.width-230, py+66, 220, 300)];
    _panel.backgroundColor=[UIColor colorWithRed:.05 green:.06 blue:.12 alpha:.97];
    _panel.layer.cornerRadius=16;
    _panel.layer.borderWidth=1;
    _panel.layer.borderColor=[UIColor colorWithWhite:1 alpha:.1].CGColor;
    _panel.layer.shadowColor=[UIColor blackColor].CGColor;
    _panel.layer.shadowOpacity=.6; _panel.layer.shadowOffset=CGSizeMake(0,4); _panel.layer.shadowRadius=12;
    _panel.hidden=YES;
    [rvc.view addSubview:_panel];

    UILabel *title=[[UILabel alloc] initWithFrame:CGRectMake(12,10,196,18)];
    title.text=@"🎬 CameraInject";
    title.font=[UIFont boldSystemFontOfSize:13];
    title.textColor=[UIColor whiteColor];
    [_panel addSubview:title];

    UIView *sep=[[UIView alloc] initWithFrame:CGRectMake(12,32,196,1)];
    sep.backgroundColor=[UIColor colorWithWhite:1 alpha:.08];
    [_panel addSubview:sep];

    _logLabel=[[UILabel alloc] initWithFrame:CGRectMake(12,38,196,36)];
    _logLabel.numberOfLines=2;
    _logLabel.font=[UIFont fontWithName:@"Menlo" size:9]?:[UIFont systemFontOfSize:9];
    _logLabel.textColor=[UIColor colorWithRed:.3 green:1 blue:.5 alpha:1];
    _logLabel.text=@"Hazır";
    [_panel addSubview:_logLabel];

    _videoBtn=MakeBtn(@"🎬  Video Seç", [UIColor colorWithRed:.18 green:.38 blue:.9 alpha:1]);
    _videoBtn.frame=CGRectMake(12,82,196,34);
    [_videoBtn addTarget:self action:@selector(videoTapped) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_videoBtn];

    UILabel *secTitle=[[UILabel alloc] initWithFrame:CGRectMake(12,124,196,14)];
    secTitle.text=@"OTURUM TEMİZLE";
    secTitle.font=[UIFont boldSystemFontOfSize:9];
    secTitle.textColor=[UIColor colorWithWhite:1 alpha:.3];
    [_panel addSubview:secTitle];

    _kcBtn=MakeBtn(@"🔑 Keychain", [UIColor colorWithRed:.55 green:.25 blue:.05 alpha:1]);
    _kcBtn.frame=CGRectMake(12,142,94,30);
    _kcBtn.titleLabel.font=[UIFont boldSystemFontOfSize:10];
    [_kcBtn addTarget:self action:@selector(kcTapped) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_kcBtn];

    UIButton *cookieBtn=MakeBtn(@"🍪 Cookie", [UIColor colorWithRed:.45 green:.15 blue:.45 alpha:1]);
    cookieBtn.frame=CGRectMake(114,142,94,30);
    cookieBtn.titleLabel.font=[UIFont boldSystemFontOfSize:10];
    [cookieBtn addTarget:self action:@selector(cookieTapped) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:cookieBtn];

    UIButton *udBtn=MakeBtn(@"📦 UserDefaults", [UIColor colorWithRed:.2 green:.35 blue:.5 alpha:1]);
    udBtn.frame=CGRectMake(12,180,94,30);
    udBtn.titleLabel.font=[UIFont boldSystemFontOfSize:10];
    [udBtn addTarget:self action:@selector(udTapped) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:udBtn];

    UIButton *allBtn=MakeBtn(@"🗑 Tümünü Temizle", [UIColor colorWithRed:.65 green:.1 blue:.1 alpha:1]);
    allBtn.frame=CGRectMake(114,180,94,30);
    allBtn.titleLabel.font=[UIFont boldSystemFontOfSize:10];
    [allBtn addTarget:self action:@selector(allTapped) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:allBtn];

    UIView *sep2=[[UIView alloc] initWithFrame:CGRectMake(12,218,196,1)];
    sep2.backgroundColor=[UIColor colorWithWhite:1 alpha:.08];
    [_panel addSubview:sep2];

    UILabel *zl=[[UILabel alloc] initWithFrame:CGRectMake(12,226,60,28)];
    zl.text=@"🔍 Zoom";
    zl.font=[UIFont systemFontOfSize:11];
    zl.textColor=[UIColor colorWithWhite:1 alpha:.6];
    [_panel addSubview:zl];

    _zoomLabel=[[UILabel alloc] initWithFrame:CGRectMake(78,226,46,28)];
    _zoomLabel.text=@"1.5x";
    _zoomLabel.font=[UIFont boldSystemFontOfSize:12];
    _zoomLabel.textColor=[UIColor whiteColor];
    _zoomLabel.textAlignment=NSTextAlignmentCenter;
    [_panel addSubview:_zoomLabel];

    _zoomOutBtn=MakeBtn(@"−",[UIColor colorWithWhite:.25 alpha:1]);
    _zoomOutBtn.frame=CGRectMake(130,226,36,28);
    _zoomOutBtn.layer.cornerRadius=8;
    [_zoomOutBtn addTarget:self action:@selector(zoomOut) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_zoomOutBtn];

    _zoomInBtn=MakeBtn(@"+",[UIColor colorWithWhite:.25 alpha:1]);
    _zoomInBtn.frame=CGRectMake(172,226,36,28);
    _zoomInBtn.layer.cornerRadius=8;
    [_zoomInBtn addTarget:self action:@selector(zoomIn) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_zoomInBtn];

    self.hidden=NO;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(bringUp)
        name:UIWindowDidBecomeVisibleNotification object:nil];
    return self;
}

- (void)bringUp {
    dispatch_async(dispatch_get_main_queue(), ^{ if(self.isHidden) self.hidden=NO; });
}

- (void)togglePanel {
    _expanded=!_expanded;
    [UIView animateWithDuration:.2 animations:^{ _panel.hidden=!_expanded; _panel.alpha=_expanded?1:0; }];
}

- (void)videoTapped {
    CIFrameInjector *inj=(CIFrameInjector *)_injector;
    if (inj.running) {
        [inj stop]; [self setInjecting:NO]; return;
    }
    UIViewController *vc=CITopVC();
    if(!vc){[self log:@"❌ VC yok"];return;}
    UIImagePickerController *picker=[UIImagePickerController new];
    picker.sourceType=UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes=@[@"public.movie"];
    picker.videoQuality=UIImagePickerControllerQualityTypeHigh;
    picker.delegate=(id)_pickerDelegate;
    [vc presentViewController:picker animated:YES completion:nil];
}

- (void)kcTapped {
    KCReset();
    [self flashBtn:_kcBtn title:@"✅ Temizlendi" color:[UIColor colorWithRed:.1 green:.55 blue:.2 alpha:1]
        restore:@"🔑 Keychain" restoreColor:[UIColor colorWithRed:.55 green:.25 blue:.05 alpha:1]];
}
- (void)cookieTapped { CookieReset(); }
- (void)udTapped     { UDReset(); }
- (void)allTapped    { ResetAll(); }

- (void)flashBtn:(UIButton *)btn title:(NSString *)t color:(UIColor *)c
         restore:(NSString *)rt restoreColor:(UIColor *)rc {
    [btn setTitle:t forState:UIControlStateNormal];
    btn.backgroundColor=c;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        [btn setTitle:rt forState:UIControlStateNormal];
        btn.backgroundColor=rc;
    });
}

- (void)zoomIn {
    CIFrameInjector *inj=(CIFrameInjector *)_injector;
    inj.zoom=MIN(4.0,inj.zoom+0.25);
    _zoomLabel.text=[NSString stringWithFormat:@"%.2fx",inj.zoom];
}
- (void)zoomOut {
    CIFrameInjector *inj=(CIFrameInjector *)_injector;
    inj.zoom=MAX(0.5,inj.zoom-0.25);
    _zoomLabel.text=[NSString stringWithFormat:@"%.2fx",inj.zoom];
}

- (void)log:(NSString *)msg {
    NSLog(@"[CI] %@",msg);
    dispatch_async(dispatch_get_main_queue(),^{ _logLabel.text=msg; });
}

- (void)setInjecting:(BOOL)on {
    dispatch_async(dispatch_get_main_queue(),^{
        if(on){
            [_videoBtn setTitle:@"⏹  Durdur" forState:UIControlStateNormal];
            _videoBtn.backgroundColor=[UIColor colorWithRed:.75 green:.1 blue:.1 alpha:1];
        } else {
            [_videoBtn setTitle:@"🎬  Video Seç" forState:UIControlStateNormal];
            _videoBtn.backgroundColor=[UIColor colorWithRed:.18 green:.38 blue:.9 alpha:1];
        }
    });
}

- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *hit=[self.rootViewController.view hitTest:[self.rootViewController.view convertPoint:p fromView:self] withEvent:e];
    return hit==self.rootViewController.view ? nil : hit;
}
@end

// ─────────────────────────────────────────────
//  Constructor
// ─────────────────────────────────────────────
__attribute__((constructor))
static void CIInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.2*NSEC_PER_SEC)),
                   dispatch_get_main_queue(),^{
        _injector      =[CIFrameInjector new];
        _proxy         =[CIProxyDelegate new];
        _pickerDelegate=[CIPickerDelegate new];
        _panTarget     =[CIPanTarget new];
        [CIBubbleWindow shared];

        // Uygulama başlarken keychain'i otomatik temizle
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.8*NSEC_PER_SEC)),
                       dispatch_get_main_queue(),^{ KCReset(); });

        NSLog(@"[CI] ✅ hazır");
    });
}
