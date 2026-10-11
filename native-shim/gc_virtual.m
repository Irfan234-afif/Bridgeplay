// gc_virtual.m: virtual GCControllers for pads the GameController framework does not expose.
//
// Native macOS games that read controllers only through GameController.framework never see
// generic HID / DirectInput pads (Flydigi, Nacon, BETOP, GameSir Bluetooth, ...). For every
// such pad (np_profile_create() != NULL) this file creates a snapshot controller with
// +[GCController controllerWithExtendedGamepad], feeds it decoded HID reports, and makes the
// game find it: +controllers / +current are swizzled and the connect / disconnect
// notifications are posted with the virtual controller as object.
//
// Built with -fobjc-arc into the same image as gamepad_shim.c, so the IOHID calls made here
// are not caught by that file's interposers. Only Foundation + IOKit are linked: the shim
// must not load GameController.framework into games that do not use it, so every GC class
// is reached through NSClassFromString and the work starts once the framework is loaded.
//
// Facts checked against the macOS 27 SDK / runtime (2026-10):
// - setValue: / setValueForXAxis:yAxis: write snapshot controllers and fire the element-level
//   handlers (valueChangedHandler, pressedChangedHandler) of the element written.
// - The profile-level GCExtendedGamepad.valueChangedHandler and (macOS 13+)
//   GCPhysicalInputProfile.valueDidChangeHandler do NOT fire for snapshot writes, so they
//   are invoked here per changed element (after a startup self-test confirms they don't).
// - vendorName is read-only API but KVC-writable (ivar _vendorName).
// - GCController.input (GCControllerLiveInput, macOS 14+) stays empty on snapshot
//   controllers; games that only use that API do not see input from virtual controllers.
// - +supportsHIDDevice: answers YES for pads the framework then never publishes (GameSir
//   G7 Pro over Bluetooth), so it is not used to decide duplicates; a real controller with
//   the same name is.

#if !__has_feature(objc_arc)
#error gc_virtual.m must be compiled with -fobjc-arc
#endif

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <IOKit/hid/IOHIDLib.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <dlfcn.h>
#import <math.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

#include "np_pad.h"

// String values of the GameController notification constants; the shim does not link the
// framework, so the extern NSString symbols are not available.
static NSString *const kConnect = @"GCControllerDidConnectNotification";
static NSString *const kDisconnect = @"GCControllerDidDisconnectNotification";
static NSString *const kBecameCurrent = @"GCControllerDidBecomeCurrentNotification";

// A real GCController with the pad's name connecting within this window of the HID device
// appearing means the system serves the pad itself.
static const double kGraceSeconds = 1.0;

static int log_on = -1;

