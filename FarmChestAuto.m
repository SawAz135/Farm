// FarmChestAuto.m
// Full auto Fortnite chest farm + player detect + auto-aim
// Offsets: v43.00 (CL-59596594)
// Target: iOS arm64 (jailbreak / ESign force-load)

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <CoreGraphics/CoreGraphics.h>

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

#pragma mark - Anti Debug

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

#pragma mark - Memory (direct read — same process)

static uintptr_t gameBase = 0;

static uintptr_t readPtr(uintptr_t addr) {
    if (!addr) return 0;
    return *(uintptr_t *)addr;
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

#pragma mark - Screen + Color

static UIImage *captureScreen(void) {
    UIWindow *w = UIApplication.sharedApplication.keyWindow;
    if (!w) return nil;
    UIGraphicsBeginImageContextWithOptions(w.bounds.size, NO, 1.0);
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
    BOOL wood  = (r > 0.32 && r < 0.82 && g > 0.16 && g < 0.52 && b < 0.38 && (r - g) > 0.04);
    BOOL rare  = (r > 0.15 && r < 0.45 && g > 0.35 && g < 0.75 && b > 0.25 && b < 0.65);
    BOOL gold  = (r > 0.55 && r < 0.95 && g > 0.40 && g < 0.80 && b < 0.35);
    return wood || rare || gold;
}

static BOOL isPlayerColor(UIColor *c) {
    if (!c) return NO;
    CGFloat r, g, b, a;
    [c getRed:&r green:&g blue:&b alpha:&a];
    BOOL skin = (r > 0.45 && r < 0.95 && g > 0.25 && g < 0.75 && b > 0.15 && b < 0.55 && (r - b) > 0.1);
    BOOL bright = (r > 0.6 || g > 0.6 || b > 0.6) && (r + g + b) > 1.4;
    return skin || bright;
}

static NSArray<NSValue *> *scanChests(UIImage *img) {
    NSMutableArray *pts = [NSMutableArray array];
    CGFloat step = 20;
    CGSize sz = img.size;
    for (CGFloat y = 50; y < sz.height - 50; y += step) {
        for (CGFloat x = 20; x < sz.width - 20; x += step) {
            UIColor *c = colorAt(img, CGPointMake(x, y));
            if (isChestColor(c)) {
                int hits = 0;
                for (int dy = -6; dy <= 6; dy += 6)
                    for (int dx = -6; dx <= 6; dx += 6)
                        if (isChestColor(colorAt(img, CGPointMake(x+dx, y+dy)))) hits++;
                if (hits >= 3)
                    [pts addObject:[NSValue valueWithCGPoint:CGPointMake(x, y)]];
            }
        }
    }
    return pts;
}

static NSArray<NSValue *> *scanPlayers(UIImage *img) {
    NSMutableArray *pts = [NSMutableArray array];
    CGFloat step = 18;
    CGSize sz = img.size;
    CGPoint center = CGPointMake(sz.width / 2, sz.height / 2);
    for (CGFloat y = 80; y < sz.height - 80; y += step) {
        for (CGFloat x = 40; x < sz.width - 40; x += step) {
            UIColor *c = colorAt(img, CGPointMake(x, y));
            if (isPlayerColor(c)) {
                int hits = 0;
                for (int dy = -5; dy <= 5; dy += 5)
                    for (int dx = -5; dx <= 5; dx += 5)
                        if (isPlayerColor(colorAt(img, CGPointMake(x+dx, y+dy)))) hits++;
                if (hits >= 4) {
                    CGFloat dist = hypot(x - center.x, y - center.y);
                    if (dist > 80)
                        [pts addObject:[NSValue valueWithCGPoint:CGPointMake(x, y)]];
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

    if (longPress) [NSThread sleepForTimeInterval:0.7];

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
    CGPoint dest = CGPointMake(stickCenter.x + dir.x * 55, stickCenter.y + dir.y * 55);
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
    CGPoint delta = CGPointMake((target.x - screenCenter.x) * 0.35,
                                (target.y - screenCenter.y) * 0.35);
    lookAround(delta);
}

#pragma mark - Menu

@interface FarmMenu : UIView
@property (nonatomic, strong) UIButton *startBtn;
@property (nonatomic, strong) UIButton *autoBtn;
@property (nonatomic, strong) UIButton *aimBtn;
@property (nonatomic, strong) UILabel  *status;
@property (nonatomic, strong) UISlider *speed;
@property (nonatomic, strong) NSMutableArray<NSValue *> *chests;
@property (nonatomic, strong) NSMutableArray<NSValue *> *players;
@property (nonatomic, assign) NSInteger lastIndex;
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
    self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.93];
    self.layer.cornerRadius = 16;
    self.layer.borderWidth = 1.8;
    self.layer.borderColor = [UIColor colorWithRed:0.1 green:0.9 blue:0.4 alpha:1].CGColor;

    self.chests = [NSMutableArray array];
    self.players = [NSMutableArray array];
    self.lastIndex = -1;
    self.running = NO;
    self.autoRestart = YES;
    self.autoAim = YES;
    self.state = StateLobby;
    self.restartPoint = CGPointMake(210, 640);
    self.interval = 2.4;
    self.timer = 0;
    self.stateTimer = 0;

    _status = [[UILabel alloc] initWithFrame:CGRectMake(12, 10, frame.size.width-24, 20)];
    _status.text = @"READY";
    _status.textColor = UIColor.whiteColor;
    _status.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightMedium];
    [self addSubview:_status];

    _startBtn = [self btn:@"START AUTO" frame:CGRectMake(12, 38, 130, 36) color:[UIColor colorWithRed:0.1 green:0.55 blue:0.25 alpha:1] action:@selector(toggle)];
    _autoBtn  = [self btn:@"RESTART 15m: ON" frame:CGRectMake(150, 38, 130, 36) color:[UIColor colorWithRed:0.15 green:0.4 blue:0.75 alpha:1] action:@selector(toggleAuto)];
    _aimBtn   = [self btn:@"AIM: ON" frame:CGRectMake(12, 80, 268, 32) color:[UIColor colorWithRed:0.6 green:0.2 blue:0.2 alpha:1] action:@selector(toggleAim)];

    UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(12, 120, 80, 14)];
    lab.text = @"Speed";
    lab.textColor = UIColor.lightGrayColor;
    lab.font = [UIFont systemFontOfSize:11];
    [self addSubview:lab];

    _speed = [[UISlider alloc] initWithFrame:CGRectMake(12, 136, frame.size.width-24, 28)];
    _speed.minimumValue = 1.5;
    _speed.maximumValue = 4.0;
    _speed.value = 2.4;
    _speed.minimumTrackTintColor = [UIColor colorWithRed:0.1 green:0.85 blue:0.4 alpha:1];
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
    b.layer.cornerRadius = 8;
    b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:b];
    return b;
}

