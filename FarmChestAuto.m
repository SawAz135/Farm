// FarmChestAuto.m
// MAX AUTONOME — mémoire + image fallback + bus + marche + open + ESP
// Offsets: v43.00 CL-59596594
// Target: iOS arm64 (injecté dans le processus)

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

#pragma mark - Memory

static uintptr_t gameBase = 0;

static uintptr_t readPtr(uintptr_t addr) {
    if (!addr || addr < 0x1000) return 0;
    @try { return *(uintptr_t *)addr; }
    @catch (__unused NSException *e) { return 0; }
}

static float readFloat(uintptr_t addr) {
    if (!addr) return 0.f;
    @try { return *(float *)addr; }
    @catch (__unused NSException *e) { return 0.f; }
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
    float x = readFloat(root + OFFSET_RELATIVELOCATION);
    float y = readFloat(root + OFFSET_RELATIVELOCATION + 4);
    return CGPointMake(x, y);
}

static NSArray *readChestWorldPositions(void) {
    NSMutableArray *chests = [NSMutableArray array];
    if (!gameBase) return chests;

    uintptr_t gEngine = readPtr(gameBase + OFFSET_GENGINE);
    if (!gEngine) return chests;
    uintptr_t viewport = readPtr(gEngine + OFFSET_GAMEVIEWPORT);
    uintptr_t world = readPtr(viewport + 0x78);
    uintptr_t level = readPtr(world + OFFSET_PERSISTENTLEVEL);
    uintptr_t actorsPtr = readPtr(level + OFFSET_ACTORS);
    int count = (int)readPtr(level + OFFSET_ACTORS + 8);
    count = MIN(MAX(count, 0), 8000);

    for (int i = 0; i < count; i++) {
        uintptr_t actor = readPtr(actorsPtr + i * 8);
        if (!actor) continue;

        uintptr_t root = readPtr(actor + OFFSET_ROOTCOMPONENT);
        if (!root) continue;

        uint8_t searched = 0;
        @try { searched = *(uint8_t *)(actor + OFFSET_SEARCHEDFLAGS); }
        @catch (__unused NSException *e) { continue; }

        if (searched == 0) {
            float x = readFloat(root + OFFSET_RELATIVELOCATION);
            float y = readFloat(root + OFFSET_RELATIVELOCATION + 4);
            if (fabsf(x) > 50.f && fabsf(y) > 50.f)
                [chests addObject:[NSValue valueWithCGPoint:CGPointMake(x, y)]];
        }
    }
    return chests;
}

#pragma mark - Screen (fallback)

static UIImage *captureScreen(void) {
    UIWindow *w = UIApplication.sharedApplication.keyWindow;
    if (!w) return nil;
    UIGraphicsBeginImageContextWithOptions(w.bounds.size, NO, 0.4);
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
    BOOL wood  = (r > 0.30 && r < 0.84 && g > 0.14 && g < 0.54 && b < 0.40);
    BOOL rare  = (r > 0.12 && r < 0.48 && g > 0.32 && g < 0.78 && b > 0.22 && b < 0.68);
    BOOL gold  = (r > 0.52 && r < 0.96 && g > 0.38 && g < 0.82 && b < 0.38);
    return wood || rare || gold;
}

