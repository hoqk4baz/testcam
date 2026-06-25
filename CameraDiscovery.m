#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

// ─────────────────────────────────────────────
//  CDLogWindow – sürüklenebilir overlay panel
// ─────────────────────────────────────────────
@interface CDLogWindow : UIWindow
@property (nonatomic, strong) UITextView   *textView;
@property (nonatomic, strong) UIButton     *copyBtn;
@property (nonatomic, strong) UIButton     *clearBtn;
@property (nonatomic, strong) UIButton     *closeBtn;
@property (nonatomic, strong) UILabel      *titleLabel;
@property (nonatomic, strong) NSMutableArray<NSString *> *lines;
@property (nonatomic, assign) CGPoint      dragOffset;
@end

@implementation CDLogWindow

+ (instancetype)shared {
    static CDLogWindow *w;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ w = [[CDLogWindow alloc] initPanel]; });
    return w;
}

- (instancetype)initPanel {
    // Küçük başlangıç boyutu, kullanıcı büyütebilir
    CGRect f = CGRectMake(10, 80, 320, 260);
    self = [super initWithFrame:f];
    if (!self) return nil;

    self.lines = [NSMutableArray new];
    self.windowLevel = UIWindowLevelAlert + 100;
    self.layer.cornerRadius = 12;
    self.layer.masksToBounds = YES;
    self.layer.borderColor  = [UIColor colorWithWhite:1 alpha:0.15].CGColor;
    self.layer.borderWidth  = 1;

    // Arka plan blur
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark];
    UIVisualEffectView *bgView = [[UIVisualEffectView alloc] initWithEffect:blur];
    bgView.frame = self.bounds;
    bgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:bgView];

    // ── Başlık çubuğu (drag handle) ──
    UIView *titleBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.bounds.size.width, 36)];
    titleBar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.3];
    titleBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self addSubview:titleBar];

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 0, 180, 36)];
    self.titleLabel.text = @"📷 Camera Discovery";
    self.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    self.titleLabel.textColor = [UIColor whiteColor];
    [titleBar addSubview:self.titleLabel];

    // Kapat butonu
    self.closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.closeBtn.frame = CGRectMake(self.bounds.size.width - 34, 4, 28, 28);
    self.closeBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [self.closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [self.closeBtn setTitleColor:[UIColor colorWithRed:1 green:0.4 blue:0.4 alpha:1] forState:UIControlStateNormal];
    self.closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [self.closeBtn addTarget:self action:@selector(toggleMinimize) forControlEvents:UIControlEventTouchUpInside];
    [titleBar addSubview:self.closeBtn];

    // Drag gesture
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [titleBar addGestureRecognizer:pan];

    // ── Log text view ──
    self.textView = [[UITextView alloc] initWithFrame:CGRectMake(0, 36, self.bounds.size.width, self.bounds.size.height - 36 - 44)];
    self.textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.textView.backgroundColor = [UIColor clearColor];
    self.textView.textColor = [UIColor colorWithRed:0.2 green:1 blue:0.4 alpha:1];
    self.textView.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    self.textView.editable = NO;
    self.textView.scrollEnabled = YES;
    self.textView.showsVerticalScrollIndicator = YES;
    [self addSubview:self.textView];

    // ── Alt buton çubuğu ──
    UIView *btnBar = [[UIView alloc] initWithFrame:CGRectMake(0, self.bounds.size.height - 44, self.bounds.size.width, 44)];
    btnBar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.3];
    btnBar.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
    [self addSubview:btnBar];

    // Panoya Kopyala butonu
    self.copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.copyBtn.frame = CGRectMake(8, 6, 140, 32);
    [self.copyBtn setTitle:@"📋 Panoya Kopyala" forState:UIControlStateNormal];
    [self.copyBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.copyBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    self.copyBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:1 alpha:0.8];
    self.copyBtn.layer.cornerRadius = 8;
    [self.copyBtn addTarget:self action:@selector(copyLogs) forControlEvents:UIControlEventTouchUpInside];
    [btnBar addSubview:self.copyBtn];

    // Temizle butonu
    self.clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.clearBtn.frame = CGRectMake(158, 6, 80, 32);
    [self.clearBtn setTitle:@"🗑 Temizle" forState:UIControlStateNormal];
    [self.clearBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.clearBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    self.clearBtn.backgroundColor = [UIColor colorWithWhite:0.3 alpha:0.8];
    self.clearBtn.layer.cornerRadius = 8;
    [self.clearBtn addTarget:self action:@selector(clearLogs) forControlEvents:UIControlEventTouchUpInside];
    [btnBar addSubview:self.clearBtn];

    // Sayaç label
    UILabel *countLbl = [[UILabel alloc] initWithFrame:CGRectMake(248, 6, 64, 32)];
    countLbl.tag = 999;
    countLbl.textAlignment = NSTextAlignmentRight;
    countLbl.textColor = [UIColor colorWithWhite:1 alpha:0.5];
    countLbl.font = [UIFont systemFontOfSize:10];
    [btnBar addSubview:countLbl];

    // Boyut tutacağı (resize handle — sağ alt köşe)
    UILabel *resizeHandle = [[UILabel alloc] initWithFrame:CGRectMake(self.bounds.size.width - 20, self.bounds.size.height - 20, 18, 18)];
    resizeHandle.text = @"⇲";
    resizeHandle.font = [UIFont systemFontOfSize:14];
    resizeHandle.textColor = [UIColor colorWithWhite:1 alpha:0.3];
    resizeHandle.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    [self addSubview:resizeHandle];

    UIPanGestureRecognizer *resize = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleResize:)];
    [resizeHandle addGestureRecognizer:resize];
    resizeHandle.userInteractionEnabled = YES;

    [self makeKeyAndVisible];
    return self;
}

