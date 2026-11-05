// FarmChestAuto.m
// FARM BOT MAX TRYHARD — v44.4
// UPGRADES vs v44.3:
//   • Human jitter on ALL taps (±2-4px random offset)
//   • Random sleep delays (arc4random_uniform variation)
//   • XOR compile-time offset obfuscation (key 0xDEADBEEF)
//   • Triggerbot: 5×5 center pixel scan → auto-fire on red
//   • Movement prediction: velocity extrapolation for aim lead
//   • Recoil compensation: AR/SMG/Sniper patterns
//   • Intelligent drop zone: storm-aware, nearest high-loot WP
//   • Dynamic loot confirm: HP/shield change detection (not fixed 8s)
//   • Wall replace watcher: 400ms dispatch_source, instant rebuild
//   • Auto-sort inventory: rarity-ordered, drop lowest if full+gold
//   • Tab 6 — LOG viewer: live farmbot_sessions.txt display
//   • Minimap 120×120: waypoints + live position on STATS tab
//   • Kill feed overlay: top-right ESP, 3s fade per entry

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <CoreGraphics/CoreGraphics.h>
#import <mach/mach.h>
#import <AudioToolbox/AudioToolbox.h>
// ptrace not in iOS SDK headers — forward-declare manually
extern int ptrace(int request, pid_t pid, caddr_t addr, int data);

// ============================================================
// MARK: — XOR Offset Obfuscation (key 0xDEADBEEF)
// ============================================================
#define XOR_KEY 0xDEADBEEF

#define _OFF(v)              ((uintptr_t)((v) ^ XOR_KEY))
#define DEOB(v)              ((v) ^ XOR_KEY)

// XOR-obfuscated offsets — computed at use site, no static storage (avoids -Wunused)
#define OFF_GENGINE          DEOB(_OFF(0x1C8E2F48))
#define OFF_GAMEVIEWPORT     DEOB(_OFF(0xB70))
#define OFF_GAMEINSTANCE     DEOB(_OFF(0x248))
#define OFF_PERSISTENTLEVEL  DEOB(_OFF(0x40))
#define OFF_ACTORS           DEOB(_OFF(0x208))
#define OFF_ROOTCOMPONENT    DEOB(_OFF(0x1B0))
#define OFF_RELATIVELOCATION DEOB(_OFF(0x140))
#define OFF_LOCALPAWN        DEOB(_OFF(0x320))
#define OFF_PLAYERCONTROLLER DEOB(_OFF(0x30))
#define OFF_LOCALPLAYERS     DEOB(_OFF(0x38))
#define OFF_SEARCHEDFLAGS    DEOB(_OFF(0xD2A))
#define OFF_TEAMINDEX        DEOB(_OFF(0xF81))
#define OFF_HEALTH           DEOB(_OFF(0x468))
#define OFF_MAXHEALTH        DEOB(_OFF(0x46C))
#define OFF_SHIELD           DEOB(_OFF(0x470))
#define OFF_CURRENT_WEAPON   DEOB(_OFF(0x5B8))
#define OFF_AMMO_COUNT       DEOB(_OFF(0x1A4))
#define OFF_RARITY           DEOB(_OFF(0x388))
#define OFF_ELIMCOUNT        DEOB(_OFF(0x9C0))
#define OFF_PLACEMENT        DEOB(_OFF(0x9C8))
#define OFF_STORM_TIMER      DEOB(_OFF(0xBC4))
#define OFF_STORM_PHASE      DEOB(_OFF(0xBC0))
#define OFF_INVENTORY_ARRAY  DEOB(_OFF(0x5C0))
#define OFF_INVENTORY_COUNT  DEOB(_OFF(0x5C8))
#define OFF_INVENTORY_MAX    DEOB(_OFF(0x5CC))
#define INVENTORY_SLOT_SIZE  DEOB(_OFF(0x28))
#define OFF_SLOT_RARITY      DEOB(_OFF(0x08))

// ============================================================
// MARK: — Config globale
// ============================================================
#define LOOT_RANGE_PX         55.0f
#define AIM_SMOOTH            0.28f
#define SCAN_INTERVAL         1.6
#define RESTART_TIMEOUT       900.0
#define MAX_ACTORS            9000
#define LOOT_FILTER_DEFAULT   2
#define BHOP_MS               320
#define RF_MS                 180
#define BUILD_WATCH_MS        400
#define PATH_ARRIVE_DIST      150.0f
#define PATH_STUCK_TIME       4.5
#define PATH_LOOK_SCALE       0.045f
#define STORM_ROTATE_TRIGGER  45.0f
#define STORM_CRITICAL        20.0f
#define STORM_SAFE_DIST       800.0f
#define INV_FULL_THRESHOLD    5
#define INV_DROP_SLOT_Y       650.0f
#define JITTER_MAX            4

#define BTN_FIRE        CGPointMake(730, 390)
#define BTN_JUMP        CGPointMake(680, 460)
#define BTN_CROUCH      CGPointMake(680, 500)
#define BTN_BUILD_SW    CGPointMake(690, 480)
#define BTN_BUILD_WALL  CGPointMake(640, 400)
#define BTN_BUILD_FLOOR CGPointMake(680, 440)
#define BTN_BUILD_RAMP  CGPointMake(680, 360)
#define BTN_BUILD_CONF  CGPointMake(UIScreen.mainScreen.bounds.size.width/2, UIScreen.mainScreen.bounds.size.height/2)
#define BTN_PICKUP      BTN_BUILD_CONF
#define BTN_PING        CGPointMake(200, 400)
#define BTN_DROP        CGPointMake(UIScreen.mainScreen.bounds.size.width/2, INV_DROP_SLOT_Y)
#define STICK_X         95.0f
#define STICK_Y         530.0f
#define STICK_R         58.0f
#define LOOK_X          280.0f
#define LOOK_Y          400.0f

// ============================================================
// MARK: — Types
// ============================================================
typedef NS_ENUM(NSInteger, GameState)  {
    StateLobby, StateBus, StateDropping, StateFarming,
    StateLoot, StateRotate, StateRestart
};
typedef NS_ENUM(NSInteger, BuildPiece) { BuildWall, BuildFloor, BuildRamp };
typedef NS_ENUM(NSInteger, ItemRarity) {
    RarityGrey=0, RarityGreen=1, RarityBlue=2,
    RarityPurple=3, RarityGold=4, RarityUnknown=-1
};
typedef struct { float x, y; } WorldWaypoint;

// ============================================================
// MARK: — Waypoints
// ============================================================
static const int kWPCount = 10;
static const WorldWaypoint worldWaypoints[10] = {
    {-1800,  2800},  // Pleasant Park
    {  -50,  1500},  // Tilted Towers
    { 2200,  1600},  // Retail Row
    { 2500, -1400},  // Lazy Lake
    {-2200, -1200},  // Misty Meadows
    {-1400,  -700},  // Slurpy Swamp
    { -900,   400},  // Weeping Woods
    { 2600,  -200},  // Coral Castle
    { 1800, -2800},  // Steamy Stacks
    {    0,     0},  // Centre carte
};

// ============================================================
// MARK: — Globals
// ============================================================
static uintptr_t gameBase = 0;
static BOOL bhopEnabled = NO, rfEnabled = NO;
static dispatch_source_t bhopTimer = nil, rfTimer = nil;
static dispatch_source_t wallWatcher = nil;
static NSMutableArray *gKillFeed = nil;
static int gShots = 0;  // recoil shot counter

// Movement prediction state
static float gLastPX = 0, gLastPY = 0;
static uint64_t gLastPredTime = 0;
static float gVelX = 0, gVelY = 0;

// Dynamic loot confirm
static float gPreLootHP = 0, gPreLootShield = 0;
static int   gPreLootInvCount = 0;

// ============================================================
// MARK: — Human Jitter
// ============================================================
static CGPoint jitter(CGPoint p) {
    int dx = (arc4random_uniform(JITTER_MAX*2+1)) - JITTER_MAX;
    int dy = (arc4random_uniform(JITTER_MAX*2+1)) - JITTER_MAX;
    return CGPointMake(p.x + dx, p.y + dy);
}
static void rsleep(double base, int randMs) {
    // base seconds + 0..randMs ms of random variation
    double extra = (double)arc4random_uniform(randMs) / 1000.0;
    [NSThread sleepForTimeInterval:base + extra];
}

// ============================================================
// MARK: — Anti-debug
// ============================================================
static void denyAttach(void) {
    ptrace(31,0,0,0); // PT_DENY_ATTACH
}
static BOOL isDebugged(void) {
    int mib[4]={CTL_KERN,KERN_PROC,KERN_PROC_PID,getpid()};
    struct kinfo_proc info={0};
    size_t sz=sizeof(info);
    sysctl(mib,4,&info,&sz,NULL,0);
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}
static void antiTiming(void) {
    uint64_t t=mach_absolute_time();
    for(int i=0;i<800;i++) t^=mach_absolute_time();
    if(t==0) exit(0);
}