static void gc_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void gc_log(const char *fmt, ...) {
    if (log_on < 0) {
        const char *v = getenv("NP_PAD_LOG");
        log_on = v && *v && strcmp(v, "0") != 0;
    }
    if (!log_on) return;
    va_list ap;
    va_start(ap, fmt);
    fputs("[np_pad gc] ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

// ---------------------------------------------------------------------------------------
// Per-pad state. Everything below runs on the main thread except the swizzled class
// methods, which read `published` under `published_lock`.

@interface NPGCPad : NSObject {
@public
    IOHIDDeviceRef device;
    np_profile *profile;
    uint8_t *buffer;
    CFIndex buffer_len;
    np_pad_state last;
    BOOL have_last;
    BOOL removed;
    BOOL shadowed;            // a real GCController serves this pad
    __weak id shadow;         // that real controller
}
@property (nonatomic, copy) NSString *name;       // HID product string
@property (nonatomic, copy) NSString *label;      // np_profile_name(), given to the game
@property (nonatomic, strong) GCController *controller;  // non-nil while published
@end

@implementation NPGCPad
@end

static Class gc_class;
static NSMutableArray<NPGCPad *> *pads;
static NSArray<GCController *> *published;  // immutable, swapped under the lock
static os_unfair_lock published_lock = OS_UNFAIR_LOCK_INIT;
static __weak GCController *last_active;
static IOHIDManagerRef manager;
static BOOL manual_profile_handlers = YES;

static NSArray *(*orig_controllers)(id, SEL);
static GCController *(*orig_current)(id, SEL);

static NSArray<GCController *> *published_snapshot(void) {
    os_unfair_lock_lock(&published_lock);
    NSArray *list = published;
    os_unfair_lock_unlock(&published_lock);
    return list ?: @[];
}

static void republish_list(void) {
    NSMutableArray *list = [NSMutableArray array];
    for (NPGCPad *pad in pads)
        if (pad.controller) [list addObject:pad.controller];
    os_unfair_lock_lock(&published_lock);
    published = [list copy];
    os_unfair_lock_unlock(&published_lock);
}

static BOOL is_virtual(id controller) {
    for (GCController *c in published_snapshot())
        if (c == controller) return YES;
    return NO;
}

// ---------------------------------------------------------------------------------------
// Swizzles

static NSArray *np_controllers(id self, SEL _cmd) {
    NSArray *real = orig_controllers ? orig_controllers(self, _cmd) : @[];
    NSArray *virt = published_snapshot();
    if (virt.count == 0) return real;
    return [(real ?: @[]) arrayByAddingObjectsFromArray:virt];
}

static GCController *np_current(id self, SEL _cmd) {
    GCController *real = orig_current ? orig_current(self, _cmd) : nil;
    if (real) return real;
    GCController *active = last_active;
    if (active && is_virtual(active)) return active;
    return published_snapshot().firstObject;
}

static void swizzle_class_method(SEL sel, IMP replacement, IMP *original) {
    Method m = class_getClassMethod(gc_class, sel);
    if (!m) {
        gc_log("+[GCController %s] missing, not swizzled", sel_getName(sel));
        return;
    }
    *original = method_setImplementation(m, replacement);
}

// ---------------------------------------------------------------------------------------
// Real controllers (system-served) vs our pads

static NSArray<GCController *> *real_controllers(void) {
    NSArray *all = orig_controllers ? orig_controllers(gc_class, @selector(controllers)) : @[];
    NSMutableArray *real = [NSMutableArray array];
    for (GCController *c in all)
        if (!c.isSnapshot && !is_virtual(c)) [real addObject:c];
    return real;
}

static BOOL names_match(NSString *a, NSString *b) {
    if (a.length == 0 || b.length == 0) return NO;
    if ([a caseInsensitiveCompare:b] == NSOrderedSame) return YES;
    NSStringCompareOptions o = NSCaseInsensitiveSearch;
    return [a rangeOfString:b options:o].location != NSNotFound ||
           [b rangeOfString:a options:o].location != NSNotFound;
}

static BOOL claimed(GCController *real) {
    for (NPGCPad *pad in pads)
        if (pad->shadowed && pad->shadow == real) return YES;
    return NO;
}

// A real controller for this pad, not already claimed by another pad of the same name.
static GCController *real_match(NPGCPad *pad) {
    for (GCController *c in real_controllers())
        if (names_match(c.vendorName, pad.name) && !claimed(c)) return c;
    return nil;
}

// ---------------------------------------------------------------------------------------
// Publishing

static void post(NSString *name, GCController *c) {
    [NSNotificationCenter.defaultCenter postNotificationName:name object:c];
}

static void publish(NPGCPad *pad) {
    if (pad.controller || pad->removed || pad->shadowed) return;
    GCController *c = [(id)gc_class controllerWithExtendedGamepad];
    if (!c) {
        gc_log("controllerWithExtendedGamepad returned nil");
        return;
    }
    @try {
        [c setValue:pad.label forKey:@"vendorName"];
    } @catch (NSException *e) {
        gc_log("cannot set vendorName: %s", e.reason.UTF8String);
    }
    // Snapshots start at player index 0; a freshly connected real controller is unset.
    c.playerIndex = GCControllerPlayerIndexUnset;
    // Neutral state: the snapshot starts at zero, which already is neutral for every element.
    pad.controller = c;
    pad->have_last = NO;
    republish_list();
    gc_log("connect virtual \"%s\" (HID \"%s\")", pad.label.UTF8String, pad.name.UTF8String);
    post(kConnect, c);
}

static void unpublish(NPGCPad *pad, const char *why) {
    GCController *c = pad.controller;
    if (!c) return;
    pad.controller = nil;
    republish_list();
    if (last_active == c) last_active = nil;
    gc_log("disconnect virtual \"%s\" (%s)", pad.label.UTF8String, why);
    post(kDisconnect, c);
}

static void shadow_pad(NPGCPad *pad, GCController *real) {
    pad->shadowed = YES;
    pad->shadow = real;
    gc_log("\"%s\" is served by real GCController \"%s\": no virtual controller",
           pad.name.UTF8String, real.vendorName.UTF8String);
    unpublish(pad, "real controller present");
}

// After the grace period: skip the pad when the system serves it, else publish.
static void settle(NPGCPad *pad) {
    if (pad->removed || pad->shadowed || pad.controller) return;
    GCController *real = real_match(pad);
    if (real) shadow_pad(pad, real);
    else publish(pad);
}

static void real_connected(NSNotification *note) {
    GCController *c = note.object;
    if (!c || is_virtual(c) || c.isSnapshot || claimed(c)) return;
    for (NPGCPad *pad in pads) {
        if (pad->removed || pad->shadowed || !names_match(c.vendorName, pad.name)) continue;
        shadow_pad(pad, c);
        return;
    }
}

static void real_disconnected(NSNotification *note) {
    GCController *c = note.object;
    if (!c || is_virtual(c)) return;
    for (NPGCPad *pad in pads) {
        if (!pad->shadowed || pad->shadow != c) continue;
        // The system dropped its controller; if the HID device stays, take over.
        pad->shadowed = NO;
        pad->shadow = nil;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kGraceSeconds * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ settle(pad); });
    }
}

