// FarmChestAuto.m
// MAX TOTAL AUTONOME — mémoire + image + ESP + GUI complet + bus + intelligence + carte fortnite.gg
// Offsets: v43.00 CL-59596594
// Target: iOS arm64

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

#pragma mark - Screen + Color

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

static NSArray *scanChestsScreen(UIImage *img) {
    NSMutableArray *pts = [NSMutableArray array];
    CGFloat step = 26;
    CGSize sz = img.size;
    CGFloat scale = 1.0 / 0.45;
    for (CGFloat y = 50; y < sz.height - 50; y += step) {
        for (CGFloat x = 25; x < sz.width - 25; x += step) {
            UIColor *c = colorAt(img, CGPointMake(x, y));
            if (isChestColor(c)) {
                int hits = 0;
                int total = 0;
                for (int dy = -8; dy <= 8; dy += 4)
                    for (int dx = -8; dx <= 8; dx += 4) {
                        total++;
                        if (isChestColor(colorAt(img, CGPointMake(x+dx, y+dy)))) hits++;
                    }
                CGFloat confidence = (CGFloat)hits / (CGFloat)total;
                if (hits >= 4 && confidence >= 0.40)
                    [pts addObject:[NSValue valueWithCGPoint:CGPointMake(x * scale, y * scale)]];
            }
        }
    }
    return pts;
}

static NSArray *scanPlayersScreen(UIImage *img) {
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
@property (nonatomic, strong) UIButton *mapBtn;
@property (nonatomic, strong) UIButton *closeBtn;
@property (nonatomic, strong) UILabel  *status;
@property (nonatomic, strong) UISlider *speed;
@property (nonatomic, strong) NSMutableArray *worldChests;
@property (nonatomic, strong) NSMutableArray *screenChests;
@property (nonatomic, strong) NSMutableArray *screenPlayers;
@property (nonatomic, strong) NSArray *waypoints;
@property (nonatomic, assign) NSInteger currentWaypoint;
@property (nonatomic, strong) NSMutableArray<CAShapeLayer *> *espLayers;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) BOOL autoRestart;
@property (nonatomic, assign) BOOL autoAim;
@property (nonatomic, assign) BOOL useMemory;
@property (nonatomic, assign) GameState state;
@property (nonatomic, assign) CGPoint restartPoint;
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
    self.screenPlayers = [NSMutableArray array];
    self.espLayers = [NSMutableArray array];
    self.running = NO;
    self.autoRestart = YES;
    self.autoAim = YES;
    self.useMemory = YES;
    self.state = StateLobby;
    self.restartPoint = CGPointMake(210, 640);
    self.interval = 1.8;
    self.timer = 0;
    self.stateTimer = 0;
    self.currentWaypoint = 0;

    self.waypoints = @[
        [NSValue valueWithCGPoint:CGPointMake(180, 220)],
        [NSValue valueWithCGPoint:CGPointMake(250, 350)],
        [NSValue valueWithCGPoint:CGPointMake(120, 400)],
        [NSValue valueWithCGPoint:CGPointMake(300, 280)]
    ];

    UIImageView *logoView = [[UIImageView alloc] initWithFrame:CGRectMake(14, 10, 36, 36)];
    logoView.contentMode = UIViewContentModeScaleAspectFit;
    logoView.layer.cornerRadius = 8;
    logoView.clipsToBounds = YES;
    logoView.backgroundColor = [UIColor colorWithRed:0.0 green:0.7 blue:0.4 alpha:1];
    [self addSubview:logoView];

    UILabel *logoText = [[UILabel alloc] initWithFrame:CGRectMake(56, 14, 160, 28)];
    logoText.text = @"FARM AUTO";
    logoText.textColor = [UIColor colorWithRed:0.0 green:0.9 blue:0.5 alpha:1];
    logoText.font = [UIFont boldSystemFontOfSize:18];
    [self addSubview:logoText];

    _closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _closeBtn.frame = CGRectMake(frame.size.width - 38, 8, 30, 30);
    [_closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [_closeBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:19];
    [_closeBtn addTarget:self action:@selector(closeMenu) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_closeBtn];

    _status = [[UILabel alloc] initWithFrame:CGRectMake(14, 50, frame.size.width - 54, 22)];
    _status.text = @"READY";
    _status.textColor = UIColor.whiteColor;
    _status.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightMedium];
    [self addSubview:_status];

    _startBtn = [self btn:@"ACTIVER" frame:CGRectMake(14, 80, 132, 40) color:[UIColor colorWithRed:0.06 green:0.58 blue:0.30 alpha:1] action:@selector(toggle)];
    _autoBtn  = [self btn:@"RESTART 15m: ON" frame:CGRectMake(154, 80, 132, 40) color:[UIColor colorWithRed:0.10 green:0.40 blue:0.75 alpha:1] action:@selector(toggleAuto)];
    _aimBtn   = [self btn:@"AIM: ON" frame:CGRectMake(14, 128, 132, 36) color:[UIColor colorWithRed:0.68 green:0.16 blue:0.16 alpha:1] action:@selector(toggleAim)];
    _mapBtn   = [self btn:@"CARTE" frame:CGRectMake(154, 128, 132, 36) color:[UIColor colorWithRed:0.2 green:0.5 blue:0.8 alpha:1] action:@selector(showMap)];

    UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(14, 172, 70, 16)];
    lab.text = @"Speed";
    lab.textColor = UIColor.lightGrayColor;
    lab.font = [UIFont systemFontOfSize:12];
    [self addSubview:lab];

    _speed = [[UISlider alloc] initWithFrame:CGRectMake(14, 188, frame.size.width - 28, 32)];
    _speed.minimumValue = 1.2;
    _speed.maximumValue = 3.4;
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

