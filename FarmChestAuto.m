// FarmChestAuto.m
// MAX version — full auto Fortnite farm + aim + anti-cheat + GUI
// Offsets: v43.00
// Target: iOS arm64 (jailbreak / ESign)

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <CoreGraphics/CoreGraphics.h>
#import <mach/mach.h>

// ===== Offsets v43.00 =====
#define OFFSET_GENGINE          0x1C8E2F48
#define OFFSET_GAMEVIEWPORT     0xB70
#define OFFSET_GAMEINSTANCE     0x248
#define OFFSET_PERSISTENTLEVEL  0x40
#define OFFSET_ACTORS           0x208
#define OFFSET_ROOTCOMPONENT    0x1B0
#define OFFSET_RELATIVELOCATION 0x140
#define OFFSET_LOCALPAWN        0x320
#define OFFSET_PLAYERCONTROLLER 0x30
#define OFFSET_LOCALPLAYERS     0x38
#define OFFSET_SEARCHEDFLAGS    0xD2A
#define OFFSET_TEAMINDEX        0xF81

typedef enum {
    StateLobby,
    StateBus,
    StateDropping,
    StateFarming,
    StateRestart
} GameState;

#pragma mark - Anti Debug MAX

static BOOL isDebugged(void) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    struct kinfo_proc info = {0};
    size_t size = sizeof(info);
    if (sysctl(mib, 4, &info, &size, NULL, 0) == 0)
        return (info.kp_proc.p_flag & P_TRACED) != 0;
    return NO;
}

static void denyAttach(void) {
    void *h = dlopen(NULL, RTLD_GLOBAL | RTLD_NOW);
    int (*ptrace_ptr)(int, pid_t, caddr_t, int) = dlsym(h, "ptrace");
    if (ptrace_ptr) ptrace_ptr(31, 0, 0, 0);
}

static void antiDebugTiming(void) {
    uint64_t start = mach_absolute_time();
    for (volatile int i = 0; i < 800; i++);
    uint64_t end = mach_absolute_time();
    if ((end - start) > 400000) exit(0);
}

#pragma mark - Memory

static uintptr_t gameBase = 0;

static uintptr_t readPtr(uintptr_t addr) {
    if (!addr || addr < 0x1000) return 0;
    @try { return *(uintptr_t *)addr; }
    @catch (__unused NSException *e) { return 0; }
}

static CGPoint readPlayerPos(void) {
    if (!gameBase) return CGPointZero;
    uintptr_t gEngine = readPtr(gameBase + OFFSET_GENGINE);
    if (!gEngine) return CGPointZero;
    uintptr_t viewport = readPtr(gEngine + OFFSET_GAMEVIEWPORT);
    uintptr_t world = readPtr(viewport + 0x78);
    uintptr_t gi = readPtr(world + OFFSET_GAMEINSTANCE);
    uintptr_t lp = readPtr(gi + OFFSET_LOCALPLAYERS);
    uintptr_t local = readPtr(lp);
    uintptr_t pc = readPtr(local + OFFSET_PLAYERCONTROLLER);
    uintptr_t pawn = readPtr(pc + OFFSET_LOCALPAWN);
    uintptr_t root = readPtr(pawn + OFFSET_ROOTCOMPONENT);
    if (!root) return CGPointZero;
    float *loc = (float *)(root + OFFSET_RELATIVELOCATION);
    return CGPointMake(loc[0], loc[1]);
}

#pragma mark - Screen + Color (optimisé)

static UIImage *captureScreen(void) {
    UIWindow *w = UIApplication.sharedApplication.keyWindow;
    if (!w) return nil;
    UIGraphicsBeginImageContextWithOptions(w.bounds.size, NO, 0.45);
    [w.layer renderInContext:UIGraphicsGetCurrentContext()];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

static UIColor *colorAt(UIImage *img, CGPoint p) {
    if (!img) return nil;
    CGImageRef cg = img.CGImage;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (p.x < 0 || p.y < 0 || p.x >= w || p.y >= h) return nil;
    CGDataProviderRef provider = CGImageGetDataProvider(cg);
    CFDataRef data = CGDataProviderCopyData(provider);
    const UInt8 *bytes = CFDataGetBytePtr(data);
    size_t bpp = 4, bpr = CGImageGetBytesPerRow(cg);
    size_t off = ((size_t)p.y) * bpr + ((size_t)p.x) * bpp;
    UInt8 r = bytes[off], g = bytes[off+1], b = bytes[off+2];
    CFRelease(data);
    return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1];
}