// ---------------------------------------------------------------------------------------
// Input

typedef void (^ProfileHandler)(GCExtendedGamepad *, GCControllerElement *);

static void changed(GCExtendedGamepad *gp, GCControllerElement *el) {
    if (!manual_profile_handlers || !el) return;
    ProfileHandler h = gp.valueChangedHandler;
    if (h) h(gp, el);
    if (@available(macOS 13.0, *)) {
        void (^h2)(GCPhysicalInputProfile *, GCControllerElement *) = gp.valueDidChangeHandler;
        if (h2) h2(gp, el);
    }
}

static void set_button(GCExtendedGamepad *gp, GCControllerButtonInput *b, float v, float old, BOOL force) {
    if (!b || (!force && v == old)) return;
    [b setValue:v];
    changed(gp, b);
}

static void set_pad(GCExtendedGamepad *gp, GCControllerDirectionPad *d, float x, float y, float ox,
                    float oy, BOOL force) {
    if (!d || (!force && x == ox && y == oy)) return;
    [d setValueForXAxis:x yAxis:y];
    changed(gp, d);
}

static float clamp1(float v) { return v < -1 ? -1 : v > 1 ? 1 : v; }
static float clamp01(float v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
static float bit(uint32_t buttons, int b) { return (buttons >> b) & 1 ? 1.0f : 0.0f; }

static void apply(NPGCPad *pad, const np_pad_state *s) {
    GCController *c = pad.controller;
    GCExtendedGamepad *gp = c.extendedGamepad;
    if (!gp) return;
    BOOL force = !pad->have_last;
    const np_pad_state *o = &pad->last;
    uint32_t nb = s->buttons, ob = o->buttons;

    // np_pad_state: +y down (SDL). GameController: +y up.
    set_pad(gp, gp.leftThumbstick, clamp1(s->lx), clamp1(-s->ly), clamp1(o->lx), clamp1(-o->ly), force);
    set_pad(gp, gp.rightThumbstick, clamp1(s->rx), clamp1(-s->ry), clamp1(o->rx), clamp1(-o->ry), force);
    set_button(gp, gp.leftTrigger, clamp01(s->lt), clamp01(o->lt), force);
    set_button(gp, gp.rightTrigger, clamp01(s->rt), clamp01(o->rt), force);

    float dx = bit(nb, NP_BTN_DPAD_RIGHT) - bit(nb, NP_BTN_DPAD_LEFT);
    float dy = bit(nb, NP_BTN_DPAD_UP) - bit(nb, NP_BTN_DPAD_DOWN);
    float odx = bit(ob, NP_BTN_DPAD_RIGHT) - bit(ob, NP_BTN_DPAD_LEFT);
    float ody = bit(ob, NP_BTN_DPAD_UP) - bit(ob, NP_BTN_DPAD_DOWN);
    set_pad(gp, gp.dpad, dx, dy, odx, ody, force);

    struct { int bit; GCControllerButtonInput *input; } map[] = {
        {NP_BTN_A, gp.buttonA},
        {NP_BTN_B, gp.buttonB},
        {NP_BTN_X, gp.buttonX},
        {NP_BTN_Y, gp.buttonY},
        {NP_BTN_LEFTSHOULDER, gp.leftShoulder},
        {NP_BTN_RIGHTSHOULDER, gp.rightShoulder},
        {NP_BTN_LEFTSTICK, gp.leftThumbstickButton},
        {NP_BTN_RIGHTSTICK, gp.rightThumbstickButton},
        {NP_BTN_START, gp.buttonMenu},
        {NP_BTN_BACK, gp.buttonOptions},
        {NP_BTN_GUIDE, nil},
    };
    if (@available(macOS 11.0, *)) map[10].input = gp.buttonHome;
    for (size_t i = 0; i < sizeof map / sizeof map[0]; i++)
        set_button(gp, map[i].input, bit(nb, map[i].bit), bit(ob, map[i].bit), force);

    pad->last = *s;
    pad->have_last = YES;

    if (last_active != c && (nb || fabsf(s->lx) > 0.5f || fabsf(s->ly) > 0.5f)) {
        last_active = c;
        BOOL real_current = NO;
        if (@available(macOS 11.0, *)) real_current = orig_current && orig_current(gc_class, @selector(current)) != nil;
        if (!real_current) post(kBecameCurrent, c);
    }
}

static void input_report(void *context, IOReturn result, void *sender, IOHIDReportType type,
                         uint32_t reportID, uint8_t *report, CFIndex length) {
    (void)sender;
    (void)type;
    NPGCPad *pad = (__bridge NPGCPad *)context;
    if (result != kIOReturnSuccess || pad->removed || !pad.controller) return;
    np_pad_state s;
    memset(&s, 0, sizeof s);
    if (!np_profile_decode(pad->profile, reportID, report, length, &s)) return;
    @autoreleasepool {
        apply(pad, &s);
    }
}

// ---------------------------------------------------------------------------------------
// HID devices

static NSString *string_property(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef v = IOHIDDeviceGetProperty(device, key);
    return v && CFGetTypeID(v) == CFStringGetTypeID() ? (__bridge NSString *)v : nil;
}

static long number_property(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef v = IOHIDDeviceGetProperty(device, key);
    long n = 0;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)v, kCFNumberLongType, &n);
    return n;
}