// ── Sürükleme ──
- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint pt = [pan locationInView:nil];
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.dragOffset = CGPointMake(pt.x - self.frame.origin.x, pt.y - self.frame.origin.y);
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        self.frame = CGRectMake(pt.x - self.dragOffset.x,
                                pt.y - self.dragOffset.y,
                                self.frame.size.width,
                                self.frame.size.height);
    }
}

// ── Boyutlandırma ──
- (void)handleResize:(UIPanGestureRecognizer *)pan {
    CGPoint delta = [pan translationInView:self];
    [pan setTranslation:CGPointZero inView:self];
    CGRect f = self.frame;
    f.size.width  = MAX(260, f.size.width  + delta.x);
    f.size.height = MAX(160, f.size.height + delta.y);
    self.frame = f;
}

// ── Minimize / geri ──
static BOOL _minimized = NO;
static CGRect _savedFrame;
- (void)toggleMinimize {
    if (!_minimized) {
        _savedFrame = self.frame;
        [UIView animateWithDuration:0.2 animations:^{
            self.frame = CGRectMake(self.frame.origin.x, self.frame.origin.y, 160, 36);
        }];
        [self.closeBtn setTitle:@"▲" forState:UIControlStateNormal];
        _minimized = YES;
    } else {
        [UIView animateWithDuration:0.2 animations:^{
            self.frame = _savedFrame;
        }];
        [self.closeBtn setTitle:@"✕" forState:UIControlStateNormal];
        _minimized = NO;
    }
}

// ── Log ekle ──
- (void)appendLine:(NSString *)line {
    [self.lines addObject:line];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *all = [self.lines componentsJoinedByString:@"\n"];
        self.textView.text = all;
        // Alta kaydır
        if (self.textView.text.length > 0) {
            NSRange r = NSMakeRange(self.textView.text.length - 1, 1);
            [self.textView scrollRangeToVisible:r];
        }
        // Sayaç güncelle
        UILabel *cnt = (UILabel *)[self.subviews.lastObject viewWithTag:999];
        // btn bar son subview değil, tara
        for (UIView *v in self.subviews) {
            UILabel *l = (UILabel *)[v viewWithTag:999];
            if (l) { l.text = [NSString stringWithFormat:@"%lu satır", (unsigned long)self.lines.count]; break; }
        }
    });
}