static BOOL isChestColor(UIColor *c) {
    if (!c) return NO;
    CGFloat r, g, b, a;
    [c getRed:&r green:&g blue:&b alpha:&a];
    BOOL wood  = (r > 0.30 && r < 0.84 && g > 0.14 && g < 0.54 && b < 0.40 && (r - g) > 0.03);
    BOOL rare  = (r > 0.12 && r < 0.48 && g > 0.32 && g < 0.78 && b > 0.22 && b < 0.68);
    BOOL gold  = (r > 0.52 && r < 0.96 && g > 0.38 && g < 0.82 && b < 0.38);
    return wood || rare || gold;
}

static BOOL isPlayerColor(UIColor *c) {
    if (!c) return NO;
    CGFloat r, g, b, a;
    [c getRed:&r green:&g blue:&b alpha:&a];
    BOOL skin = (r > 0.42 && r < 0.96 && g > 0.22 && g < 0.78 && b > 0.12 && b < 0.58 && (r - b) > 0.08);
    BOOL bright = (r > 0.58 || g > 0.58 || b > 0.58) && (r + g + b) > 1.35;
    return skin || bright;
}

static NSArray<NSValue *> *scanChests(UIImage *img) {
    NSMutableArray *pts = [NSMutableArray array];
    CGFloat step = 26;
    CGSize sz = img.size;
    CGFloat scale = 1.0 / 0.45;
    for (CGFloat y = 50; y < sz.height - 50; y += step) {
        for (CGFloat x = 25; x < sz.width - 25; x += step) {
            UIColor *c = colorAt(img, CGPointMake(x, y));
            if (isChestColor(c)) {
                int hits = 0;
                for (int dy = -7; dy <= 7; dy += 7)
                    for (int dx = -7; dx <= 7; dx += 7)
                        if (isChestColor(colorAt(img, CGPointMake(x+dx, y+dy)))) hits++;
                if (hits >= 3)
                    [pts addObject:[NSValue valueWithCGPoint:CGPointMake(x * scale, y * scale)]];
            }
        }
    }
    return pts;
}

static NSArray<NSValue *> *scanPlayers(UIImage *img) {
    NSMutableArray *pts = [NSMutableArray array];
    CGFloat step = 22;
    CGSize sz = img.size;
    CGPoint center = CGPointMake(sz.width / 2, sz.height / 2);
    CGFloat scale = 1.0 / 0.45;
    for (CGFloat y = 90; y < sz.height - 90; y += step) {
        for (CGFloat x = 45; x < sz.width - 45; x += step) {
            UIColor *c = colorAt(img, CGPointMake(x, y));
            if (isPlayerColor(c)) {
                int hits = 0;
                for (int dy = -5; dy <= 5; dy += 5)
                    for (int dx = -5; dx <= 5; dx += 5)
                        if (isPlayerColor(colorAt(img, CGPointMake(x+dx, y+dy)))) hits++;
                if (hits >= 4) {
                    CGFloat dist = hypot(x - center.x, y - center.y);
                    if (dist > 90)
                        [pts addObject:[NSValue valueWithCGPoint:CGPointMake(x * scale, y * scale)]];
                }
            }
        }
    }
    return pts;
}

#pragma mark - Touch

@interface UITouch (Private)
- (id)_initWithTarget:(id)target;
- (void)setWindow:(UIWindow *)window;
- (void)setView:(UIView *)view;
- (void)setIsTap:(BOOL)isTap;
- (void)setTimestamp:(NSTimeInterval)timestamp;
- (void)setPhase:(UITouchPhase)phase;
- (void)setTapCount:(NSUInteger)count;
- (void)_setLocationInWindow:(CGPoint)location resetPrevious:(BOOL)reset;
@end

@interface UIApplication (Private)
- (UIEvent *)_touchesEvent;
@end

