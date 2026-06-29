//
//  DeviceIdHook.m — deviceId spoof (header + body + URL)
//  Constructor'da hook kur, UI sonra yükle
//
//  Build:
//  clang -arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
//    -miphoneos-version-min=13.0 -shared -fobjc-arc -O2 \
//    -framework UIKit -framework Foundation \
//    DeviceIdHook.m fishhook.c -o DeviceIdHook.dylib
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ─── Ayarlar ─────────────────────────────────────────────────────────────
static NSString *const kTargetId  = @"77bc647fc7ccc3aec3cd94eace776e68fc23b1661774527271fd";
static NSString *const kFakeId    = @"aabbccddeeff00112233445566778899aabbccddeeff00112233";

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Hook implementations
// NOT: Bu fonksiyonlar constructor'dan önce tanımlanmalı
// ═══════════════════════════════════════════════════════════════════════════

static IMP orig_setValue;
static IMP orig_setBody;
static IMP orig_setURL;

static NSString *replaceStr(NSString *s) {
    if (!s || ![s containsString:kTargetId]) return s;
    return [s stringByReplacingOccurrencesOfString:kTargetId withString:kFakeId];
}

static NSData *replaceData(NSData *data) {
    if (!data) return data;
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!s || ![s containsString:kTargetId]) return data;
    return [[s stringByReplacingOccurrencesOfString:kTargetId withString:kFakeId]
            dataUsingEncoding:NSUTF8StringEncoding];
}

static void h_setValue(id self, SEL _cmd, NSString *val, NSString *field) {
    NSString *replaced = replaceStr(val);
    if (replaced != val)
        NSLog(@"[DHook][SPOOF] Header %@: %@ → %@", field, val, replaced);
    ((void(*)(id,SEL,NSString*,NSString*))orig_setValue)(self, _cmd, replaced, field);
}

static void h_setBody(id self, SEL _cmd, NSData *body) {
    NSData *replaced = replaceData(body);
    if (replaced != body) NSLog(@"[DHook][SPOOF] Body değiştirildi");
    ((void(*)(id,SEL,NSData*))orig_setBody)(self, _cmd, replaced);
}