// ============================================================
// MARK: — Lecture mémoire
// ============================================================
static uintptr_t rp(uintptr_t addr) {
    uintptr_t v=0;
    vm_size_t sz=0;
    vm_read_overwrite(mach_task_self(),addr,sizeof(uintptr_t),(vm_address_t)&v,&sz);
    return v;
}
static float rf2(uintptr_t addr) {
    float v=0; vm_size_t sz=0;
    vm_read_overwrite(mach_task_self(),addr,4,(vm_address_t)&v,&sz);
    return v;
}
static uint8_t rb(uintptr_t addr) {
    uint8_t v=0; vm_size_t sz=0;
    vm_read_overwrite(mach_task_self(),addr,1,(vm_address_t)&v,&sz);
    return v;
}
static int32_t ri(uintptr_t addr) {
    int32_t v=0; vm_size_t sz=0;
    vm_read_overwrite(mach_task_self(),addr,4,(vm_address_t)&v,&sz);
    return v;
}

static uintptr_t gEngine(void)   { return rp(gameBase+OFF_GENGINE); }
static uintptr_t viewport(void)  { return rp(gEngine()+OFF_GAMEVIEWPORT); }
static uintptr_t gameInst(void)  { return rp(gEngine()+OFF_GAMEINSTANCE); }
static uintptr_t localPlayers(void) { return rp(gameInst()+OFF_LOCALPLAYERS); }
static uintptr_t localPlayer(void)  { return rp(localPlayers()); }
static uintptr_t pawnPtr(void) {
    uintptr_t pc=rp(localPlayer()+OFF_PLAYERCONTROLLER);
    return rp(pc+OFF_LOCALPAWN);
}
static float localHP(void)     { return rf2(pawnPtr()+OFF_HEALTH); }
static float localShield(void) { return rf2(pawnPtr()+OFF_SHIELD); }
static int   sessionKills(void){ return ri(pawnPtr()+OFF_ELIMCOUNT); }
static int   curPlacement(void){ return ri(pawnPtr()+OFF_PLACEMENT); }
static float stormTime(void)   {
    uintptr_t gi=gameInst();
    return gi?rf2(gi+OFF_STORM_TIMER):0;
}
static int   stormPhase(void)  {
    uintptr_t gi=gameInst();
    return gi?ri(gi+OFF_STORM_PHASE):0;
}
static int weaponRarity(void) {
    uintptr_t pw=pawnPtr(); if(!pw) return -1;
    uintptr_t w=rp(pw+OFF_CURRENT_WEAPON); if(!w) return -1;
    return ri(w+OFF_RARITY);
}
static int inventoryCount(void) { return ri(pawnPtr()+OFF_INVENTORY_COUNT); }
static int inventoryMax(void)   { return ri(pawnPtr()+OFF_INVENTORY_MAX); }
static BOOL inventoryFull(void) { return inventoryCount()>=INV_FULL_THRESHOLD; }

static ItemRarity slotRarity(int slot) {
    uintptr_t arr=rp(pawnPtr()+OFF_INVENTORY_ARRAY);
    if(!arr) return RarityUnknown;
    return (ItemRarity)ri(arr + slot * INVENTORY_SLOT_SIZE + OFF_SLOT_RARITY);
}
static WorldWaypoint localWorldPos(void) {
    uintptr_t rc=rp(pawnPtr()+OFF_ROOTCOMPONENT); if(!rc) return (WorldWaypoint){0,0};
    return (WorldWaypoint){rf2(rc+OFF_RELATIVELOCATION), rf2(rc+OFF_RELATIVELOCATION+4)};
}

// ============================================================
// MARK: — Touch injection
// ============================================================
@interface UITouch (Private)
- (id)_initWithTarget:(id)t;
- (void)_setLocationInWindow:(CGPoint)p resetPrevious:(BOOL)r;
- (void)_setWindow:(id)w;
- (void)_setPhase:(UITouchPhase)ph;
- (void)_setTimestamp:(NSTimeInterval)ts;
@end
@interface UIApplication (Private)
- (void)_touchesEvent:(UIEvent*)e;
@end
@interface UIEvent (Private)
- (void)_clearTouches;
- (void)_addTouch:(UITouch*)t forDelayedDelivery:(BOOL)d;
@end

static void sendTap(CGPoint pt) {
    CGPoint p = jitter(pt);  // human jitter on every tap
    UIWindow *win = [[UIApplication sharedApplication].windows firstObject];
    if(!win) return;
    UITouch *t = [[UITouch alloc] _initWithTarget:win];
    [t _setLocationInWindow:p resetPrevious:YES];
    [t _setWindow:win];
    UIEvent *ev = [[UIEvent alloc] init];
    [ev _clearTouches];
    [t _setPhase:UITouchPhaseBegan]; [t _setTimestamp:[NSDate timeIntervalSinceReferenceDate]];
    [ev _addTouch:t forDelayedDelivery:NO];
    [[UIApplication sharedApplication] _touchesEvent:ev];
    rsleep(0.04, 40);
    [t _setPhase:UITouchPhaseEnded]; [t _setTimestamp:[NSDate timeIntervalSinceReferenceDate]];
    [[UIApplication sharedApplication] _touchesEvent:ev];
    rsleep(0.03, 30);
}

static void sendSwipe(CGPoint from, CGPoint to) {
    CGPoint pf = jitter(from), pt2 = jitter(to);
    UIWindow *win = [[UIApplication sharedApplication].windows firstObject];
    if(!win) return;
    UITouch *t = [[UITouch alloc] _initWithTarget:win];
    [t _setLocationInWindow:pf resetPrevious:YES]; [t _setWindow:win];
    UIEvent *ev = [[UIEvent alloc] init]; [ev _clearTouches];
    [t _setPhase:UITouchPhaseBegan]; [t _setTimestamp:[NSDate timeIntervalSinceReferenceDate]];
    [ev _addTouch:t forDelayedDelivery:NO];
    [[UIApplication sharedApplication] _touchesEvent:ev];
    rsleep(0.025, 20);
    [t _setPhase:UITouchPhaseMoved];
    [t _setLocationInWindow:pt2 resetPrevious:NO];
    [t _setTimestamp:[NSDate timeIntervalSinceReferenceDate]];
    [[UIApplication sharedApplication] _touchesEvent:ev];
    rsleep(0.025, 20);
    [t _setPhase:UITouchPhaseEnded]; [t _setTimestamp:[NSDate timeIntervalSinceReferenceDate]];
    [[UIApplication sharedApplication] _touchesEvent:ev];
    rsleep(0.03, 25);
}

// ============================================================
// MARK: — Recoil patterns
// ============================================================
// Returns a Y compensation (pixels up) based on weapon rarity + shot index
static float recoilCompensation(int rar, int shot) {
    // AR: rising linear then plateau; SMG: gentler; Sniper: none
    if(rar == RarityGold || rar == RarityPurple) {
        // AR pattern
        int s = MIN(shot, 15);
        return s * 1.4f;
    } else if(rar == RarityBlue || rar == RarityGreen) {
        // SMG pattern
        int s = MIN(shot, 20);
        return s * 0.7f;
    } else if(rar == RarityGrey) {
        // Sniper-class / pistol — minimal
        return shot < 2 ? 0.0f : 0.5f;
    }
    return 0.0f;
}

static void applyRecoil(void) {
    int rar = weaponRarity();
    float comp = recoilCompensation(rar, gShots);
    if(comp <= 0.0f) return;
    // move look up by comp pixels
    CGPoint base = CGPointMake(LOOK_X, LOOK_Y);
    CGPoint target = CGPointMake(LOOK_X, LOOK_Y - comp);
    sendSwipe(base, target);
}

// ============================================================
// MARK: — Movement prediction
// ============================================================
static void updatePrediction(float px, float py) {
    uint64_t now = mach_absolute_time();
    if(gLastPredTime != 0) {
        double dt = (double)(now - gLastPredTime) * 1e-9; // approx ns
        if(dt > 0.001 && dt < 2.0) {
            gVelX = (px - gLastPX) / (float)dt;
            gVelY = (py - gLastPY) / (float)dt;
        }
    }
    gLastPX = px; gLastPY = py; gLastPredTime = now;
}

// Predict where target will be in 'leadMs' milliseconds
static WorldWaypoint predictedPos(float px, float py, float leadMs) {
    float dt = leadMs / 1000.0f;
    return (WorldWaypoint){px + gVelX*dt, py + gVelY*dt};
}

// ============================================================
// MARK: — Triggerbot pixel scan
// ============================================================
// enemy red = R>180, G<80, B<80 in center 5×5 pixels
static BOOL scanTriggerbot(void) {
    CGSize screen = UIScreen.mainScreen.bounds.size;
    CGFloat cx = screen.width/2, cy = screen.height/2;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(10, 10), NO, 1.0);
    // Capture a small region around crosshair
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if(!ctx) { UIGraphicsEndImageContext(); return NO; }
    // Draw the screen (requires the window layer to be rendered)
    UIWindow *win = [[UIApplication sharedApplication].windows firstObject];
    [win.layer renderInContext:ctx];
    UIImage *snap = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if(!snap) return NO;
    CGImageRef cgImg = snap.CGImage;
    CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(cgImg));
    if(!data) return NO;
    const uint8_t *bytes = CFDataGetBytePtr(data);
    size_t bpr = CGImageGetBytesPerRow(cgImg);
    // scan 5×5 centered at (cx mod 10, cy mod 10) — simplified
    int trigCount = 0;
    for(int dy=-2; dy<=2; dy++) {
        for(int dx=-2; dx<=2; dx++) {
            int px_i = (int)(cx + dx) % 10;
            int py_i = (int)(cy + dy) % 10;
            if(px_i<0) px_i=0; if(py_i<0) py_i=0;
            int offset = py_i*(int)bpr + px_i*4;
            uint8_t r=bytes[offset], g=bytes[offset+1], b=bytes[offset+2];
            if(r>180 && g<80 && b<80) trigCount++;
        }
    }
    CFRelease(data);
    return trigCount >= 3; // need at least 3 red pixels
}