static void TapAt(CGPoint p, BOOL longPress) {
    UIWindow *w = UIApplication.sharedApplication.keyWindow;
    if (!w) return;
    UITouch *t = [[UITouch alloc] _initWithTarget:w];
    [t setWindow:w];
    [t setView:w];
    [t setIsTap:!longPress];
    [t setTimestamp:NSProcessInfo.processInfo.systemUptime];
    [t setPhase:UITouchPhaseBegan];
    [t setTapCount:1];
    [t _setLocationInWindow:p resetPrevious:YES];

    UIEvent *e = [UIApplication.sharedApplication _touchesEvent];
    @try {
        [e setValue:[NSSet setWithObject:t] forKey:@"_touches"];
        [UIApplication.sharedApplication sendEvent:e];
    } @catch (__unused NSException *ex) {}

    if (longPress) [NSThread sleepForTimeInterval:0.62];

    [t setPhase:UITouchPhaseEnded];
    [t setTimestamp:NSProcessInfo.processInfo.systemUptime];
    @try {
        [e setValue:[NSSet setWithObject:t] forKey:@"_touches"];
        [UIApplication.sharedApplication sendEvent:e];
    } @catch (__unused NSException *ex) {}
}

static void moveStick(CGPoint dir, NSTimeInterval duration) {
    CGPoint stickCenter = CGPointMake(95, 530);
    TapAt(stickCenter, NO);
    CGPoint dest = CGPointMake(stickCenter.x + dir.x * 58, stickCenter.y + dir.y * 58);
    TapAt(dest, NO);
    [NSThread sleepForTimeInterval:duration];
    TapAt(stickCenter, NO);
}

static void lookAround(CGPoint delta) {
    CGPoint lookCenter = CGPointMake(280, 400);
    TapAt(lookCenter, NO);
    TapAt(CGPointMake(lookCenter.x + delta.x, lookCenter.y + delta.y), NO);
}

static void aimAt(CGPoint target) {
    CGPoint screenCenter = CGPointMake(UIScreen.mainScreen.bounds.size.width / 2,
                                       UIScreen.mainScreen.bounds.size.height / 2);
    CGPoint delta = CGPointMake((target.x - screenCenter.x) * 0.30,
                                (target.y - screenCenter.y) * 0.30);
    lookAround(delta);
}

#pragma mark - Menu

@interface FarmMenu : UIView
@property (nonatomic, strong) UIButton *startBtn;
@property (nonatomic, strong) UIButton *autoBtn;
@property (nonatomic, strong) UIButton *aimBtn;
@property (nonatomic, strong) UIButton *closeBtn;
@property (nonatomic, strong) UILabel  *status;
@property (nonatomic, strong) UISlider *speed;
@property (nonatomic, strong) NSMutableArray<NSValue *> *chests;
@property (nonatomic, strong) NSMutableArray<NSValue *> *players;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) BOOL autoRestart;
@property (nonatomic, assign) BOOL autoAim;
@property (nonatomic, assign) GameState state;
@property (nonatomic, assign) CGPoint restartPoint;
@property (nonatomic, assign) NSTimeInterval interval;
@property (nonatomic, assign) NSTimeInterval timer;
@property (nonatomic, assign) NSTimeInterval stateTimer;
@end