static void h_setURL(id self, SEL _cmd, NSURL *url) {
    NSString *abs = url.absoluteString;
    NSString *replaced = replaceStr(abs);
    if (replaced != abs) {
        NSLog(@"[DHook][SPOOF] URL değiştirildi");
        url = [NSURL URLWithString:replaced];
    }
    ((void(*)(id,SEL,NSURL*))orig_setURL)(self, _cmd, url);
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Overlay (sadece log göstermek için, spoof'tan bağımsız)
// ═══════════════════════════════════════════════════════════════════════════

@interface DHOverlay : UIWindow
+ (instancetype)shared;
- (void)addLog:(NSString *)msg;
@end

@implementation DHOverlay {
    UILabel *_stats; UITextView *_tv; UIView *_panel; UIButton *_minBtn;
    NSMutableString *_logs; BOOL _min;
}
+ (instancetype)shared {
    static DHOverlay *i; static dispatch_once_t t;
    dispatch_once(&t, ^{
        i = [[DHOverlay alloc] initWithFrame:UIScreen.mainScreen.bounds];
        i.windowLevel = UIWindowLevelAlert + 100;
        i.backgroundColor = UIColor.clearColor;
        i->_logs = [NSMutableString string];
        [i buildUI]; i.hidden = NO;
    }); return i;
}
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *h = [super hitTest:p withEvent:e];
    return h == self ? nil : h;
}
- (void)buildUI {
    CGFloat W = UIScreen.mainScreen.bounds.size.width;
    _panel = [[UIView alloc] initWithFrame:CGRectMake(8,60,W-16,280)];
    _panel.backgroundColor = [UIColor colorWithRed:0.04 green:0.04 blue:0.07 alpha:0.95];
    _panel.layer.cornerRadius = 12; _panel.clipsToBounds = YES;

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0,0,W-16,36)];
    bar.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.12 alpha:1];
    UILabel *ttl = [[UILabel alloc] initWithFrame:CGRectMake(12,10,W-100,16)];
    ttl.text = @"🎭 deviceId Spoof"; ttl.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    ttl.textColor = [UIColor colorWithWhite:0.9 alpha:1]; [bar addSubview:ttl];
    _minBtn = [UIButton buttonWithType:UIButtonTypeCustom]; _minBtn.frame = CGRectMake(W-16-40,6,36,24);
    [_minBtn setTitle:@"−" forState:UIControlStateNormal];
    _minBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [_minBtn setTitleColor:[UIColor colorWithWhite:0.6 alpha:1] forState:UIControlStateNormal];
    [_minBtn addTarget:self action:@selector(toggleMin) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:_minBtn]; [_panel addSubview:bar];

    _stats = [[UILabel alloc] initWithFrame:CGRectMake(8,38,W-32,16)];
    _stats.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    _stats.textColor = [UIColor colorWithWhite:0.45 alpha:1];
    _stats.text = [NSString stringWithFormat:@"fake: %.16s…", kFakeId.UTF8String];
    [_panel addSubview:_stats];

    _tv = [[UITextView alloc] initWithFrame:CGRectMake(0,56,W-16,280-56-36)];
    _tv.backgroundColor = UIColor.clearColor; _tv.editable = NO; _tv.selectable = NO;
    _tv.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    _tv.textColor = [UIColor colorWithRed:0.85 green:0.85 blue:0.85 alpha:1];
    [_panel addSubview:_tv];

    UIView *bot = [[UIView alloc] initWithFrame:CGRectMake(0,280-36,W-16,36)];
    bot.backgroundColor = [UIColor colorWithRed:0.06 green:0.06 blue:0.10 alpha:1];
    UIButton *clr = [UIButton buttonWithType:UIButtonTypeCustom]; clr.frame = CGRectMake(10,6,60,24);
    [clr setTitle:@"Temizle" forState:UIControlStateNormal];
    clr.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    [clr setTitleColor:[UIColor colorWithWhite:0.5 alpha:1] forState:UIControlStateNormal];
    [clr addTarget:self action:@selector(clearLogs) forControlEvents:UIControlEventTouchUpInside];
    [bot addSubview:clr];
    UIButton *cpy = [UIButton buttonWithType:UIButtonTypeCustom]; cpy.frame = CGRectMake(W-16-80,4,72,28);
    [cpy setTitle:@"📋 Kopyala" forState:UIControlStateNormal];
    cpy.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [cpy setTitleColor:[UIColor colorWithRed:0.47 green:0.75 blue:1.0 alpha:1] forState:UIControlStateNormal];
    cpy.layer.borderWidth=0.5; cpy.layer.cornerRadius=6;
    cpy.layer.borderColor=[UIColor colorWithRed:0.47 green:0.75 blue:1.0 alpha:0.4].CGColor;
    [cpy addTarget:self action:@selector(copyLogs) forControlEvents:UIControlEventTouchUpInside];
    [bot addSubview:cpy]; [_panel addSubview:bot];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
    [bar addGestureRecognizer:pan]; [self addSubview:_panel];
}
- (void)addLog:(NSString *)msg {
    NSDateFormatter *f = [NSDateFormatter new]; f.dateFormat = @"HH:mm:ss";
    [_logs appendFormat:@"[%@] %@\n", [f stringFromDate:[NSDate date]], msg];
    _tv.text = _logs;
    [_tv scrollRangeToVisible:NSMakeRange(_logs.length, 0)];
}
- (void)clearLogs { [_logs setString:@""]; _tv.text = @""; }
- (void)copyLogs { [UIPasteboard generalPasteboard].string = _logs; }
- (void)toggleMin {
    _min = !_min; CGRect f = _panel.frame; f.size.height = _min ? 36 : 280;
    [UIView animateWithDuration:0.2 animations:^{ self->_panel.frame = f; }];
    [_minBtn setTitle:_min ? @"+" : @"−" forState:UIControlStateNormal];
}
- (void)pan:(UIPanGestureRecognizer *)gr {
    CGPoint t = [gr translationInView:self]; CGRect f = _panel.frame, s = UIScreen.mainScreen.bounds;
    f.origin.x = MAX(0, MIN(f.origin.x+t.x, s.size.width-f.size.width));
    f.origin.y = MAX(20, MIN(f.origin.y+t.y, s.size.height-f.size.height-20));
    _panel.frame = f; [gr setTranslation:CGPointZero inView:self];
}
@end

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Constructor
// Hook'lar burada kurulur — ObjC runtime bu noktada hazır
// UI ayrıca 1 sn sonra yüklenir
// ═══════════════════════════════════════════════════════════════════════════

__attribute__((constructor))
static void init(void) {
    // Foundation sınıfları dylib load'da hazır, swizzle güvenli
    Class cls = [NSMutableURLRequest class];

    Method m1 = class_getInstanceMethod(cls, @selector(setValue:forHTTPHeaderField:));
    if (m1) { orig_setValue = method_getImplementation(m1); method_setImplementation(m1, (IMP)h_setValue); }

    Method m2 = class_getInstanceMethod(cls, @selector(setHTTPBody:));
    if (m2) { orig_setBody = method_getImplementation(m2); method_setImplementation(m2, (IMP)h_setBody); }

    Method m3 = class_getInstanceMethod(cls, @selector(setURL:));
    if (m3) { orig_setURL = method_getImplementation(m3); method_setImplementation(m3, (IMP)h_setURL); }

    NSLog(@"[DHook] Hook'lar kuruldu. Hedef: %@", kTargetId);

    // UI geç yükle — crash olmaz
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[DHOverlay shared] addLog:@"✅ Spoof aktif"];
        [[DHOverlay shared] addLog:[NSString stringWithFormat:@"Hedef: %.16s…", kTargetId.UTF8String]];
        [[DHOverlay shared] addLog:[NSString stringWithFormat:@"Fake : %.16s…", kFakeId.UTF8String]];
    });
}