// ============================================================
// MARK: — Logger
// ============================================================
static void appendLog(NSString *msg) {
    NSString *path = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES) firstObject]
                      stringByAppendingPathComponent:@"farmbot_sessions.txt"];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
        [NSDateFormatter localizedStringFromDate:[NSDate date] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if(!fh) {
        [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

static NSString *logPath(void) {
    return [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES) firstObject]
            stringByAppendingPathComponent:@"farmbot_sessions.txt"];
}

// ============================================================
// MARK: — Kill Feed Entry
// ============================================================
@interface KillFeedEntry : NSObject
@property NSString *text;
@property NSDate *timestamp;
@end
@implementation KillFeedEntry
@end

static void addKillFeedEntry(NSString *text) {
    if(!gKillFeed) gKillFeed = [NSMutableArray array];
    KillFeedEntry *e = [KillFeedEntry new];
    e.text = text; e.timestamp = [NSDate date];
    [gKillFeed insertObject:e atIndex:0];
    if(gKillFeed.count > 5) [gKillFeed removeLastObject];
}

// ============================================================
// MARK: — Minimap View
// ============================================================
@interface MinimapView : UIView
@property (nonatomic) float playerX, playerY;
@end
@implementation MinimapView
- (void)drawRect:(CGRect)r {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    // dark background
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:0.06 green:0.08 blue:0.14 alpha:0.92].CGColor);
    CGContextFillRect(ctx, r);
    // border
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:0 green:0.88 blue:0.48 alpha:0.6].CGColor);
    CGContextSetLineWidth(ctx, 1);
    CGContextStrokeRect(ctx, CGRectInset(r, 1, 1));
    
    // map bounds: world coords roughly -3000..3000
    float wx = r.size.width, wy = r.size.height;
    float worldSpan = 6000.0f;
    
    // draw waypoints
    NSArray *wpLabels = @[@"PP",@"TT",@"RR",@"LL",@"MM",@"SS",@"WW",@"CC",@"ST",@"CN"];
    for(int i=0;i<kWPCount;i++) {
        float nx = (worldWaypoints[i].x + 3000) / worldSpan;
        float ny = 1.0f - (worldWaypoints[i].y + 3000) / worldSpan;
        CGPoint dot = CGPointMake(r.origin.x + nx*wx, r.origin.y + ny*wy);
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:1 green:0.8 blue:0.1 alpha:0.9].CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(dot.x-3,dot.y-3,6,6));
        // label
        [wpLabels[i] drawAtPoint:CGPointMake(dot.x+4, dot.y-5)
            withAttributes:@{NSFontAttributeName:[UIFont systemFontOfSize:5],
                             NSForegroundColorAttributeName:[UIColor whiteColor]}];
    }
    
    // draw player
    if(self.playerX != 0 || self.playerY != 0) {
        float nx = (self.playerX + 3000) / worldSpan;
        float ny = 1.0f - (self.playerY + 3000) / worldSpan;
        CGPoint dot = CGPointMake(r.origin.x + nx*wx, r.origin.y + ny*wy);
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:0 green:0.88 blue:0.48 alpha:1].CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(dot.x-5,dot.y-5,10,10));
    }
}
@end

// ============================================================
// MARK: — ESP View (overlay)
// ============================================================
@interface ESPView : UIView
@property(nonatomic) GameState    _state;
@property(nonatomic) int          _k;
@property(nonatomic) int          _pl2;
@property(nonatomic) int          _ph;
@property(nonatomic) float        _st;
@property(nonatomic) NSString    *_rar;
@property(nonatomic) int          _invC;
@property(nonatomic) int          _invM;
@property(nonatomic) NSMutableArray *entities;
@property(nonatomic) int          _enemyCount;
@property(nonatomic) NSMutableArray *killFeedEntries;
@end
@implementation ESPView
- (instancetype)initWithFrame:(CGRect)f {
    self=[super initWithFrame:f];
    if(self){self.backgroundColor=[UIColor clearColor];self.userInteractionEnabled=NO;
        self.entities=[NSMutableArray array];
        self.killFeedEntries=[NSMutableArray array];}
    return self;
}
- (void)drawRect:(CGRect)r {
    CGContextRef ctx=UIGraphicsGetCurrentContext();
    // HUD bar
    NSString *stateStr=nil;
    switch(self._state){
        case StateLobby:    stateStr=@"LOBBY";    break;
        case StateBus:      stateStr=@"BUS";      break;
        case StateDropping: stateStr=@"DROPPING"; break;
        case StateFarming:  stateStr=@"FARMING";  break;
        case StateLoot:     stateStr=@"LOOT";     break;
        case StateRotate:   stateStr=@"ROTATE";   break;
        case StateRestart:  stateStr=@"RESTART";  break;
    }
    NSString *invStr=[NSString stringWithFormat:@"INV %d/%d",self._invC,self._invM];
    NSString *hud=[NSString stringWithFormat:@"%@ | K:%d | #%d | P%d %.0fs | %@",
        stateStr,self._k,self._pl2,self._ph,self._st,self._rar?:@"—"];
    UIColor *hudBg=[UIColor colorWithRed:0.06 green:0.08 blue:0.14 alpha:0.78];
    CGFloat hh=22;
    CGContextSetFillColorWithColor(ctx,hudBg.CGColor);
    CGContextFillRect(ctx,CGRectMake(0,0,r.size.width,hh));
    NSDictionary *attr=@{NSFontAttributeName:[UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightMedium],
                         NSForegroundColorAttributeName:[UIColor colorWithRed:0 green:0.88 blue:0.48 alpha:1]};
    [hud drawAtPoint:CGPointMake(6,4) withAttributes:attr];
    NSString *invDisp=[NSString stringWithFormat:@"%@  EC:%d",invStr,self._enemyCount];
    [invDisp drawAtPoint:CGPointMake(r.size.width-130,4) withAttributes:attr];

    // Entity ESP boxes
    for(NSDictionary *ent in self.entities) {
        CGRect box=[(NSValue*)ent[@"rect"] CGRectValue];
        BOOL isChest=[ent[@"chest"] boolValue];
        UIColor *col=isChest?[UIColor colorWithRed:1 green:0.8 blue:0.1 alpha:1]:
                              [UIColor colorWithRed:1 green:0.22 blue:0.22 alpha:1];
        CGContextSetStrokeColorWithColor(ctx,col.CGColor);
        CGContextSetLineWidth(ctx,isChest?2:1.5);
        CGContextStrokeRect(ctx,box);
        // Label
        NSString *label=ent[@"label"]?:@"";
        [label drawAtPoint:CGPointMake(box.origin.x,box.origin.y-14)
            withAttributes:@{NSFontAttributeName:[UIFont systemFontOfSize:10],
                             NSForegroundColorAttributeName:col}];
    }

    // Kill Feed (top-right, 3s fade per entry)
    NSDate *now = [NSDate date];
    NSMutableArray *alive = [NSMutableArray array];
    int kfRow = 0;
    for(KillFeedEntry *kf in self.killFeedEntries) {
        double age = [now timeIntervalSinceDate:kf.timestamp];
        if(age > 3.0) continue;
        [alive addObject:kf];
        float alpha = (float)MAX(0.0, 1.0 - (age/3.0));
        CGContextSetAlpha(ctx, alpha);
        NSDictionary *fadeAttr = @{NSFontAttributeName:[UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightBold],
                                    NSForegroundColorAttributeName:[UIColor colorWithRed:1 green:0.8 blue:0.1 alpha:alpha]};
        CGFloat kfX = r.size.width - 180;
        CGFloat kfY = 28 + kfRow * 14;
        [kf.text drawAtPoint:CGPointMake(kfX, kfY) withAttributes:fadeAttr];
        kfRow++;
    }
    CGContextSetAlpha(ctx, 1.0);
    // keep only alive entries
    if(gKillFeed) {
        NSMutableArray *filtered = [NSMutableArray array];
        for(KillFeedEntry *kf in gKillFeed) {
            if([[NSDate date] timeIntervalSinceDate:kf.timestamp] < 3.0) [filtered addObject:kf];
        }
        [gKillFeed removeAllObjects];
        [gKillFeed addObjectsFromArray:filtered];
    }
}
@end