// ── Panoya kopyala ──
- (void)copyLogs {
    NSString *all = [self.lines componentsJoinedByString:@"\n"];
    [UIPasteboard generalPasteboard].string = all;
    // Görsel geri bildirim
    NSString *orig = [self.copyBtn titleForState:UIControlStateNormal];
    [self.copyBtn setTitle:@"✅ Kopyalandı!" forState:UIControlStateNormal];
    self.copyBtn.backgroundColor = [UIColor colorWithRed:0.1 green:0.7 blue:0.3 alpha:0.9];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.copyBtn setTitle:orig forState:UIControlStateNormal];
        self.copyBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:1 alpha:0.8];
    });
}

// ── Temizle ──
- (void)clearLogs {
    [self.lines removeAllObjects];
    self.textView.text = @"";
}

// UIWindow'un event'leri bloklamasını engelle — arka plandaki app çalışsın
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}

@end

// ─────────────────────────────────────────────
//  Log helper
// ─────────────────────────────────────────────
static void CDLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSLog(@"[CameraDiscovery] %@", msg);

    dispatch_async(dispatch_get_main_queue(), ^{
        [[CDLogWindow shared] appendLine:msg];
    });
}

// ─────────────────────────────────────────────
//  Uygulama başlayınca window'u göster
// ─────────────────────────────────────────────
__attribute__((constructor))
static void CDInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [CDLogWindow shared];
        CDLog(@"🚀 CameraDiscovery dylib yüklendi");
    });
}

// ─────────────────────────────────────────────
//  1. AVCaptureSession
// ─────────────────────────────────────────────
@interface AVCaptureSession (CD) @end
@implementation AVCaptureSession (CD)

- (void)cd_startRunning {
    CDLog(@"✅ AVCaptureSession startRunning");
    [self cd_startRunning];
}
- (void)cd_stopRunning {
    CDLog(@"⏹ AVCaptureSession stopRunning");
    [self cd_stopRunning];
}
- (void)cd_addInput:(AVCaptureInput *)input {
    CDLog(@"➕ addInput: %@", NSStringFromClass([input class]));
    if ([input isKindOfClass:[AVCaptureDeviceInput class]]) {
        AVCaptureDeviceInput *di = (AVCaptureDeviceInput *)input;
        CDLog(@"   └─ device: %@  pos: %ld", di.device.localizedName, (long)di.device.position);
    }
    [self cd_addInput:input];
}
- (void)cd_addOutput:(AVCaptureOutput *)output {
    CDLog(@"➕ addOutput: %@", NSStringFromClass([output class]));
    [self cd_addOutput:output];
}

+ (void)load {
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        Class cls = [AVCaptureSession class];
        void(^sw)(SEL,SEL) = ^(SEL o, SEL s){
            Method mo = class_getInstanceMethod(cls, o);
            Method ms = class_getInstanceMethod(cls, s);
            if (mo && ms) method_exchangeImplementations(mo, ms);
        };
        sw(@selector(startRunning), @selector(cd_startRunning));
        sw(@selector(stopRunning),  @selector(cd_stopRunning));
        sw(@selector(addInput:),    @selector(cd_addInput:));
        sw(@selector(addOutput:),   @selector(cd_addOutput:));
    });
}
@end

// ─────────────────────────────────────────────
//  2. AVCaptureVideoDataOutput
// ─────────────────────────────────────────────
@interface CDDelegateProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> real;
@property (nonatomic, assign) BOOL logged;
@end
@implementation CDDelegateProxy
- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)buf
       fromConnection:(AVCaptureConnection *)conn {
    if (!self.logged) {
        self.logged = YES;
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(buf);
        CMMediaType mt = CMFormatDescriptionGetMediaType(fmt);
        CDLog(@"📸 didOutputSampleBuffer (type: %c%c%c%c)",
              (char)(mt>>24),(char)(mt>>16),(char)(mt>>8),(char)mt);
        CVImageBufferRef px = CMSampleBufferGetImageBuffer(buf);
        if (px) CDLog(@"   └─ %zu x %zu", CVPixelBufferGetWidth(px), CVPixelBufferGetHeight(px));
    }
    if ([self.real respondsToSelector:_cmd])
        [self.real captureOutput:output didOutputSampleBuffer:buf fromConnection:conn];
}
- (void)captureOutput:(AVCaptureOutput *)o didDropSampleBuffer:(CMSampleBufferRef)b fromConnection:(AVCaptureConnection *)c {
    if ([self.real respondsToSelector:_cmd]) [self.real captureOutput:o didDropSampleBuffer:b fromConnection:c];
}
- (BOOL)respondsToSelector:(SEL)s { return [super respondsToSelector:s] || [self.real respondsToSelector:s]; }
- (id)forwardingTargetForSelector:(SEL)s { return self.real; }
@end