@implementation FarmMenu

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.94];
    self.layer.cornerRadius = 20;
    self.layer.borderWidth = 2.2;
    self.layer.borderColor = [UIColor colorWithRed:0.0 green:0.88 blue:0.48 alpha:1].CGColor;
    self.clipsToBounds = YES;

    self.chests = [NSMutableArray array];
    self.players = [NSMutableArray array];
    self.running = NO;
    self.autoRestart = YES;
    self.autoAim = YES;
    self.state = StateLobby;
    self.restartPoint = CGPointMake(210, 640);
    self.interval = 2.1;
    self.timer = 0;
    self.stateTimer = 0;

    _closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _closeBtn.frame = CGRectMake(frame.size.width - 38, 8, 30, 30);
    [_closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [_closeBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:19];
    [_closeBtn addTarget:self action:@selector(closeMenu) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_closeBtn];

    _status = [[UILabel alloc] initWithFrame:CGRectMake(14, 14, frame.size.width - 54, 24)];
    _status.text = @"READY";
    _status.textColor = UIColor.whiteColor;
    _status.font = [UIFont monospacedSystemFontOfSize:14.5 weight:UIFontWeightMedium];
    [self addSubview:_status];

    _startBtn = [self btn:@"START AUTO" frame:CGRectMake(14, 48, 132, 40) color:[UIColor colorWithRed:0.06 green:0.58 blue:0.30 alpha:1] action:@selector(toggle)];
    _autoBtn  = [self btn:@"RESTART 15m: ON" frame:CGRectMake(154, 48, 132, 40) color:[UIColor colorWithRed:0.10 green:0.40 blue:0.75 alpha:1] action:@selector(toggleAuto)];
    _aimBtn   = [self btn:@"AIM: ON" frame:CGRectMake(14, 96, 272, 36) color:[UIColor colorWithRed:0.68 green:0.16 blue:0.16 alpha:1] action:@selector(toggleAim)];

    UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(14, 140, 70, 16)];
    lab.text = @"Speed";
    lab.textColor = UIColor.lightGrayColor;
    lab.font = [UIFont systemFontOfSize:12];
    [self addSubview:lab];

    _speed = [[UISlider alloc] initWithFrame:CGRectMake(14, 156, frame.size.width - 28, 32)];
    _speed.minimumValue = 1.3;
    _speed.maximumValue = 3.6;
    _speed.value = 2.1;
    _speed.minimumTrackTintColor = [UIColor colorWithRed:0.0 green:0.82 blue:0.48 alpha:1];
    [_speed addTarget:self action:@selector(speedChanged:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:_speed];

    return self;
}

- (UIButton *)btn:(NSString *)title frame:(CGRect)f color:(UIColor *)c action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = f;
    [b setTitle:title forState:UIControlStateNormal];
    b.backgroundColor = c;
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.layer.cornerRadius = 10;
    b.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:b];
    return b;
}

- (void)closeMenu {
    self.hidden = YES;
}

- (void)toggle {
    self.running = !self.running;
    if (self.running) {
        [_startBtn setTitle:@"STOP" forState:UIControlStateNormal];
        _startBtn.backgroundColor = [UIColor colorWithRed:0.80 green:0.10 blue:0.10 alpha:1];
        self.state = StateLobby;
        self.stateTimer = 0;
        self.timer = 0;
        [self tick];
    } else {
        [_startBtn setTitle:@"START AUTO" forState:UIControlStateNormal];
        _startBtn.backgroundColor = [UIColor colorWithRed:0.06 green:0.58 blue:0.30 alpha:1];
        _status.text = @"STOPPED";
        [NSObject cancelPreviousPerformRequestsWithTarget:self];
    }
}

- (void)toggleAuto {
    self.autoRestart = !self.autoRestart;
    [_autoBtn setTitle:self.autoRestart ? @"RESTART 15m: ON" : @"RESTART 15m: OFF" forState:UIControlStateNormal];
    _autoBtn.backgroundColor = self.autoRestart ? [UIColor colorWithRed:0.10 green:0.40 blue:0.75 alpha:1] : [UIColor colorWithRed:0.30 green:0.30 blue:0.30 alpha:1];
}

- (void)toggleAim {
    self.autoAim = !self.autoAim;
    [_aimBtn setTitle:self.autoAim ? @"AIM: ON" : @"AIM: OFF" forState:UIControlStateNormal];
    _aimBtn.backgroundColor = self.autoAim ? [UIColor colorWithRed:0.68 green:0.16 blue:0.16 alpha:1] : [UIColor colorWithRed:0.30 green:0.30 blue:0.30 alpha:1];
}

- (void)speedChanged:(UISlider *)s { self.interval = s.value; }

- (void)fullScan {
    UIImage *shot = captureScreen();
    NSArray *chests = scanChests(shot);
    NSArray *players = scanPlayers(shot);
    [self.chests removeAllObjects];
    [self.chests addObjectsFromArray:chests];
    [self.players removeAllObjects];
    [self.players addObjectsFromArray:players];
}

- (BOOL)stillChestAt:(CGPoint)p {
    UIImage *shot = captureScreen();
    CGFloat scale = 0.45;
    return isChestColor(colorAt(shot, CGPointMake(p.x * scale, p.y * scale)));
}