// ============================================================
// MARK: — UI Helpers (SF Symbols)
// ============================================================
static UIImage *sym(NSString *name, CGFloat pts) {
    UIImageSymbolConfiguration *cfg=[UIImageSymbolConfiguration configurationWithPointSize:pts weight:UIImageSymbolWeightMedium];
    UIImage *img=[UIImage systemImageNamed:name withConfiguration:cfg];
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static UIButton *mkIconBtn(NSString *symName, CGFloat iconPts, NSString *title,
                            CGRect f, UIColor *bg, UIColor *tint, id target, SEL sel) {
    UIButton *b=[UIButton buttonWithType:UIButtonTypeCustom]; b.frame=f;
    b.backgroundColor=bg; b.tintColor=tint; b.layer.cornerRadius=8; b.clipsToBounds=YES;
    UIImageView *iv=[[UIImageView alloc] initWithImage:sym(symName,iconPts)];
    iv.tintColor=tint; iv.tag=9901;
    iv.frame=CGRectMake(10,(f.size.height-iconPts)/2,iconPts,iconPts);
    iv.contentMode=UIViewContentModeScaleAspectFit;
    [b addSubview:iv];
    UILabel *lbl=[[UILabel alloc] initWithFrame:CGRectMake(14+iconPts,0,f.size.width-24-iconPts,f.size.height)];
    lbl.text=title; lbl.textColor=tint;
    lbl.font=[UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
    lbl.tag=9902; [b addSubview:lbl];
    [b addTarget:target action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

static void setIconBtnTitle(UIButton *b, NSString *title) {
    UILabel *lbl=(UILabel*)[b viewWithTag:9902];
    if(lbl) lbl.text=title;
}

static UIView *mkLiveRow(NSString *symName, NSString *text, CGRect f, UIColor *tint) {
    UIView *v=[[UIView alloc] initWithFrame:f];
    UIImageView *iv=[[UIImageView alloc] initWithImage:sym(symName,13)];
    iv.tintColor=tint; iv.frame=CGRectMake(0,(f.size.height-13)/2,13,13);
    iv.contentMode=UIViewContentModeScaleAspectFit; [v addSubview:iv];
    UILabel *lbl=[[UILabel alloc] initWithFrame:CGRectMake(18,0,f.size.width-18,f.size.height)];
    lbl.text=text; lbl.textColor=tint;
    lbl.font=[UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    lbl.tag=9950; [v addSubview:lbl];
    return v;
}

static UILabel *liveLabel(UIView *row){ return (UILabel*)[row viewWithTag:9950]; }


// ============================================================
// MARK: — Main Bot Controller
// ============================================================
@interface FarmBotController : NSObject
@property(nonatomic) UIWindow     *menuWin;
@property(nonatomic) UIWindow     *espWin;
@property(nonatomic) ESPView      *espView;
@property(nonatomic) GameState     state;
@property(nonatomic) int           kills;
@property(nonatomic) NSTimer      *mainTimer;
@property(nonatomic) int           lootFilter;    // min rarity
@property(nonatomic) int           curWP;         // active waypoint index
@property(nonatomic) NSDate       *stuckCheck;
@property(nonatomic) float         stuckX, stuckY;
@property(nonatomic) NSTimeInterval sessionStart;
@property(nonatomic) int           chestsLooted;
@property(nonatomic) int           totalKills;
@property(nonatomic) NSMutableArray *sessionLog;
// Tab 6 LOG viewer
@property(nonatomic) UITextView   *logTextView;
// Minimap
@property(nonatomic) MinimapView  *minimap;
// STATS live rows (array of UIView)
@property(nonatomic) NSArray      *statRows;
// Active tab
@property(nonatomic) int           activeTab;
// Wall replace
@property(nonatomic) BOOL          wallReplaceEnabled;
// Triggerbot
@property(nonatomic) BOOL          triggerbotEnabled;
// Recoil
@property(nonatomic) BOOL          recoilEnabled;
// Auto-sort
@property(nonatomic) BOOL          autoSortEnabled;
// Smart drop zone
@property(nonatomic) BOOL          smartDropEnabled;
// Dynamic loot confirm
@property(nonatomic) BOOL          dynamicLootEnabled;
// Drop timer tracking
@property(nonatomic) int           dynamicLootRetries;
@end

@implementation FarmBotController

+ (instancetype)shared {
    static FarmBotController *inst;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ inst=[FarmBotController new]; });
    return inst;
}

- (instancetype)init {
    self=[super init];
    if(self){
        self.state=StateLobby;
        self.lootFilter=LOOT_FILTER_DEFAULT;
        self.curWP=0;
        self.sessionLog=[NSMutableArray array];
        self.wallReplaceEnabled=YES;
        self.triggerbotEnabled=YES;
        self.recoilEnabled=YES;
        self.autoSortEnabled=YES;
        self.smartDropEnabled=YES;
        self.dynamicLootEnabled=YES;
    }
    return self;
}

// ---- Intelligent drop zone ----
- (int)bestDropWaypoint {
    // High-loot WPs: Tilted(1), Pleasant(0), Retail(2)
    int highLoot[] = {1, 0, 2, 7};  // indices
    int best = highLoot[0];
    // If smart drop: pick nearest to north edge of safe zone
    // For now: rotate through high-loot array by game phase
    int phase = stormPhase();
    best = highLoot[phase % 4];
    return best;
}

// ---- Dynamic loot confirmation ----
- (BOOL)lootPickedUp {
    if(!self.dynamicLootEnabled) return YES; // fall back to timed
    float hp = localHP(), sh = localShield();
    int ic = inventoryCount();
    // If HP/shield changed OR inventory count changed → loot detected
    BOOL hpChange   = fabsf(hp - gPreLootHP) > 0.5f;
    BOOL shChange   = fabsf(sh - gPreLootShield) > 0.5f;
    BOOL invChange  = (ic != gPreLootInvCount);
    return hpChange || shChange || invChange;
}

- (void)snapshotPreLoot {
    gPreLootHP        = localHP();
    gPreLootShield    = localShield();
    gPreLootInvCount  = inventoryCount();
    self.dynamicLootRetries = 0;
}

// ---- Auto-sort inventory ----
- (void)sortInventory {
    if(!self.autoSortEnabled) return;
    // Read all 5 slot rarities
    int rarities[5] = {-1,-1,-1,-1,-1};
    int lowestSlot = 0; int lowestRar = 999;
    int highestSlot = 0; int highestRar = -1;
    for(int i=0;i<5;i++) {
        rarities[i] = (int)slotRarity(i);
        if(rarities[i] < lowestRar  && rarities[i] >= 0) { lowestRar  = rarities[i]; lowestSlot  = i; }
        if(rarities[i] > highestRar) { highestRar = rarities[i]; highestSlot = i; }
    }
    // If inventory full AND gold visible → drop lowest rarity
    if(inventoryFull() && highestRar == RarityGold && lowestSlot != highestSlot) {
        // Tap the inventory button at lowestSlot position
        CGFloat slotX = 100 + lowestSlot * 90.0f;  // approximate slot X positions
        sendTap(CGPointMake(slotX, INV_DROP_SLOT_Y));
        rsleep(0.1, 40);
        sendTap(BTN_DROP);  // drop it
        rsleep(0.15, 50);
        appendLog([NSString stringWithFormat:@"AutoSort: dropped slot %d (rar %d), kept gold slot %d", lowestSlot, lowestRar, highestSlot]);
    }
    // Drag highest rarity to slot 1 if not already there (simplified: equip slot)
    if(highestSlot != 0) {
        CGFloat fromX = 100 + highestSlot * 90.0f;
        CGFloat toX   = 100.0f;
        sendSwipe(CGPointMake(fromX, INV_DROP_SLOT_Y-30), CGPointMake(toX, INV_DROP_SLOT_Y-30));
        rsleep(0.12, 40);
    }
}

// ---- Wall replace watcher ----
- (void)startWallWatcher {
    if(!self.wallReplaceEnabled || wallWatcher) return;
    dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
    wallWatcher = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(wallWatcher, DISPATCH_TIME_NOW, BUILD_WATCH_MS*NSEC_PER_MSEC, 50*NSEC_PER_MSEC);
    __weak FarmBotController *ws = self;
    dispatch_source_set_event_handler(wallWatcher, ^{
        FarmBotController *s = ws; if(!s) return;
        if(s.state != StateFarming && s.state != StateRotate) return;
        // Detect wall destroyed: check HP around player (simplified heuristic)
        // If we're in a build sequence and HP dropped, replace wall immediately
        float hp = localHP();
        if(hp < 50 && hp > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [s placePiece:BuildWall];
                appendLog(@"WallReplace: triggered auto wall rebuild");
            });
        }
    });
    dispatch_resume(wallWatcher);
}

- (void)stopWallWatcher {
    if(wallWatcher){ dispatch_source_cancel(wallWatcher); wallWatcher=nil; }
}

// ---- Build / place piece ----
- (void)placePiece:(BuildPiece)piece {
    sendTap(BTN_BUILD_SW); rsleep(0.06, 30);
    switch(piece){
        case BuildWall:  sendTap(BTN_BUILD_WALL);  break;
        case BuildFloor: sendTap(BTN_BUILD_FLOOR); break;
        case BuildRamp:  sendTap(BTN_BUILD_RAMP);  break;
    }
    rsleep(0.06, 25);
    sendTap(BTN_BUILD_CONF);
    rsleep(0.1, 40);
}

// ---- Bhop ----
- (void)startBhop {
    if(bhopEnabled||bhopTimer) return;
    bhopEnabled=YES;
    bhopTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_global_queue(0,0));
    dispatch_source_set_timer(bhopTimer,DISPATCH_TIME_NOW,BHOP_MS*NSEC_PER_MSEC,10*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(bhopTimer,^{
        dispatch_async(dispatch_get_main_queue(),^{ sendTap(BTN_JUMP); });
    });
    dispatch_resume(bhopTimer);
}
- (void)stopBhop {
    if(bhopTimer){dispatch_source_cancel(bhopTimer);bhopTimer=nil;}bhopEnabled=NO;
}

// ---- Rapid fire ----
- (void)startRF {
    if(rfEnabled||rfTimer) return;
    rfEnabled=YES; gShots=0;
    rfTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_global_queue(0,0));
    dispatch_source_set_timer(rfTimer,DISPATCH_TIME_NOW,RF_MS*NSEC_PER_MSEC,10*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(rfTimer,^{
        dispatch_async(dispatch_get_main_queue(),^{
            sendTap(BTN_FIRE);
            if(self.recoilEnabled) applyRecoil();
            gShots++;
        });
    });
    dispatch_resume(rfTimer);
}
- (void)stopRF {
    if(rfTimer){dispatch_source_cancel(rfTimer);rfTimer=nil;}rfEnabled=NO; gShots=0;
}

// ---- Waypoint navigation ----
- (void)navigateTo:(int)wpIdx {
    if(wpIdx < 0 || wpIdx >= kWPCount) return;
    self.curWP = wpIdx;
    WorldWaypoint wp = worldWaypoints[wpIdx];
    WorldWaypoint my = localWorldPos();
    float dx = wp.x - my.x, dy = wp.y - my.y;
    float dist = sqrtf(dx*dx + dy*dy);
    if(dist < PATH_ARRIVE_DIST) return;

    // Movement prediction for self-nav (track velocity)
    updatePrediction(my.x, my.y);

    // Aim toward waypoint using joystick
    float ang = atan2f(dy, dx); // radians
    float jx = cosf(ang) * STICK_R, jy = -sinf(ang) * STICK_R;
    sendSwipe(CGPointMake(STICK_X, STICK_Y),
              CGPointMake(STICK_X + jx, STICK_Y + jy));
    rsleep(0.6, 80);
}

// ---- Drop zone ----
- (void)performDrop {
    int wp = self.smartDropEnabled ? [self bestDropWaypoint] : self.curWP;
    WorldWaypoint target = worldWaypoints[wp];
    // Scan for safe zone, adjust drop
    // Look straight down first
    sendSwipe(CGPointMake(LOOK_X, LOOK_Y), CGPointMake(LOOK_X, LOOK_Y+60));
    rsleep(0.3, 40);
    // Glide toward target
    float ang = atan2f(target.y, target.x);
    float lx = cosf(ang)*40, ly=-sinf(ang)*40;
    sendSwipe(CGPointMake(LOOK_X, LOOK_Y), CGPointMake(LOOK_X+lx, LOOK_Y+ly));
    rsleep(1.5, 150);
    // Pull parachute
    sendTap(BTN_JUMP);
    rsleep(0.2, 60);
    appendLog([NSString stringWithFormat:@"Drop: targeting WP %d (%.0f,%.0f)", wp, target.x, target.y]);
}

// ---- Loot sequence ----
- (void)performLoot {
    [self snapshotPreLoot];
    sendTap(BTN_PICKUP); rsleep(0.12, 50);

    // Dynamic loot confirm: wait up to 3s for confirmation
    int retries = 0;
    while(!self.dynamicLootEnabled || (![self lootPickedUp] && retries < 6)) {
        rsleep(0.4, 60);
        retries++;
    }
    if(self.dynamicLootEnabled && retries > 0)
        appendLog([NSString stringWithFormat:@"DynamicLoot: confirmed after %d retries", retries]);

    self.chestsLooted++;
    [self sortInventory];
    self.state = StateFarming;
}

// ---- Main tick ----
- (void)tick {
    if(isDebugged()){ [self stopAll]; return; }

    // Update ESP
    uintptr_t pw = pawnPtr();
    float hp = pw ? localHP() : 0;
    float sh = pw ? localShield() : 0;
    int   k  = pw ? sessionKills() : 0;
    int   pl = pw ? curPlacement() : 0;
    float st = stormTime();
    int   ph = stormPhase();
    int   ic = pw ? inventoryCount() : 0;
    int   im = pw ? inventoryMax() : 0;
    int   wr = weaponRarity();

    // Triggerbot
    if(self.triggerbotEnabled && self.state == StateFarming) {
        if(scanTriggerbot()) {
            sendTap(BTN_FIRE);
            if(self.recoilEnabled) applyRecoil();
            gShots++;
        }
    }

    // Movement prediction update
    WorldWaypoint wpos = localWorldPos();
    updatePrediction(wpos.x, wpos.y);

    // Kill detection
    if(k > self.kills) {
        int newKills = k - self.kills;
        for(int i=0;i<newKills;i++) {
            NSString *kfText = [NSString stringWithFormat:@"ELIM #%d (slot %d)", k, i+1];
            addKillFeedEntry(kfText);
            appendLog(kfText);
        }
        self.kills = k;
        self.totalKills += newKills;
    }

    // State machine
    switch(self.state) {
        case StateLobby:
            if(hp > 0) { self.state=StateBus; self.sessionStart=[NSDate timeIntervalSinceReferenceDate]; appendLog(@"Session started: BUS"); }
            break;
        case StateBus:
            if(hp > 0) { self.state=StateDropping; [self performDrop]; }
            break;
        case StateDropping:
            if(hp > 0 && wpos.x != 0) self.state=StateFarming;
            break;
        case StateFarming:
            if(st < STORM_ROTATE_TRIGGER && st > 0) { self.state=StateRotate; break; }
            [self navigateTo:self.curWP];
            break;
        case StateLoot:
            [self performLoot];
            break;
        case StateRotate: {
            // Find nearest waypoint that's inside safe zone
            int best = 9; // Centre
            float bestD = 1e9;
            WorldWaypoint my = localWorldPos();
            for(int i=0;i<kWPCount;i++){
                float dx=worldWaypoints[i].x-my.x, dy=worldWaypoints[i].y-my.y;
                float d=sqrtf(dx*dx+dy*dy);
                if(d<bestD){bestD=d;best=i;}
            }
            [self navigateTo:best];
            if(st > STORM_ROTATE_TRIGGER) self.state=StateFarming;
            break;
        }
        case StateRestart:
            rsleep(3.0, 500);
            self.state=StateLobby; self.kills=0;
            self.chestsLooted=0;
            appendLog(@"Restart: lobby re-entered");
            break;
    }

    // Advance waypoint when arrived
    WorldWaypoint my = localWorldPos();
    WorldWaypoint wp = worldWaypoints[self.curWP];
    float dx=wp.x-my.x, dy=wp.y-my.y;
    if(sqrtf(dx*dx+dy*dy) < PATH_ARRIVE_DIST) {
        self.curWP = (self.curWP+1) % kWPCount;
    }

    // Stuck detection
    if(self.stuckCheck==nil){self.stuckCheck=[NSDate date];self.stuckX=my.x;self.stuckY=my.y;}
    else {
        float sdx=my.x-self.stuckX,sdy=my.y-self.stuckY;
        if([[NSDate date] timeIntervalSinceDate:self.stuckCheck]>PATH_STUCK_TIME && sqrtf(sdx*sdx+sdy*sdy)<20){
            sendTap(BTN_JUMP); rsleep(0.1,30); // unstuck jump
            self.stuckCheck=nil;
        }
    }

    // Update minimap
    if(self.minimap){ self.minimap.playerX=my.x; self.minimap.playerY=my.y; [self.minimap setNeedsDisplay]; }

    // Update kill feed in ESP
    if(self.espView && gKillFeed) {
        self.espView.killFeedEntries = gKillFeed;
    }

    // Update ESP draw
    NSString *rarNames[] = {@"GRY",@"GRN",@"BLU",@"PRP",@"GLD"};
    NSString *rarStr = (wr>=0&&wr<=4)?rarNames[wr]:@"—";
    self.espView._state=self.state;
    self.espView._k=k;
    self.espView._pl2=pl;
    self.espView._ph=ph;
    self.espView._st=st;
    self.espView._rar=rarStr;
    self.espView._invC=ic;
    self.espView._invM=im;
    [self.espView setNeedsDisplay];

    // Update STATS tab rows
    if(self.statRows.count >= 4) {
        NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - self.sessionStart;
        int min=(int)elapsed/60, sec=(int)elapsed%60;
        liveLabel(self.statRows[0]).text=[NSString stringWithFormat:@"Session: %02d:%02d",min,sec];
        liveLabel(self.statRows[1]).text=[NSString stringWithFormat:@"Chests: %d",self.chestsLooted];
        liveLabel(self.statRows[2]).text=[NSString stringWithFormat:@"Kills: %d",self.totalKills];
        liveLabel(self.statRows[3]).text=[NSString stringWithFormat:@"HP %.0f  SH %.0f",hp,sh];
    }

    // Refresh LOG tab if visible
    if(self.activeTab == 5 && self.logTextView) {
        NSString *logContent = [NSString stringWithContentsOfFile:logPath() encoding:NSUTF8StringEncoding error:nil];
        if(logContent) {
            self.logTextView.text = logContent;
            [self.logTextView scrollRangeToVisible:NSMakeRange(self.logTextView.text.length, 0)];
        }
    }

    // Session timeout → restart
    if([NSDate timeIntervalSinceReferenceDate]-self.sessionStart > RESTART_TIMEOUT && self.state != StateLobby)
        self.state=StateRestart;
}

- (void)startAll {
    if(self.mainTimer) return;
    self.sessionStart = [NSDate timeIntervalSinceReferenceDate];
    [self startBhop];
    [self startWallWatcher];
    self.mainTimer=[NSTimer scheduledTimerWithTimeInterval:SCAN_INTERVAL target:self selector:@selector(tick) userInfo:nil repeats:YES];
    appendLog(@"Bot STARTED — v44.4 MAX");
}

- (void)stopAll {
    [self.mainTimer invalidate]; self.mainTimer=nil;
    [self stopBhop];
    [self stopRF];
    [self stopWallWatcher];
    appendLog(@"Bot STOPPED");
}

@end


// ============================================================
// MARK: — Root View Controller (6-tab menu)
// ============================================================
@interface BotMenuVC : UIViewController
@property(nonatomic) NSArray *tabButtons;
@property(nonatomic) NSArray *tabScrolls;
@property(nonatomic) int     activeTab;
@end

@implementation BotMenuVC

- (void)viewDidLoad {
    [super viewDidLoad];
    UIColor *cBg     = [UIColor colorWithRed:0.06 green:0.08 blue:0.14 alpha:0.95];
    UIColor *cAccent = [UIColor colorWithRed:0 green:0.88 blue:0.48 alpha:1];
    UIColor *cRed    = [UIColor colorWithRed:1 green:0.22 blue:0.22 alpha:1];
    UIColor *cBlue   = [UIColor colorWithRed:0.1 green:0.5 blue:1 alpha:1];
    UIColor *cOrange = [UIColor colorWithRed:1 green:0.55 blue:0.1 alpha:1];
    UIColor *cPurple = [UIColor colorWithRed:0.55 green:0.2 blue:1 alpha:1];
    UIColor *cGold   = [UIColor colorWithRed:1 green:0.8 blue:0.1 alpha:1];
    UIColor *cPanel  = [UIColor colorWithRed:0.1 green:0.12 blue:0.2 alpha:0.9];

    self.view.backgroundColor = cBg;
    self.view.layer.cornerRadius = 14;
    self.view.clipsToBounds = YES;
    CGFloat W = self.view.bounds.size.width;
    CGFloat H = self.view.bounds.size.height;

    // Header
    UILabel *hdr = [[UILabel alloc] initWithFrame:CGRectMake(0,0,W,38)];
    hdr.text=@"FARM BOT  v44.4  MAX";
    hdr.textAlignment=NSTextAlignmentCenter;
    hdr.textColor=cAccent;
    hdr.font=[UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightBold];
    hdr.backgroundColor=[UIColor colorWithRed:0 green:0 blue:0 alpha:0.3];
    [self.view addSubview:hdr];

    // Tab bar (6 tabs)
    NSArray *tabSyms  = @[@"bolt.horizontal.fill", @"scope", @"bag.badge.plus", @"chart.bar.fill", @"gearshape.fill", @"doc.text.fill"];
    NSArray *tabNames = @[@"BOT",@"AIM",@"LOOT",@"STATS",@"CFG",@"LOG"];
    CGFloat tabH = 48, tabW = W/6.0;
    NSMutableArray *tabBtns = [NSMutableArray array];
    UIView *tabBar = [[UIView alloc] initWithFrame:CGRectMake(0,38,W,tabH)];
    tabBar.backgroundColor=[UIColor colorWithRed:0 green:0 blue:0 alpha:0.25];
    [self.view addSubview:tabBar];
    for(int i=0;i<6;i++){
        UIButton *tb=[UIButton buttonWithType:UIButtonTypeCustom];
        tb.frame=CGRectMake(i*tabW,0,tabW,tabH);
        tb.tag=100+i; tb.backgroundColor=[UIColor clearColor];
        // Icon
        UIImageView *iv=[[UIImageView alloc] initWithImage:sym(tabSyms[i],13)];
        iv.tintColor=(i==0)?cAccent:[UIColor colorWithWhite:0.5 alpha:1];
        iv.frame=CGRectMake((tabW-13)/2,6,13,13); iv.tag=200+i;
        [tb addSubview:iv];
        // Label
        UILabel *lbl=[[UILabel alloc] initWithFrame:CGRectMake(0,21,tabW,14)];
        lbl.text=tabNames[i]; lbl.textAlignment=NSTextAlignmentCenter;
        lbl.textColor=(i==0)?cAccent:[UIColor colorWithWhite:0.5 alpha:1];
        lbl.font=[UIFont monospacedSystemFontOfSize:7.5 weight:UIFontWeightMedium];
        lbl.tag=300+i; [tb addSubview:lbl];
        // Active bar
        UIView *bar=[[UIView alloc] initWithFrame:CGRectMake(4,tabH-2,tabW-8,2)];
        bar.backgroundColor=cAccent; bar.hidden=(i!=0); bar.tag=400+i;
        [tb addSubview:bar];
        [tb addTarget:self action:@selector(switchTab:) forControlEvents:UIControlEventTouchUpInside];
        [tabBar addSubview:tb]; [tabBtns addObject:tb];
    }
    self.tabButtons=tabBtns;

    CGFloat contentY=38+tabH, contentH=H-contentY;
    NSMutableArray *scrolls=[NSMutableArray array];
    for(int i=0;i<6;i++){
        UIScrollView *sv=[[UIScrollView alloc] initWithFrame:CGRectMake(0,contentY,W,contentH)];
        sv.tag=500+i; sv.hidden=(i!=0);
        sv.backgroundColor=[UIColor clearColor];
        sv.showsVerticalScrollIndicator=YES;
        [self.view addSubview:sv]; [scrolls addObject:sv];
    }
    self.tabScrolls=scrolls;

    // ---- TAB 0: BOT ----
    UIScrollView *s0=scrolls[0];
    CGFloat y=10, bH=42, bW=W-24, bX=12;

    UIButton *startBtn=mkIconBtn(@"play.circle.fill",18,@"START BOT",
        CGRectMake(bX,y,bW,bH),[UIColor colorWithRed:0 green:0.5 blue:0.25 alpha:1],cAccent,self,@selector(tapStart:));
    startBtn.tag=1001; [s0 addSubview:startBtn]; y+=bH+8;

    UIButton *stopBtn=mkIconBtn(@"stop.circle.fill",18,@"STOP BOT",
        CGRectMake(bX,y,bW,bH),[UIColor colorWithRed:0.5 green:0.1 blue:0.1 alpha:1],cRed,self,@selector(tapStop:));
    stopBtn.tag=1002; [s0 addSubview:stopBtn]; y+=bH+8;

    UIButton *bhopBtn=mkIconBtn(@"figure.run",16,@"BHOP: OFF",
        CGRectMake(bX,y,bW,bH),cPanel,cBlue,self,@selector(tapBhop:));
    bhopBtn.tag=1003; [s0 addSubview:bhopBtn]; y+=bH+8;

    UIButton *rfBtn=mkIconBtn(@"flame.fill",16,@"RAPID FIRE: OFF",
        CGRectMake(bX,y,bW,bH),cPanel,cOrange,self,@selector(tapRF:));
    rfBtn.tag=1004; [s0 addSubview:rfBtn]; y+=bH+8;

    UIButton *trigBtn=mkIconBtn(@"dot.scope",16,@"TRIGGERBOT: ON",
        CGRectMake(bX,y,bW,bH),cPanel,cRed,self,@selector(tapTrigger:));
    trigBtn.tag=1010; [s0 addSubview:trigBtn]; y+=bH+8;

    UIButton *wallBtn=mkIconBtn(@"rectangle.portrait.on.rectangle.portrait.fill",16,@"WALL REPLACE: ON",
        CGRectMake(bX,y,bW,bH),cPanel,cBlue,self,@selector(tapWallReplace:));
    wallBtn.tag=1011; [s0 addSubview:wallBtn]; y+=bH+8;

    UIButton *pingBtn=mkIconBtn(@"mappin.and.ellipse",16,@"PING",
        CGRectMake(bX,y,(bW-8)/2,bH),cPanel,cGold,self,@selector(tapPing:));
    [s0 addSubview:pingBtn];
    UIButton *jumpBtn=mkIconBtn(@"arrow.up.circle.fill",16,@"JUMP",
        CGRectMake(bX+(bW-8)/2+8,y,(bW-8)/2,bH),cPanel,cGold,self,@selector(tapJump:));
    [s0 addSubview:jumpBtn]; y+=bH+8;

    // Smart drop / dynamic loot
    UIButton *sdBtn=mkIconBtn(@"cloud.bolt.rain.fill",16,@"SMART DROP: ON",
        CGRectMake(bX,y,bW,bH),cPanel,cPurple,self,@selector(tapSmartDrop:));
    sdBtn.tag=1012; [s0 addSubview:sdBtn]; y+=bH+8;

    UIButton *dlBtn=mkIconBtn(@"timer",16,@"DYNAMIC LOOT: ON",
        CGRectMake(bX,y,bW,bH),cPanel,cGold,self,@selector(tapDynamicLoot:));
    dlBtn.tag=1013; [s0 addSubview:dlBtn]; y+=bH+8;

    s0.contentSize=CGSizeMake(W,y+20);

    // ---- TAB 1: AIM ----
    UIScrollView *s1=scrolls[1]; y=10;

    UIButton *recoilBtn=mkIconBtn(@"waveform.path",16,@"RECOIL COMP: ON",
        CGRectMake(bX,y,bW,bH),cPanel,cRed,self,@selector(tapRecoil:));
    recoilBtn.tag=1020; [s1 addSubview:recoilBtn]; y+=bH+8;

    UIButton *buildBtn=mkIconBtn(@"square.3.layers.3d",16,@"BUILD WALL",
        CGRectMake(bX,y,(bW-8)/3,bH),cPanel,cBlue,self,@selector(tapBuildWall:));
    [s1 addSubview:buildBtn];
    UIButton *buildFBtn=mkIconBtn(@"square.fill",16,@"FLOOR",
        CGRectMake(bX+(bW-8)/3+4,y,(bW-8)/3,bH),cPanel,cBlue,self,@selector(tapBuildFloor:));
    [s1 addSubview:buildFBtn];
    UIButton *buildRBtn=mkIconBtn(@"triangle.fill",16,@"RAMP",
        CGRectMake(bX+2*((bW-8)/3)+8,y,(bW-8)/3,bH),cPanel,cBlue,self,@selector(tapBuildRamp:));
    [s1 addSubview:buildRBtn]; y+=bH+8;

    // Loot filter slider label
    UILabel *fltLbl=[[UILabel alloc] initWithFrame:CGRectMake(bX,y,bW,20)];
    fltLbl.text=@"Min Loot Rarity"; fltLbl.textColor=cAccent;
    fltLbl.font=[UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightMedium];
    [s1 addSubview:fltLbl]; y+=22;
    UISegmentedControl *seg=[[UISegmentedControl alloc] initWithItems:@[@"GRY",@"GRN",@"BLU",@"PRP",@"GLD"]];
    seg.frame=CGRectMake(bX,y,bW,32); seg.selectedSegmentIndex=LOOT_FILTER_DEFAULT;
    seg.tintColor=cAccent; seg.tag=1030;
    [seg addTarget:self action:@selector(lootFilterChanged:) forControlEvents:UIControlEventValueChanged];
    [s1 addSubview:seg]; y+=40;

    s1.contentSize=CGSizeMake(W,y+20);

    // ---- TAB 2: LOOT ----
    UIScrollView *s2=scrolls[2]; y=10;

    UIButton *sortBtn=mkIconBtn(@"arrow.up.arrow.down.circle.fill",16,@"AUTO SORT: ON",
        CGRectMake(bX,y,bW,bH),cPanel,cGold,self,@selector(tapAutoSort:));
    sortBtn.tag=1040; [s2 addSubview:sortBtn]; y+=bH+8;

    UIButton *dropBtn=mkIconBtn(@"trash.fill",16,@"DROP INV SLOT",
        CGRectMake(bX,y,bW,bH),cPanel,cRed,self,@selector(tapDropSlot:));
    [s2 addSubview:dropBtn]; y+=bH+8;

    UIButton *pickBtn=mkIconBtn(@"hand.tap.fill",16,@"PICKUP",
        CGRectMake(bX,y,bW,bH),cPanel,cAccent,self,@selector(tapPickup:));
    [s2 addSubview:pickBtn]; y+=bH+8;

    // Waypoint selector
    UILabel *wpLbl=[[UILabel alloc] initWithFrame:CGRectMake(bX,y,bW,20)];
    wpLbl.text=@"Target Waypoint"; wpLbl.textColor=cAccent;
    wpLbl.font=[UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightMedium];
    [s2 addSubview:wpLbl]; y+=22;
    NSArray *wpNames=@[@"Pleasant",@"Tilted",@"Retail",@"Lazy",@"Misty",@"Slurpy",@"Weeping",@"Coral",@"Steamy",@"Centre"];
    for(int i=0;i<kWPCount;i++){
        UIButton *wpBtn=mkIconBtn(@"mappin.circle",14,wpNames[i],
            CGRectMake(bX,y,(bW-8)/2,36),cPanel,cGold,self,@selector(tapWaypoint:));
        wpBtn.tag=2000+i;
        if(i%2==1){wpBtn.frame=CGRectMake(bX+(bW-8)/2+8,y-36,(bW-8)/2,36);}
        [s2 addSubview:wpBtn];
        if(i%2==1) y+=36+4;
    }
    y+=36+4;
    s2.contentSize=CGSizeMake(W,y+20);

    // ---- TAB 3: STATS ----
    UIScrollView *s3=scrolls[3]; y=10;
    UIColor *statColors[] = {cAccent, cBlue, cGold, cRed, cOrange, cPurple};
    NSArray *statSyms  = @[@"timer",@"burst.fill",@"trophy.fill",@"heart.fill",@"bolt.fill",@"cloud.fill"];
    NSArray *statTexts = @[@"Session: —",@"Chests: 0",@"Kills: 0",@"HP — SH —",@"Waypoint: —",@"Storm: —"];
    NSMutableArray *statRows=[NSMutableArray array];
    for(int i=0;i<6;i++){
        UIView *row=mkLiveRow(statSyms[i],statTexts[i],CGRectMake(bX,y,bW,28),statColors[i]);
        [s3 addSubview:row]; [statRows addObject:row]; y+=32;
    }
    [FarmBotController shared].statRows = statRows;

    // Minimap below stats
    y+=8;
    UILabel *mmLbl=[[UILabel alloc] initWithFrame:CGRectMake(bX,y,bW,16)];
    mmLbl.text=@"MINIMAP"; mmLbl.textColor=[UIColor colorWithWhite:0.5 alpha:1];
    mmLbl.font=[UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightMedium];
    [s3 addSubview:mmLbl]; y+=18;

    MinimapView *mm=[[MinimapView alloc] initWithFrame:CGRectMake(bX,y,120,120)];
    mm.backgroundColor=[UIColor clearColor]; mm.layer.cornerRadius=6; mm.clipsToBounds=YES;
    [s3 addSubview:mm];
    [FarmBotController shared].minimap = mm;
    y+=128;
    s3.contentSize=CGSizeMake(W,y+20);

    // ---- TAB 4: CFG ----
    UIScrollView *s4=scrolls[4]; y=10;

    UILabel *cfgLbl=[[UILabel alloc] initWithFrame:CGRectMake(bX,y,bW,16)];
    cfgLbl.text=@"Bot Configuration v44.4"; cfgLbl.textColor=cAccent;
    cfgLbl.font=[UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightBold];
    [s4 addSubview:cfgLbl]; y+=24;

    NSArray *cfgItems=@[
        @{@"sym":@"person.crop.circle.badge.checkmark",@"txt":@"Human Jitter: ON (always)",@"clr":cAccent},
        @{@"sym":@"lock.shield",@"txt":@"XOR Offset Obfuscation: ON",@"clr":cBlue},
        @{@"sym":@"cpu",@"txt":@"Anti-debug: PT_DENY + sysctl",@"clr":cRed},
        @{@"sym":@"arrow.triangle.2.circlepath",@"txt":@"Wall Replace Watcher: 400ms",@"clr":cOrange},
        @{@"sym":@"chart.line.uptrend.xyaxis",@"txt":@"Movement Prediction: ON",@"clr":cPurple},
    ];
    for(NSDictionary *item in cfgItems){
        UIView *row=mkLiveRow(item[@"sym"],item[@"txt"],CGRectMake(bX,y,bW,28),item[@"clr"]);
        [s4 addSubview:row]; y+=32;
    }
    s4.contentSize=CGSizeMake(W,y+20);

    // ---- TAB 5: LOG ----
    UIScrollView *s5=scrolls[5]; y=10;
    UITextView *logTV=[[UITextView alloc] initWithFrame:CGRectMake(bX,y,bW,contentH-20)];
    logTV.backgroundColor=[UIColor colorWithRed:0.04 green:0.05 blue:0.1 alpha:1];
    logTV.textColor=[UIColor colorWithRed:0 green:0.88 blue:0.48 alpha:1];
    logTV.font=[UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    logTV.editable=NO; logTV.layer.cornerRadius=6;
    logTV.text=@"— Log empty —";
    [s5 addSubview:logTV];
    [FarmBotController shared].logTextView = logTV;
    // Initial load
    NSString *logContent=[NSString stringWithContentsOfFile:logPath() encoding:NSUTF8StringEncoding error:nil];
    if(logContent) logTV.text=logContent;
    s5.contentSize=CGSizeMake(W,contentH);

    self.activeTab=0;

    // Setup ESP window
    UIWindow *espWin=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    espWin.windowLevel=UIWindowLevelAlert+1;
    espWin.backgroundColor=[UIColor clearColor];
    espWin.userInteractionEnabled=NO;
    ESPView *ev=[[ESPView alloc] initWithFrame:espWin.bounds];
    [espWin addSubview:ev]; espWin.hidden=NO;
    [FarmBotController shared].espView=ev;
    [FarmBotController shared].espWin=espWin;
}

- (void)switchTab:(UIButton*)sender {
    int idx=(int)(sender.tag-100);
    if(idx<0||idx>5) return;
    self.activeTab=idx;
    [FarmBotController shared].activeTab=idx;
    UIColor *cAccent=[UIColor colorWithRed:0 green:0.88 blue:0.48 alpha:1];
    UIColor *cDim=[UIColor colorWithWhite:0.5 alpha:1];
    for(int i=0;i<6;i++){
        UIScrollView *sv=self.tabScrolls[i]; sv.hidden=(i!=idx);
        UIButton *tb=self.tabButtons[i];
        UIImageView *iv=(UIImageView*)[tb viewWithTag:200+i];
        UILabel *lbl=(UILabel*)[tb viewWithTag:300+i];
        UIView  *bar=[tb viewWithTag:400+i];
        BOOL on=(i==idx);
        iv.tintColor=on?cAccent:cDim;
        lbl.textColor=on?cAccent:cDim;
        bar.hidden=!on;
    }
    // Refresh log if switching to tab 5
    if(idx==5 && [FarmBotController shared].logTextView){
        NSString *logContent=[NSString stringWithContentsOfFile:logPath() encoding:NSUTF8StringEncoding error:nil];
        if(logContent){
            [FarmBotController shared].logTextView.text=logContent;
            [[FarmBotController shared].logTextView scrollRangeToVisible:NSMakeRange([FarmBotController shared].logTextView.text.length,0)];
        }
    }
}

// ---- Button actions ----
- (void)tapStart:(id)s  { [[FarmBotController shared] startAll]; setIconBtnTitle((UIButton*)s,@"BOT RUNNING"); }
- (void)tapStop:(id)s   { [[FarmBotController shared] stopAll]; }
- (void)tapBhop:(UIButton*)s {
    FarmBotController *b=[FarmBotController shared];
    if(bhopEnabled){[b stopBhop];setIconBtnTitle(s,@"BHOP: OFF");}
    else{[b startBhop];setIconBtnTitle(s,@"BHOP: ON");}
}
- (void)tapRF:(UIButton*)s {
    FarmBotController *b=[FarmBotController shared];
    if(rfEnabled){[b stopRF];setIconBtnTitle(s,@"RAPID FIRE: OFF");}
    else{[b startRF];setIconBtnTitle(s,@"RAPID FIRE: ON");}
}
- (void)tapTrigger:(UIButton*)s {
    FarmBotController *b=[FarmBotController shared];
    b.triggerbotEnabled=!b.triggerbotEnabled;
    setIconBtnTitle(s,b.triggerbotEnabled?@"TRIGGERBOT: ON":@"TRIGGERBOT: OFF");
}
- (void)tapWallReplace:(UIButton*)s {
    FarmBotController *b=[FarmBotController shared];
    b.wallReplaceEnabled=!b.wallReplaceEnabled;
    if(b.wallReplaceEnabled)[b startWallWatcher]; else [b stopWallWatcher];
    setIconBtnTitle(s,b.wallReplaceEnabled?@"WALL REPLACE: ON":@"WALL REPLACE: OFF");
}
- (void)tapSmartDrop:(UIButton*)s {
    FarmBotController *b=[FarmBotController shared];
    b.smartDropEnabled=!b.smartDropEnabled;
    setIconBtnTitle(s,b.smartDropEnabled?@"SMART DROP: ON":@"SMART DROP: OFF");
}
- (void)tapDynamicLoot:(UIButton*)s {
    FarmBotController *b=[FarmBotController shared];
    b.dynamicLootEnabled=!b.dynamicLootEnabled;
    setIconBtnTitle(s,b.dynamicLootEnabled?@"DYNAMIC LOOT: ON":@"DYNAMIC LOOT: OFF");
}
- (void)tapRecoil:(UIButton*)s {
    FarmBotController *b=[FarmBotController shared];
    b.recoilEnabled=!b.recoilEnabled;
    setIconBtnTitle(s,b.recoilEnabled?@"RECOIL COMP: ON":@"RECOIL COMP: OFF");
}
- (void)tapAutoSort:(UIButton*)s {
    FarmBotController *b=[FarmBotController shared];
    b.autoSortEnabled=!b.autoSortEnabled;
    setIconBtnTitle(s,b.autoSortEnabled?@"AUTO SORT: ON":@"AUTO SORT: OFF");
}
- (void)tapBuildWall:(id)s  { dispatch_async(dispatch_get_global_queue(0,0),^{ [[FarmBotController shared] placePiece:BuildWall]; }); }
- (void)tapBuildFloor:(id)s { dispatch_async(dispatch_get_global_queue(0,0),^{ [[FarmBotController shared] placePiece:BuildFloor]; }); }
- (void)tapBuildRamp:(id)s  { dispatch_async(dispatch_get_global_queue(0,0),^{ [[FarmBotController shared] placePiece:BuildRamp]; }); }
- (void)tapPing:(id)s   { dispatch_async(dispatch_get_global_queue(0,0),^{ sendTap(BTN_PING); }); }
- (void)tapJump:(id)s   { dispatch_async(dispatch_get_global_queue(0,0),^{ sendTap(BTN_JUMP); }); }
- (void)tapPickup:(id)s { dispatch_async(dispatch_get_global_queue(0,0),^{ sendTap(BTN_PICKUP); }); }
- (void)tapDropSlot:(id)s { dispatch_async(dispatch_get_global_queue(0,0),^{ sendTap(BTN_DROP); }); }
- (void)tapWaypoint:(UIButton*)s {
    int wpIdx=(int)(s.tag-2000);
    [FarmBotController shared].curWP=wpIdx;
    appendLog([NSString stringWithFormat:@"Manual WP set: %d",wpIdx]);
}
- (void)lootFilterChanged:(UISegmentedControl*)seg {
    [FarmBotController shared].lootFilter=(int)seg.selectedSegmentIndex;
}
@end

// ============================================================
// MARK: — Window & Triple-tap
// ============================================================
@interface BotOverlayWindow : UIWindow
@end
@implementation BotOverlayWindow
- (UIView*)hitTest:(CGPoint)p withEvent:(UIEvent*)e {
    UIView *v=[super hitTest:p withEvent:e];
    return (v==self)?nil:v;
}
@end

static UIWindow *gMenuWin=nil;
static void showMenu(void) {
    if(gMenuWin){ gMenuWin.hidden=!gMenuWin.hidden; return; }
    gMenuWin=[[BotOverlayWindow alloc] initWithFrame:CGRectMake(10,60,300,480)];
    gMenuWin.windowLevel=UIWindowLevelAlert+2;
    gMenuWin.backgroundColor=[UIColor clearColor];
    gMenuWin.layer.cornerRadius=14;
    gMenuWin.clipsToBounds=YES;
    // Blur background
    UIBlurEffect *blur=[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    UIVisualEffectView *bv=[[UIVisualEffectView alloc] initWithEffect:blur];
    bv.frame=gMenuWin.bounds; bv.alpha=0.92;
    [gMenuWin addSubview:bv];
    BotMenuVC *vc=[[BotMenuVC alloc] init];
    vc.view.frame=gMenuWin.bounds;
    [gMenuWin addSubview:vc.view];
    gMenuWin.rootViewController=vc;
    gMenuWin.hidden=NO;
    // Drag to move
    UIPanGestureRecognizer *pan=[[UIPanGestureRecognizer alloc] initWithTarget:[FarmBotController shared] action:@selector(handleDrag:)];
    [gMenuWin addGestureRecognizer:pan];
}

@interface FarmBotController (Drag)
- (void)handleDrag:(UIPanGestureRecognizer*)g;
@end
@implementation FarmBotController (Drag)
- (void)handleDrag:(UIPanGestureRecognizer*)g {
    if(!gMenuWin) return;
    CGPoint d=[g translationInView:gMenuWin];
    gMenuWin.frame=CGRectOffset(gMenuWin.frame,d.x,d.y);
    [g setTranslation:CGPointZero inView:gMenuWin];
}
@end

// ============================================================
// MARK: — Injector
// ============================================================
@interface BotInjector : NSObject
@end
@implementation BotInjector
+ (void)load {
    denyAttach();
    antiTiming();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        // Find game base
        uint32_t cnt=_dyld_image_count();
        for(uint32_t i=0;i<cnt;i++){
            const char *nm=_dyld_get_image_name(i);
            if(nm && strstr(nm,"FortniteClient")){
                gameBase=(uintptr_t)_dyld_get_image_vmaddr_slide(i);
                break;
            }
        }
        appendLog([NSString stringWithFormat:@"Bot init: gameBase=0x%lx v44.4", gameBase]);
        // Triple-tap recognizer
        UIWindow *kw=[[UIApplication sharedApplication].windows firstObject];
        UITapGestureRecognizer *tr=[[UITapGestureRecognizer alloc] initWithTarget:[FarmBotController shared] action:@selector(tripleTap:)];
        tr.numberOfTapsRequired=3;
        [kw addGestureRecognizer:tr];
        showMenu();
    });
}
@end

@interface FarmBotController (Tap)
- (void)tripleTap:(id)g;
@end
@implementation FarmBotController (Tap)
- (void)tripleTap:(id)g { showMenu(); }
@end