static NSArray *scanChestsScreen(UIImage *img) {
    NSMutableArray *pts = [NSMutableArray array];
    CGFloat step = 28;
    CGSize sz = img.size;
    CGFloat scale = 1.0 / 0.4;
    for (CGFloat y = 60; y < sz.height - 60; y += step) {
        for (CGFloat x = 30; x < sz.width - 30; x += step) {
            if (isChestColor(colorAt(img, CGPointMake(x, y)))) {
                int hits = 0;
                for (int dy = -6; dy <= 6; dy += 6)
                    for (int dx = -6; dx <= 6; dx += 6)
                        if (isChestColor(colorAt(img, CGPointMake(x+dx, y+dy)))) hits++;
                if (hits >= 3)
                    [pts addObject:[NSValue valueWithCGPoint:CGPointMake(x * scale, y * scale)]];
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

    if (longPress) [NSThread sleepForTimeInterval:0.65];

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
    CGPoint dest = CGPointMake(stickCenter.x + dir.x * 60, stickCenter.y + dir.y * 60);
    TapAt(dest, NO);
    [NSThread sleepForTimeInterval:duration];
    TapAt(stickCenter, NO);
}

static void lookAround(CGPoint delta) {
    CGPoint lookCenter = CGPointMake(280, 400);
    TapAt(lookCenter, NO);
    TapAt(CGPointMake(lookCenter.x + delta.x, lookCenter.y + delta.y), NO);
}

#pragma mark - Menu

@interface FarmMenu : UIView
@property (nonatomic, strong) UIButton *startBtn;
@property (nonatomic, strong) UIButton *closeBtn;
@property (nonatomic, strong) UILabel  *status;
@property (nonatomic, strong) UISlider *speed;
@property (nonatomic, strong) NSMutableArray *worldChests;
@property (nonatomic, strong) NSMutableArray *screenChests;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) BOOL useMemory;
@property (nonatomic, assign) GameState state;
@property (nonatomic, assign) NSTimeInterval interval;
@property (nonatomic, assign) NSTimeInterval timer;
@property (nonatomic, assign) NSTimeInterval stateTimer;
@end

@implementation FarmMenu

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    self.clipsToBounds = YES;

    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.frame = self.bounds;
    gradient.colors = @[
        (id)[UIColor colorWithRed:0.05 green:0.05 blue:0.08 alpha:0.96].CGColor,
        (id)[UIColor colorWithRed:0.02 green:0.08 blue:0.05 alpha:0.94].CGColor
    ];
    gradient.startPoint = CGPointMake(0, 0);
    gradient.endPoint = CGPointMake(1, 1);
    [self.layer insertSublayer:gradient atIndex:0];

    self.layer.cornerRadius = 20;
    self.layer.borderWidth = 2.2;
    self.layer.borderColor = [UIColor colorWithRed:0.0 green:0.88 blue:0.48 alpha:1].CGColor;

    self.worldChests = [NSMutableArray array];
    self.screenChests = [NSMutableArray array];
    self.running = NO;
    self.useMemory = YES;
    self.state = StateLobby;
    self.interval = 1.8;
    self.timer = 0;
    self.stateTimer = 0;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, 200, 28)];
    title.text = @"FARM AUTO";
    title.textColor = [UIColor colorWithRed:0.0 green:0.9 blue:0.5 alpha:1];
    title.font = [UIFont boldSystemFontOfSize:18];
    [self addSubview:title];

    _closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _closeBtn.frame = CGRectMake(frame.size.width - 38, 8, 30, 30);
    [_closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [_closeBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:19];
    [_closeBtn addTarget:self action:@selector(closeMenu) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_closeBtn];

    _status = [[UILabel alloc] initWithFrame:CGRectMake(14, 44, frame.size.width - 28, 22)];
    _status.text = @"READY";
    _status.textColor = UIColor.whiteColor;
    _status.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightMedium];
    [self addSubview:_status];

    _startBtn = [self btn:@"ACTIVER" frame:CGRectMake(14, 74, 160, 40) color:[UIColor colorWithRed:0.06 green:0.58 blue:0.30 alpha:1] action:@selector(toggle)];

    UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(14, 124, 70, 16)];
    lab.text = @"Speed";
    lab.textColor = UIColor.lightGrayColor;
    lab.font = [UIFont systemFontOfSize:12];
    [self addSubview:lab];

    _speed = [[UISlider alloc] initWithFrame:CGRectMake(14, 140, frame.size.width - 28, 32)];
    _speed.minimumValue = 1.2;
    _speed.maximumValue = 3.2;
    _speed.value = 1.8;
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

- (void)closeMenu { self.hidden = YES; }

- (void)toggle {
    self.running = !self.running;
    if (self.running) {
        [_startBtn setTitle:@"DÉSACTIVER" forState:UIControlStateNormal];
        _startBtn.backgroundColor = [UIColor colorWithRed:0.80 green:0.10 blue:0.10 alpha:1];
        self.state = StateLobby;
        self.stateTimer = 0;
        self.timer = 0;
        [self tick];
    } else {
        [_startBtn setTitle:@"ACTIVER" forState:UIControlStateNormal];
        _startBtn.backgroundColor = [UIColor colorWithRed:0.06 green:0.58 blue:0.30 alpha:1];
        _status.text = @"STOPPED";
        [NSObject cancelPreviousPerformRequestsWithTarget:self];
    }
}

- (void)speedChanged:(UISlider *)s { self.interval = s.value; }