- (void)toggle {
    self.running = !self.running;
    if (self.running) {
        [_startBtn setTitle:@"STOP" forState:UIControlStateNormal];
        _startBtn.backgroundColor = [UIColor colorWithRed:0.75 green:0.15 blue:0.15 alpha:1];
        self.state = StateLobby;
        self.stateTimer = 0;
        self.timer = 0;
        [self tick];
    } else {
        [_startBtn setTitle:@"START AUTO" forState:UIControlStateNormal];
        _startBtn.backgroundColor = [UIColor colorWithRed:0.1 green:0.55 blue:0.25 alpha:1];
        _status.text = @"STOPPED";
        [NSObject cancelPreviousPerformRequestsWithTarget:self];
    }
}

- (void)toggleAuto {
    self.autoRestart = !self.autoRestart;
    [_autoBtn setTitle:self.autoRestart ? @"RESTART 15m: ON" : @"RESTART 15m: OFF" forState:UIControlStateNormal];
    _autoBtn.backgroundColor = self.autoRestart ? [UIColor colorWithRed:0.15 green:0.4 blue:0.75 alpha:1] : [UIColor colorWithRed:0.3 green:0.3 blue:0.3 alpha:1];
}

- (void)toggleAim {
    self.autoAim = !self.autoAim;
    [_aimBtn setTitle:self.autoAim ? @"AIM: ON" : @"AIM: OFF" forState:UIControlStateNormal];
    _aimBtn.backgroundColor = self.autoAim ? [UIColor colorWithRed:0.6 green:0.2 blue:0.2 alpha:1] : [UIColor colorWithRed:0.3 green:0.3 blue:0.3 alpha:1];
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
    return isChestColor(colorAt(shot, p));
}

- (void)tick {
    if (!self.running) return;

    self.stateTimer += self.interval;
    self.timer += self.interval;

    switch (self.state) {
        case StateLobby:
            _status.text = @"LOBBY — waiting bus";
            if (self.stateTimer > 8.0) {
                TapAt(CGPointMake(200, 500), NO);
                self.state = StateBus;
                self.stateTimer = 0;
            }
            break;

        case StateBus:
            _status.text = @"BUS — dropping soon";
            if (self.stateTimer > 12.0) {
                TapAt(CGPointMake(200, 480), NO);
                lookAround(CGPointMake(0, -30));
                self.state = StateDropping;
                self.stateTimer = 0;
            }
            break;

        case StateDropping:
            _status.text = @"DROPPING";
            if (self.stateTimer > 6.0) {
                moveStick(CGPointMake(0, 1), 1.2);
                self.state = StateFarming;
                self.stateTimer = 0;
                [self fullScan];
            }
            break;

        case StateFarming: {
            _status.text = [NSString stringWithFormat:@"FARM — %lu c / %lu p", (unsigned long)self.chests.count, (unsigned long)self.players.count];
            if (self.chests.count == 0 || ((int)self.stateTimer % 20) < 1) {
                [self fullScan];
                if (self.chests.count == 0) {
                    CGPoint dir = CGPointMake((arc4random()%3)-1, (arc4random()%3)-1);
                    moveStick(dir, 0.8);
                    lookAround(CGPointMake((arc4random()%60)-30, (arc4random()%40)-20));
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
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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

#pragma mark - Bootstrap

static UIWindow *gWin = nil;

__attribute__((constructor))
static void init(void) {
    denyAttach();
    if (isDebugged()) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gWin = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        gWin.windowLevel = UIWindowLevelAlert + 2;
        gWin.backgroundColor = UIColor.clearColor;
        gWin.hidden = NO;

        FarmMenu *m = [[FarmMenu alloc] initWithFrame:CGRectMake(12, 100, 292, 180)];
        [gWin addSubview:m];
        [m addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:m action:@selector(handlePan:)]];
    });
}