static NPGCPad *pad_for(IOHIDDeviceRef device) {
    for (NPGCPad *pad in pads)
        if (pad->device == device) return pad;
    return nil;
}

static void device_added(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)context;
    (void)result;
    (void)sender;
    if (pad_for(device)) return;
    // Synthetic HID devices the GameController framework itself creates.
    CFTypeRef synthetic = IOHIDDeviceGetProperty(device, CFSTR("GCSyntheticDevice"));
    if (synthetic && CFGetTypeID(synthetic) == CFBooleanGetTypeID() && CFBooleanGetValue(synthetic)) return;

    NSString *name = string_property(device, CFSTR(kIOHIDProductKey)) ?: @"";
    long vid = number_property(device, CFSTR(kIOHIDVendorIDKey));
    long pid = number_property(device, CFSTR(kIOHIDProductIDKey));
    np_profile *profile = np_profile_create(device);
    if (!profile) {
        gc_log("skip \"%s\" %04lx:%04lx: no profile (not a pad, or natively supported)", name.UTF8String,
               vid, pid);
        return;
    }

    NPGCPad *pad = [NPGCPad new];
    pad->device = (IOHIDDeviceRef)CFRetain(device);
    pad->profile = profile;
    pad.name = name;
    const char *label = np_profile_name(profile);
    pad.label = label && *label ? @(label) : (name.length ? name : @"Gamepad");
    long len = number_property(device, CFSTR(kIOHIDMaxInputReportSizeKey));
    pad->buffer_len = len > 0 ? len : 64;
    pad->buffer = calloc(1, (size_t)pad->buffer_len);
    [pads addObject:pad];

    IOHIDDeviceRegisterInputReportCallback(device, pad->buffer, pad->buffer_len, input_report,
                                           (__bridge void *)pad);
    gc_log("pad \"%s\" %04lx:%04lx profile \"%s\" guid %s", name.UTF8String, vid, pid,
           pad.label.UTF8String, np_profile_guid(profile) ?: "?");

    GCController *real = real_match(pad);
    if (real) {
        shadow_pad(pad, real);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kGraceSeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ settle(pad); });
}