- (void)tick {
    if (!self.running) return;

    self.stateTimer += self.interval;
    self.timer += self.interval;

    switch (self.state) {
        case StateLobby:
            _status.text = @"LOBBY";
            if (self.stateTimer > 6.5) {
                TapAt(CGPointMake(200, 500), NO);
                self.state = StateBus;
                self.stateTimer = 0;
            }
            break;

        case StateBus:
            _status.text = @"BUS";
            if (self.stateTimer > 11.0) {
                TapAt(CGPointMake(200, 480), NO);
                lookAround(CGPointMake(0, -24));
                self.state = StateDropping;
                self.stateTimer = 0;
            }
            break;

        case StateDropping:
            _status.text = @"DROP";
            if (self.stateTimer > 4.5) {
                moveStick(CGPointMake(0, 1), 1.2);
                self.state = StateFarming;
                self.stateTimer = 0;
            }
            break;

        case StateFarming: {
            CGPoint myPos = readPlayerPos();
            NSArray *memChests = self.useMemory ? readChestWorldPositions() : @[];
            [self.worldChests removeAllObjects];
            [self.worldChests addObjectsFromArray:memChests];

            if (self.worldChests.count == 0) {
                UIImage *shot = captureScreen();
                NSArray *scr = scanChestsScreen(shot);
                [self.screenChests removeAllObjects];
                [self.screenChests addObjectsFromArray:scr];
                _status.text = [NSString stringWithFormat:@"FARM scr %lu", (unsigned long)self.screenChests.count];
            } else {
                _status.text = [NSString stringWithFormat:@"FARM mem %lu", (unsigned long)self.worldChests.count];
            }

            CGPoint targetWorld = CGPointZero;
            BOOL hasTarget = NO;

            if (self.worldChests.count > 0) {
                CGFloat best = 999999;
                for (NSValue *v in self.worldChests) {
                    CGPoint c = [v CGPointValue];
                    CGFloat d = hypotf(c.x - myPos.x, c.y - myPos.y);
                    if (d < best && d > 30) {
                        best = d;
                        targetWorld = c;
                        hasTarget = YES;
                    }
                }
            }

            if (hasTarget && myPos.x != 0) {
                CGPoint dir = CGPointMake(targetWorld.x - myPos.x, targetWorld.y - myPos.y);
                CGFloat len = hypotf(dir.x, dir.y);
                if (len > 80) {
                    dir.x /= len; dir.y /= len;
                    moveStick(dir, 1.3);
                    if (arc4random() % 5 == 0) TapAt(CGPointMake(200, 420), NO);
                    lookAround(CGPointMake(dir.x * 30, dir.y * 20));
                } else {
                    // close enough — try open (screen tap fallback)
                    CGPoint screenCenter = CGPointMake(UIScreen.mainScreen.bounds.size.width / 2,
                                                       UIScreen.mainScreen.bounds.size.height / 2);
                    TapAt(screenCenter, YES);
                }
            } else if (self.screenChests.count > 0) {
                CGPoint t = [self.screenChests[0] CGPointValue];
                CGPoint center = CGPointMake(UIScreen.mainScreen.bounds.size.width / 2,
                                             UIScreen.mainScreen.bounds.size.height / 2);
                CGPoint dir = CGPointMake(t.x - center.x, t.y - center.y);
                CGFloat len = hypotf(dir.x, dir.y);
                if (len > 50) {
                    dir.x /= len; dir.y /= len;
                    moveStick(dir, 1.0);
                } else {
                    TapAt(t, YES);
                }
            } else {
                // wander
                moveStick(CGPointMake((arc4random() % 200 - 100) / 100.0f, 0.6), 0.8);
            }
            break;
        }

        default:
            break;
    }

    if (self.timer >= 900.0) {
        TapAt(CGPointMake(210, 640), NO);
        self.timer = 0;
        self.state = StateLobby;
        self.stateTimer = 0;
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
static FarmMenu *gMenu = nil;

__attribute__((constructor))
static void init(void) {
    denyAttach();
    if (isDebugged()) return;

    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "Fortnite")) {
            gameBase = (uintptr_t)_dyld_get_image_header(i);
            break;
        }
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gWin = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        gWin.windowLevel = UIWindowLevelAlert + 2;
        gWin.backgroundColor = UIColor.clearColor;
        gWin.hidden = NO;
        gWin.userInteractionEnabled = YES;

        gMenu = [[FarmMenu alloc] initWithFrame:CGRectMake(12, 85, 220, 190)];
        [gWin addSubview:gMenu];
        [gMenu addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:gMenu action:@selector(handlePan:)]];

        UITapGestureRecognizer *triple = [[UITapGestureRecognizer alloc] initWithTarget:gMenu action:@selector(reopen)];
        triple.numberOfTapsRequired = 3;
        [gWin addGestureRecognizer:triple];
    });
}

@implementation FarmMenu (Reopen)
- (void)reopen { self.hidden = NO; }
@end