@interface AVCaptureVideoDataOutput (CD) @end
@implementation AVCaptureVideoDataOutput (CD)
- (void)cd_setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)del queue:(dispatch_queue_t)q {
    CDLog(@"🔗 setSampleBufferDelegate: %@", NSStringFromClass([del class]));
    if (del) {
        CDDelegateProxy *p = [CDDelegateProxy new]; p.real = del;
        [self cd_setSampleBufferDelegate:p queue:q];
    } else { [self cd_setSampleBufferDelegate:nil queue:q]; }
}
+ (void)load {
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        Class cls = [AVCaptureVideoDataOutput class];
        Method o = class_getInstanceMethod(cls, @selector(setSampleBufferDelegate:queue:));
        Method s = class_getInstanceMethod(cls, @selector(cd_setSampleBufferDelegate:queue:));
        if (o && s) method_exchangeImplementations(o, s);
    });
}
@end

// ─────────────────────────────────────────────
//  3. AVCapturePhotoOutput
// ─────────────────────────────────────────────
@interface AVCapturePhotoOutput (CD) @end
@implementation AVCapturePhotoOutput (CD)
- (void)cd_capturePhotoWithSettings:(AVCapturePhotoSettings *)s delegate:(id)d {
    CDLog(@"📷 capturePhoto (delegate: %@)", NSStringFromClass([d class]));
    [self cd_capturePhotoWithSettings:s delegate:d];
}
+ (void)load {
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        Class cls = [AVCapturePhotoOutput class];
        Method o = class_getInstanceMethod(cls, @selector(capturePhotoWithSettings:delegate:));
        Method s = class_getInstanceMethod(cls, @selector(cd_capturePhotoWithSettings:delegate:));
        if (o && s) method_exchangeImplementations(o, s);
    });
}
@end

// ─────────────────────────────────────────────
//  4. AVCaptureDevice auth
// ─────────────────────────────────────────────
@interface AVCaptureDevice (CD) @end
@implementation AVCaptureDevice (CD)
+ (AVAuthorizationStatus)cd_authorizationStatusForMediaType:(AVMediaType)mt {
    AVAuthorizationStatus s = [self cd_authorizationStatusForMediaType:mt];
    CDLog(@"🔐 authorizationStatus(%@) → %ld", mt, (long)s);
    return s;
}
+ (void)cd_requestAccessForMediaType:(AVMediaType)mt completionHandler:(void(^)(BOOL))h {
    CDLog(@"🔐 requestAccess(%@)", mt);
    [self cd_requestAccessForMediaType:mt completionHandler:h];
}
+ (void)load {
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        Class meta = object_getClass([AVCaptureDevice class]);
        void(^sw)(SEL,SEL) = ^(SEL o, SEL s){
            Method mo = class_getInstanceMethod(meta, o);
            Method ms = class_getInstanceMethod(meta, s);
            if (mo && ms) method_exchangeImplementations(mo, ms);
        };
        sw(@selector(authorizationStatusForMediaType:), @selector(cd_authorizationStatusForMediaType:));
        sw(@selector(requestAccessForMediaType:completionHandler:), @selector(cd_requestAccessForMediaType:completionHandler:));
    });
}
@end

// ─────────────────────────────────────────────
//  5. UIImagePickerController (fallback)
// ─────────────────────────────────────────────
@interface UIImagePickerController (CD) @end
@implementation UIImagePickerController (CD)
- (void)cd_viewWillAppear:(BOOL)a {
    CDLog(@"📱 UIImagePickerController appeared (source: %ld)", (long)self.sourceType);
    [self cd_viewWillAppear:a];
}
+ (void)load {
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        Class cls = [UIImagePickerController class];
        Method o = class_getInstanceMethod(cls, @selector(viewWillAppear:));
        Method s = class_getInstanceMethod(cls, @selector(cd_viewWillAppear:));
        if (o && s) method_exchangeImplementations(o, s);
    });
}
@end