static void device_removed(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)context;
    (void)result;
    (void)sender;
    NPGCPad *pad = pad_for(device);
    if (!pad) return;
    pad->removed = YES;
    unpublish(pad, "device removed");
    IOHIDDeviceRegisterInputReportCallback(device, pad->buffer, pad->buffer_len, NULL, NULL);
    [pads removeObject:pad];
    np_profile_free(pad->profile);
    pad->profile = NULL;
    // The buffer may still be referenced by a report already queued on this run loop pass;
    // free it on the next turn.
    uint8_t *buffer = pad->buffer;
    IOHIDDeviceRef dev = pad->device;
    pad->buffer = NULL;
    pad->device = NULL;
    dispatch_async(dispatch_get_main_queue(), ^{
        free(buffer);
        CFRelease(dev);
    });
    gc_log("pad \"%s\" removed", pad.name.UTF8String);
}

// ---------------------------------------------------------------------------------------
// Startup

// Startup self-test: does a snapshot write fire the profile-level handler by itself?
static void probe_handler_behaviour(void) {
    GCController *c = [(id)gc_class controllerWithExtendedGamepad];
    GCExtendedGamepad *gp = c.extendedGamepad;
    if (!gp) return;
    __block int fired = 0;
    gp.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *e) {
        (void)g;
        (void)e;
        fired++;
    };
    [gp.buttonA setValue:1];
    gp.valueChangedHandler = nil;
    manual_profile_handlers = fired == 0;
    gc_log("profile handlers on snapshot write: %s", fired ? "fired by framework" : "invoked by shim");
}

static void start(void) {
    gc_class = NSClassFromString(@"GCController");
    if (!gc_class || ![gc_class respondsToSelector:@selector(controllerWithExtendedGamepad)]) {
        gc_log("GCController.controllerWithExtendedGamepad unavailable, virtual controllers off");
        return;
    }
    pads = [NSMutableArray array];
    np_db_load();
    probe_handler_behaviour();

    swizzle_class_method(@selector(controllers), (IMP)np_controllers, (IMP *)&orig_controllers);
    if (@available(macOS 11.0, *)) swizzle_class_method(@selector(current), (IMP)np_current, (IMP *)&orig_current);

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:kConnect object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        real_connected(n);
    }];
    [nc addObserverForName:kDisconnect object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        real_disconnected(n);
    }];

    manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    NSArray *matching = @[
        @{@kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_Joystick)},
        @{@kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_GamePad)},
        @{@kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop),
          @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_MultiAxisController)},
    ];
    IOHIDManagerSetDeviceMatchingMultiple(manager, (__bridge CFArrayRef)matching);
    IOHIDManagerRegisterDeviceMatchingCallback(manager, device_added, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(manager, device_removed, NULL);
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    IOReturn r = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
    gc_log("started (IOHIDManagerOpen 0x%x)", r);
}

static void image_added(const struct mach_header *mh, intptr_t slide) {
    (void)slide;
    static int scheduled;
    if (__atomic_load_n(&scheduled, __ATOMIC_ACQUIRE)) return;
    Dl_info info;
    if (!dladdr(mh, &info) || !info.dli_fname || !strstr(info.dli_fname, "/GameController.framework/")) return;
    if (__atomic_exchange_n(&scheduled, 1, __ATOMIC_ACQ_REL)) return;
    // dyld holds its lock here: do the Objective-C work later on the main queue.
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            start();
        }
    });
}

__attribute__((constructor)) static void gc_virtual_init(void) {
    if (!(np_pad_mode() & NP_MODE_GC)) return;
    // Called at once for every loaded image, later for each dlopen: starts only when the
    // game itself brings in GameController.framework.
    _dyld_register_func_for_add_image(image_added);
}