- (void)tick {
    if (!self.running) return;

    self.stateTimer += self.interval;
    self.timer += self.interval;

    switch (self.state) {
        case StateLobby:
            _status.text = @"LOBBY — waiting bus";
            if (self.stateTimer > 7.0) {
                TapAt(CGPointMake(200, 500), NO);
                self.state = StateBus;
                self.stateTimer = 0;
            }
            break;

        case StateBus:
            _status.text = @"BUS — dropping soon";
            if (self.stateTimer > 10.5) {
                TapAt(CGPointMake(200, 480), NO);
                lookAround(CGPointMake(0, -26));
                self.state = StateDropping;
                self.stateTimer = 0;
            }
            break;

        case StateDropping:
            _status.text = @"DROPPING";
            if (self.stateTimer > 5.0) {
                moveStick(CGPointMake(0, 1), 1.0);
                self.state = StateFarming;
                self.stateTimer = 0;
                [self fullScan];
            }
            break;

        case StateFarming: {
            _status.text = [NSString stringWithFormat:@"FARM — %lu c / %lu p", (unsigned long)self.chests.count, (unsigned long)self.players.count];
            if (self.chests.count == 0 || ((int)self.stateTimer % 16) < 1) {
                [self fullScan];
                if (self.chests.count == 0) {
                    CGPoint dir = CGPointMake((arc4random()%3)-1, (arc4random()%3)-1);
                    moveStick(dir, 0.65);
                    lookAround(CGPointMake((arc4random()%48)-24, (arc4random()%34)-17));
                }
            }

            if (self.autoAim && self.players.count > 0) {
                CGPoint closest = [self.players[0] CGPointValue];
                CGPoint center = CGPointMake(UIScreen.mainScreen.bounds.size.width / 2,
                                             UIScreen.mainScreen.bounds.size.height / 2);
                CGFloat best = 99999;
                for (NSValue *v in self.players) {
                    CGPoint p = [v CGPointValue];
                    CGFloat d = hypot(p.x - center.x, p.y - center.y);
                    if (d < best) { best = d; closest = p; }
                }
                aimAt(closest);
            }

            if (self.chests.count > 0) {
                NSInteger idx = arc4random_uniform((uint32_t)self.chests.count);
                CGPoint p = [self.chests[idx] CGPointValue];
                TapAt(p, YES);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.48 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (![self stillChestAt:p]) {
                        if (idx < self.chests.count) [self.chests removeObjectAtIndex:idx];
                    }
                });
            }
            break;
        }

        case StateRestart:
            break;
    }

    if (self.autoRestart && self.timer >= 900.0) {
        _status.text = @"RESTART MATCH";
        TapAt(self.restartPoint, NO);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            TapAt(self.restartPoint, NO);
        });
        self.timer = 0;
        self.state = StateLobby;
        self.stateTimer = 0;
        [self.chests removeAllObjects];
        [self.players removeAllObjects];
    }

    [self performSelector:@selector(tick) withObject:nil afterDelay:self.interval];
}

- (void)handlePan:(UIPanGestureRecognizer *)p {
    CGPoint t = [p translationInView:self.superview];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [p setTranslation:CGPointZero inView:self.superview];
}

@end

#pragma mark - Bootstrap + réouverture

static UIWindow *gWin = nil;
static FarmMenu *gMenu = nil;

__attribute__((constructor))
static void init(void) {
    denyAttach();
    antiDebugTiming();
    if (isDebugged()) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gWin = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        gWin.windowLevel = UIWindowLevelAlert + 2;
        gWin.backgroundColor = UIColor.clearColor;
        gWin.hidden = NO;
        gWin.userInteractionEnabled = YES;

        gMenu = [[FarmMenu alloc] initWithFrame:CGRectMake(12, 85, 300, 200)];
        [gWin addSubview:gMenu];
        [gMenu addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:gMenu action:@selector(handlePan:)]];

        UITapGestureRecognizer *triple = [[UITapGestureRecognizer alloc] initWithTarget:gMenu action:@selector(reopen)];
        triple.numberOfTapsRequired = 3;
        [gWin addGestureRecognizer:triple];
    });
}

@implementation FarmMenu (Reopen)
- (void)reopen {
    self.hidden = NO;
}
@end