- (void)showMap {
    NSString *mapB64 = @"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";
    NSData *data = [[NSData alloc] initWithBase64EncodedString:mapB64 options:0];
    UIImage *mapImg = [UIImage imageWithData:data];
    
    UIImageView *mapView = [[UIImageView alloc] initWithFrame:CGRectMake(10, 30, 280, 220)];
    mapView.image = mapImg;
    mapView.contentMode = UIViewContentModeScaleAspectFit;
    mapView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.92];
    mapView.layer.cornerRadius = 12;
    mapView.clipsToBounds = YES;
    [self.superview addSubview:mapView];
    
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:mapView action:@selector(removeFromSuperview)];
    [mapView addGestureRecognizer:tap];
    mapView.userInteractionEnabled = YES;
}

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
    NSArray *chests = scanChestsScreen(shot);
    NSArray *players = scanPlayersScreen(shot);
    [self.screenChests removeAllObjects];
    [self.screenChests addObjectsFromArray:chests];
    [self.screenPlayers removeAllObjects];
    [self.screenPlayers addObjectsFromArray:players];
    [self drawESP];
}

- (void)drawESP {
    for (CAShapeLayer *l in self.espLayers) [l removeFromSuperlayer];
    [self.espLayers removeAllObjects];

    UIWindow *w = UIApplication.sharedApplication.keyWindow;
    if (!w) return;

    for (NSValue *v in self.screenChests) {
        CGPoint p = [v CGPointValue];
        CAShapeLayer *box = [CAShapeLayer layer];
        box.path = [UIBezierPath bezierPathWithRect:CGRectMake(p.x - 18, p.y - 18, 36, 36)].CGPath;
        box.strokeColor = [UIColor colorWithRed:1.0 green:0.85 blue:0.2 alpha:0.95].CGColor;
        box.fillColor = [UIColor clearColor].CGColor;
        box.lineWidth = 2.2;
        [w.layer addSublayer:box];
        [self.espLayers addObject:box];
    }

    for (NSValue *v in self.screenPlayers) {
        CGPoint p = [v CGPointValue];
        CAShapeLayer *box = [CAShapeLayer layer];
        box.path = [UIBezierPath bezierPathWithRect:CGRectMake(p.x - 14, p.y - 30, 28, 60)].CGPath;
        box.strokeColor = [UIColor colorWithRed:1.0 green:0.25 blue:0.25 alpha:0.95].CGColor;
        box.fillColor = [UIColor clearColor].CGColor;
        box.lineWidth = 2.2;
        [w.layer addSublayer:box];
        [self.espLayers addObject:box];
    }
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
            _status.text = @"BUS — jumping soon";
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
            CGPoint myPos = readPlayerPos();
            NSArray *memChests = self.useMemory ? readChestWorldPositions() : @[];
            [self.worldChests removeAllObjects];
            [self.worldChests addObjectsFromArray:memChests];

            if (self.worldChests.count == 0 || ((int)self.stateTimer % 12) < 1) {
                [self fullScan];
            }

            _status.text = [NSString stringWithFormat:@"FARM m%lu s%lu p%lu",
                            (unsigned long)self.worldChests.count,
                            (unsigned long)self.screenChests.count,
                            (unsigned long)self.screenPlayers.count];

            if (self.autoAim && self.screenPlayers.count > 0) {
                CGPoint closest = [self.screenPlayers[0] CGPointValue];
                CGPoint center = CGPointMake(UIScreen.mainScreen.bounds.size.width / 2,
                                             UIScreen.mainScreen.bounds.size.height / 2);
                CGFloat best = 99999;
                for (NSValue *v in self.screenPlayers) {
                    CGPoint p = [v CGPointValue];
                    CGFloat d = hypot(p.x - center.x, p.y - center.y);
                    if (d < best) { best = d; closest = p; }
                }
                aimAt(closest);
            }

            BOOL moved = NO;
            if (self.worldChests.count > 0 && myPos.x != 0) {
                CGPoint target = CGPointZero;
                CGFloat best = 999999;
                for (NSValue *v in self.worldChests) {
                    CGPoint c = [v CGPointValue];
                    CGFloat d = hypotf(c.x - myPos.x, c.y - myPos.y);
                    if (d < best && d > 40) {
                        best = d;
                        target = c;
                    }
                }
                if (best < 999999) {
                    CGPoint dir = CGPointMake(target.x - myPos.x, target.y - myPos.y);
                    CGFloat len = hypotf(dir.x, dir.y);
                    if (len > 70) {
                        dir.x /= len; dir.y /= len;
                        moveStick(dir, 1.2);
                        if (arc4random() % 4 == 0) TapAt(CGPointMake(200, 420), NO);
                        lookAround(CGPointMake(dir.x * 28, dir.y * 18));
                    } else {
                        TapAt(CGPointMake(UIScreen.mainScreen.bounds.size.width / 2,
                                          UIScreen.mainScreen.bounds.size.height / 2), YES);
                    }
                    moved = YES;
                }
            }

            if (!moved && self.screenChests.count > 0) {
                NSInteger idx = 0;
                CGPoint target = [self.screenChests[idx] CGPointValue];
                CGPoint center = CGPointMake(UIScreen.mainScreen.bounds.size.width / 2,
                                             UIScreen.mainScreen.bounds.size.height / 2);
                CGPoint dir = CGPointMake(target.x - center.x, target.y - center.y);
                CGFloat len = hypot(dir.x, dir.y);
                
                if (len > 60) {
                    dir.x /= len; dir.y /= len;
                    moveStick(dir, 1.1);
                    if (arc4random() % 4 == 0) TapAt(CGPointMake(200, 420), NO);
                    lookAround(CGPointMake(dir.x * 30, dir.y * 20));
                } else {
                    TapAt(target, YES);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        if (![self stillChestAt:target]) {
                            if (idx < self.screenChests.count) [self.screenChests removeObjectAtIndex:idx];
                        }
                    });
                }
                moved = YES;
            }

            if (!moved) {
                CGPoint wp = [self.waypoints[self.currentWaypoint] CGPointValue];
                CGPoint center = CGPointMake(UIScreen.mainScreen.bounds.size.width / 2,
                                             UIScreen.mainScreen.bounds.size.height / 2);
                CGPoint dir = CGPointMake(wp.x - center.x, wp.y - center.y);
                CGFloat len = hypot(dir.x, dir.y);
                if (len > 50) {
                    dir.x /= len; dir.y /= len;
                    moveStick(dir, 1.3);
                    lookAround(CGPointMake(dir.x * 25, dir.y * 15));
                } else {
                    self.currentWaypoint = (self.currentWaypoint + 1) % self.waypoints.count;
                }
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
        [self.worldChests removeAllObjects];
        [self.screenChests removeAllObjects];
        [self.screenPlayers removeAllObjects];
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

        gMenu = [[FarmMenu alloc] initWithFrame:CGRectMake(12, 85, 300, 240)];
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
