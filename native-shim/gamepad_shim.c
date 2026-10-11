// Makes game controllers that native macOS games do not recognise usable in games that
// read pads through raw HID (Unity's Input System, Rewired, SDL among them). Loaded with
// DYLD_INSERT_LIBRARIES (as part of libnp_gamepad.dylib), this presents every pad that
// np_profile_create() accepts as an Xbox Wireless Controller (Bluetooth, 045E:0B13) and
// rewrites its input reports into the 18-byte Xbox Bluetooth report layout.
//
// Origin: the first version handled one Bluetooth GameSir G7 Pro (3537:1022). Over
// Bluetooth that pad's primary usage is Consumer and its name is unknown to those games,
// so they skipped it. The lessons from it apply to every pad and are kept below:
//  - Unity identifies the pad only through IOHIDDeviceGetProperty, so spoofing the
//    product, manufacturer, vendor/product IDs and primary usage there is enough.
//  - Unity sizes its report buffer from MaxInputReportSize; the pad's own (11 for the
//    GameSir) would cut the translated report off before the hat and the buttons, so it
//    is spoofed to NP_XBOX_REPORT_LEN.
//  - Games that match on primary usage are never handed a pad whose primary usage is not
//    Gamepad, so device matching is extended (here: by DeviceUsagePairs).
//  - Interposed calls made from inside this dylib (hid_profile.c, gc_virtual.m and the
//    replacements below) reach the real IOKit functions: dyld does not redirect the
//    interposing image's own calls. That is what lets the replacements call the original.
//
// Game code only: dyld interposing also redirects calls made by Apple's frameworks.
// SDL 2.32+/SDL3 ask [GCController supportsHIDDevice:] about every HID device; if
// GameController.framework saw a spoofed 045E:0B13 it could claim the pad and SDL would
// drop it. So every replacement checks its caller (return address + dladdr, cached per
// call site) and passes calls from /System/ and /usr/lib/ images through untouched. A
// caller dladdr cannot place (JIT code: Mono/IL2CPP P/Invoke) counts as game code.
// Limit: a game function that tail-calls an IOHID function from a callback the system
// invoked would look like a system caller; no known game does that.
//
// dlsym: Rewired (Superliminal, Broforce) reaches IOKit through P/Invoke, which resolves
// functions with dlsym, so __interpose never sees those calls. dlsym is interposed too and
// hands game callers our replacements for the hooked names. Because the real dlsym
// resolves RTLD_NEXT/RTLD_SELF relative to its caller (which would now be this dylib),
// those two handles are resolved here relative to the real caller's image.
//
// Lifetime: every device this file has looked at is cached with a CFRetain, so its
// address cannot be reused by a new device while the entry exists (no ABA when a pad
// disconnects and another connects). Entries go away when a manager reports the device
// removed (IOHIDManagerRegisterDeviceRemovalCallback is wrapped), or are pruned when their
// service has left the IORegistry. Pads and their relays live in a static table that is
// never freed; a relay checks that the report's sender is still the pad in its slot, so a
// late report after removal is dropped, never sent through freed memory.
//
// Known limitation: games that read element values instead of input reports
// (IOHIDDeviceCopyMatchingElements, IOHIDDeviceRegisterInputValueCallback,
// IOHIDDeviceGetValue, IOHIDQueue) see the pad's real elements under the spoofed Xbox
// identity. Unity reads reports, so this is not handled yet. Polled reports
// (IOHIDDeviceGetReport) are not translated either.

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDLib.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "np_pad.h"

#define XB_VENDOR 0x045E
#define XB_PRODUCT 0x0B13
#define XB_REPORT_ID 1

#define MAX_DEVICES 256   // every HID device a game asked about, profiled or not
#define MAX_PADS 16       // profiled devices
#define MAX_MANAGERS 32   // managers with a wrapped removal callback
#define MAX_CALLERS 512   // call-site cache (power of two)
// Our own buffer for the pad's raw reports; the game's is sized for the Xbox report.
#define RAW_MAX 1024

#define INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *r; const void *o; } \
    interpose_##original __attribute__((section("__DATA,__interpose"))) = \
        { (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&original };

#define CALLER __builtin_extract_return_addr(__builtin_return_address(0))

struct pad {
    IOHIDDeviceRef device;            // NULL = free slot; not retained (struct dev holds it)
    np_profile *profile;
    np_pad_state state;
    IOHIDReportCallback cb;
    void *ctx;
    IOHIDReportWithTimeStampCallback cb_ts;
    void *ctx_ts;
    uint8_t out[NP_XBOX_REPORT_LEN];
    uint8_t out_ts[NP_XBOX_REPORT_LEN];
    uint8_t raw[RAW_MAX];
    uint8_t raw_ts[RAW_MAX];
};

struct dev {
    IOHIDDeviceRef device;            // retained; NULL = free slot
    struct pad *pad;                  // NULL = not a pad we translate
};

struct manager_slot {
    IOHIDManagerRef manager;          // not retained; only compared
    IOHIDDeviceCallback cb;
    void *ctx;
};

struct caller {
    const void *address;              // call site; NULL = empty
    int system;
};

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t callers_lock = PTHREAD_MUTEX_INITIALIZER;
static struct dev devs[MAX_DEVICES];
static struct pad pads[MAX_PADS];
static struct manager_slot managers[MAX_MANAGERS];
static struct caller callers[MAX_CALLERS];

static pthread_once_t init_once = PTHREAD_ONCE_INIT;
static int hid_on;
static int log_on;
static const char *mode_name = "off";
static CFNumberRef spoof_vendor, spoof_product, spoof_page, spoof_usage, spoof_size;

static CFNumberRef make_number(int value) {
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
}

static void init(void) {
    int mode = np_pad_mode();
    hid_on = (mode & NP_MODE_HID) != 0;
    mode_name = (mode & NP_MODE_HID) ? ((mode & NP_MODE_GC) ? "both" : "hid")
                                     : ((mode & NP_MODE_GC) ? "gc" : "off");
    const char *log = getenv("NP_PAD_LOG");
    log_on = log && strcmp(log, "1") == 0;
    if (!hid_on) return;
    // Get rule: callers of IOHIDDeviceGetProperty do not release, so these live forever.
    spoof_vendor = make_number(XB_VENDOR);
    spoof_product = make_number(XB_PRODUCT);
    spoof_page = make_number(kHIDPage_GenericDesktop);
    spoof_usage = make_number(kHIDUsage_GD_GamePad);
    spoof_size = make_number(NP_XBOX_REPORT_LEN);
    if (!spoof_vendor || !spoof_product || !spoof_page || !spoof_usage || !spoof_size) {
        hid_on = 0;                   // cannot spoof safely; stay out of the way
        return;
    }
    np_db_load();
}

static int hid_mode(void) {
    pthread_once(&init_once, init);
    return hid_on;
}

// ---- Caller filter -----------------------------------------------------------------

static int system_path(const char *path) {
    return path && (strncmp(path, "/System/", 8) == 0 || strncmp(path, "/usr/lib/", 9) == 0);
}

// 1 when the call site belongs to an Apple framework or system library.
static int from_system(const void *address) {
    if (!address) return 0;
    unsigned slot = (unsigned)(((uintptr_t)address >> 2) * 2654435761u) & (MAX_CALLERS - 1);
    pthread_mutex_lock(&callers_lock);
    for (unsigned i = 0; i < 8; i++) {
        struct caller *c = &callers[(slot + i) & (MAX_CALLERS - 1)];
        if (c->address == address) {
            int system = c->system;
            pthread_mutex_unlock(&callers_lock);
            return system;
        }
    }
    pthread_mutex_unlock(&callers_lock);
    Dl_info info;
    int system = dladdr(address, &info) && system_path(info.dli_fname);
    pthread_mutex_lock(&callers_lock);
    for (unsigned i = 0; i < 8; i++) {
        struct caller *c = &callers[(slot + i) & (MAX_CALLERS - 1)];
        if (!c->address) {
            c->address = address;
            c->system = system;
            break;
        }
    }
    pthread_mutex_unlock(&callers_lock);   // a full bucket just means no caching
    return system;
}

// HID mode is on and the call comes from game code.
static int serve(const void *caller) {
    return hid_mode() && !from_system(caller);
}

// ---- Device cache ------------------------------------------------------------------

// A cached device whose service has left the registry was unplugged without a removal
// callback reaching us.
static int device_gone(IOHIDDeviceRef device) {
    io_service_t service = IOHIDDeviceGetService(device);
    return service == MACH_PORT_NULL || !IORegistryEntryInPlane(service, kIOServicePlane);
}

// Unlinks a cache entry. Called with the lock held; the caller frees the profile and
// releases the device after unlocking, since neither may run under our lock.
static void unlink_dev(struct dev *d, np_profile **profile, IOHIDDeviceRef *device) {
    *profile = NULL;
    *device = d->device;
    if (d->pad) {
        *profile = d->pad->profile;
        // Neutralise the relay; the slot memory stays valid for late callbacks.
        d->pad->device = NULL;
        d->pad->profile = NULL;
        d->pad->cb = NULL;
        d->pad->ctx = NULL;
        d->pad->cb_ts = NULL;
        d->pad->ctx_ts = NULL;
    }
    d->device = NULL;
    d->pad = NULL;
}

static struct dev *find_dev(IOHIDDeviceRef device) {
    for (int i = 0; i < MAX_DEVICES; i++)
        if (devs[i].device == device) return &devs[i];
    return NULL;
}

static void forget_device(IOHIDDeviceRef device) {
    np_profile *profile = NULL;
    IOHIDDeviceRef release = NULL;
    if (!device) return;
    pthread_mutex_lock(&lock);
    struct dev *d = find_dev(device);
    if (d) unlink_dev(d, &profile, &release);
    pthread_mutex_unlock(&lock);
    if (profile) np_profile_free(profile);
    if (release) CFRelease(release);
}

// Drops every entry whose device has gone. Called without the lock.
static void prune(void) {
    np_profile *profiles[MAX_DEVICES];
    IOHIDDeviceRef released[MAX_DEVICES];
    int n = 0;
    pthread_mutex_lock(&lock);
    for (int i = 0; i < MAX_DEVICES; i++)
        if (devs[i].device && device_gone(devs[i].device)) {
            unlink_dev(&devs[i], &profiles[n], &released[n]);
            n++;
        }
    pthread_mutex_unlock(&lock);
    for (int i = 0; i < n; i++) {
        if (profiles[i]) np_profile_free(profiles[i]);
        if (released[i]) CFRelease(released[i]);
    }
}

// The pad slot for a device we translate, creating the profile on first sight; NULL for
// every device we leave alone.
static struct pad *pad_for(IOHIDDeviceRef device) {
    if (!device || CFGetTypeID(device) != IOHIDDeviceGetTypeID()) return NULL;
    pthread_mutex_lock(&lock);
    struct dev *d = find_dev(device);
    struct pad *p = d ? d->pad : NULL;
    pthread_mutex_unlock(&lock);
    if (d) return p;

    // First sight: profile outside the lock (it reads the descriptor through IOKit).
    prune();
    np_profile *profile = np_profile_create(device);
    np_profile *discard = NULL;
    int logged = 0;
    pthread_mutex_lock(&lock);
    d = find_dev(device);
    p = NULL;
    if (d) {                                  // another thread got there first
        p = d->pad;
        discard = profile;
    } else {
        for (int i = 0; i < MAX_DEVICES && !d; i++)
            if (!devs[i].device) d = &devs[i];
        if (!d) {
            discard = profile;                // table full: leave the device alone
        } else {
            if (profile)
                for (int i = 0; i < MAX_PADS && !p; i++)
                    if (!pads[i].device) p = &pads[i];
            if (profile && !p) discard = profile;   // too many pads: leave it alone
            if (p) {
                memset(&p->state, 0, sizeof p->state);
                p->profile = profile;
                p->cb = NULL;
                p->ctx = NULL;
                p->cb_ts = NULL;
                p->ctx_ts = NULL;
                p->device = device;
                logged = log_on;
            }
            d->device = (IOHIDDeviceRef)CFRetain(device);
            d->pad = p;
        }
    }
    pthread_mutex_unlock(&lock);
    if (discard) np_profile_free(discard);
    if (logged) {
        // profile stays valid here: only removal frees it, after this device is gone.
        const char *guid = np_profile_guid(profile), *name = np_profile_name(profile);
        fprintf(stderr, "np_gamepad: %s \"%s\" -> Xbox Wireless Controller, mode=%s\n",
                guid ? guid : "?", name ? name : "?", mode_name);
    }
    return p;
}

// ---- Identity ----------------------------------------------------------------------

static CFTypeRef get_property(const void *caller, IOHIDDeviceRef device, CFStringRef key) {
    if (!key || !serve(caller) || !pad_for(device))
        return IOHIDDeviceGetProperty(device, key);
    CFTypeRef spoof = NULL;
    if (CFEqual(key, CFSTR(kIOHIDProductKey))) spoof = CFSTR("Xbox Wireless Controller");
    else if (CFEqual(key, CFSTR(kIOHIDManufacturerKey))) spoof = CFSTR("Microsoft");
    else if (CFEqual(key, CFSTR(kIOHIDVendorIDKey))) spoof = spoof_vendor;
    else if (CFEqual(key, CFSTR(kIOHIDProductIDKey))) spoof = spoof_product;
    else if (CFEqual(key, CFSTR(kIOHIDPrimaryUsagePageKey))) spoof = spoof_page;
    else if (CFEqual(key, CFSTR(kIOHIDPrimaryUsageKey))) spoof = spoof_usage;
    // Callers size their report buffer from this; the pad's own value could cut the
    // translated report off before the hat and the buttons.
    else if (CFEqual(key, CFSTR(kIOHIDMaxInputReportSizeKey))) spoof = spoof_size;
    return spoof ? spoof : IOHIDDeviceGetProperty(device, key);
}

static CFTypeRef np_IOHIDDeviceGetProperty(IOHIDDeviceRef device, CFStringRef key) {
    return get_property(CALLER, device, key);
}
INTERPOSE(np_IOHIDDeviceGetProperty, IOHIDDeviceGetProperty)

// ---- Reports -----------------------------------------------------------------------

// Decodes one raw report into the slot's Xbox buffer. Returns the Xbox report, or NULL
// when the report is dropped. Fills the game's callback and context.
static uint8_t *translate(struct pad *p, void *sender, uint32_t reportID, const uint8_t *report,
                          CFIndex length, int timestamped, void **callback, void **context) {
    uint8_t *out = NULL;
    pthread_mutex_lock(&lock);
    if (p->device && p->device == sender && p->profile && report && length > 0) {
        void *cb = timestamped ? (void *)p->cb_ts : (void *)p->cb;
        if (cb && np_profile_decode(p->profile, reportID, report, length, &p->state) == 1) {
            out = timestamped ? p->out_ts : p->out;
            np_xbox_encode(&p->state, out);
            *callback = cb;
            *context = timestamped ? p->ctx_ts : p->ctx;
        }
    }
    pthread_mutex_unlock(&lock);
    return out;   // the game's callback runs without our lock held
}

static void relay_report(void *context, IOReturn result, void *sender, IOHIDReportType type,
                         uint32_t reportID, uint8_t *report, CFIndex length) {
    void *cb = NULL, *ctx = NULL;
    uint8_t *out = translate(context, sender, reportID, report, length, 0, &cb, &ctx);
    if (out)
        ((IOHIDReportCallback)cb)(ctx, result, sender, type, XB_REPORT_ID, out,
                                  NP_XBOX_REPORT_LEN);
}

static void relay_report_ts(void *context, IOReturn result, void *sender, IOHIDReportType type,
                            uint32_t reportID, uint8_t *report, CFIndex length,
                            uint64_t timeStamp) {
    void *cb = NULL, *ctx = NULL;
    uint8_t *out = translate(context, sender, reportID, report, length, 1, &cb, &ctx);
    if (out)
        ((IOHIDReportWithTimeStampCallback)cb)(ctx, result, sender, type, XB_REPORT_ID, out,
                                               NP_XBOX_REPORT_LEN, timeStamp);
}

static void register_report(const void *caller, IOHIDDeviceRef device, uint8_t *report,
                            CFIndex length, IOHIDReportCallback callback, void *context) {
    struct pad *p = serve(caller) ? pad_for(device) : NULL;
    if (!p) {
        IOHIDDeviceRegisterInputReportCallback(device, report, length, callback, context);
        return;
    }
    pthread_mutex_lock(&lock);
    int live = p->device == device;
    if (live) {
        p->cb = callback;
        p->ctx = context;
    }
    pthread_mutex_unlock(&lock);
    if (!live || !callback) {
        // Unregister (or a device removed meanwhile): the game's own arguments.
        IOHIDDeviceRegisterInputReportCallback(device, report, length, callback, context);
        return;
    }
    // The pad's raw reports go to our buffer: the game's is sized for the Xbox report.
    IOHIDDeviceRegisterInputReportCallback(device, p->raw, RAW_MAX, relay_report, p);
}

static void np_IOHIDDeviceRegisterInputReportCallback(IOHIDDeviceRef device, uint8_t *report,
                                                      CFIndex length, IOHIDReportCallback callback,
                                                      void *context) {
    register_report(CALLER, device, report, length, callback, context);
}
INTERPOSE(np_IOHIDDeviceRegisterInputReportCallback, IOHIDDeviceRegisterInputReportCallback)

static void register_report_ts(const void *caller, IOHIDDeviceRef device, uint8_t *report,
                               CFIndex length, IOHIDReportWithTimeStampCallback callback,
                               void *context) {
    struct pad *p = serve(caller) ? pad_for(device) : NULL;
    if (!p) {
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, report, length, callback,
                                                            context);
        return;
    }
    pthread_mutex_lock(&lock);
    int live = p->device == device;
    if (live) {
        p->cb_ts = callback;
        p->ctx_ts = context;
    }
    pthread_mutex_unlock(&lock);
    if (!live || !callback) {
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, report, length, callback,
                                                            context);
        return;
    }
    IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, p->raw_ts, RAW_MAX,
                                                        relay_report_ts, p);
}

static void np_IOHIDDeviceRegisterInputReportWithTimeStampCallback(
    IOHIDDeviceRef device, uint8_t *report, CFIndex length,
    IOHIDReportWithTimeStampCallback callback, void *context) {
    register_report_ts(CALLER, device, report, length, callback, context);
}
INTERPOSE(np_IOHIDDeviceRegisterInputReportWithTimeStampCallback,
          IOHIDDeviceRegisterInputReportWithTimeStampCallback)

// ---- Removal -----------------------------------------------------------------------

static void relay_removal(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    struct manager_slot *m = context;
    pthread_mutex_lock(&lock);
    IOHIDDeviceCallback cb = m->manager == sender ? m->cb : NULL;
    void *ctx = m->ctx;
    pthread_mutex_unlock(&lock);
    // The game's callback first: it may still read the (spoofed) identity of the pad.
    if (cb) cb(ctx, result, sender, device);
    forget_device(device);
}

// Wrapped for every caller: it only adds cache cleanup, the game's callback is unchanged.
static void np_IOHIDManagerRegisterDeviceRemovalCallback(IOHIDManagerRef manager,
                                                         IOHIDDeviceCallback callback,
                                                         void *context) {
    if (!manager || !hid_mode()) {
        IOHIDManagerRegisterDeviceRemovalCallback(manager, callback, context);
        return;
    }
    struct manager_slot *m = NULL, *free_slot = NULL;
    pthread_mutex_lock(&lock);
    for (int i = 0; i < MAX_MANAGERS && !m; i++) {
        if (managers[i].manager == manager) m = &managers[i];
        else if (!managers[i].manager && !free_slot) free_slot = &managers[i];
    }
    if (!m) m = free_slot;
    if (m) {
        // A manager freed and a new one at the same address simply takes over the slot.
        m->manager = manager;
        m->cb = callback;
        m->ctx = context;
    }
    pthread_mutex_unlock(&lock);
    if (m)   // still registered when the game passes NULL, so the cache is cleaned up
        IOHIDManagerRegisterDeviceRemovalCallback(manager, relay_removal, m);
    else     // out of slots: pruning by registry presence still frees stale entries
        IOHIDManagerRegisterDeviceRemovalCallback(manager, callback, context);
}
INTERPOSE(np_IOHIDManagerRegisterDeviceRemovalCallback, IOHIDManagerRegisterDeviceRemovalCallback)

// ---- Matching ----------------------------------------------------------------------

static int dict_int(CFDictionaryRef dict, CFStringRef key, int *out) {
    CFTypeRef value = CFDictionaryGetValue(dict, key);
    return value && CFGetTypeID(value) == CFNumberGetTypeID() &&
           CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, out);
}

// A matching dict that asks for game controllers: GenericDesktop with Joystick, Gamepad,
// MultiAxis or no usage, by primary or device usage, not narrowed to one vendor.
static int wants_pads(CFTypeRef value) {
    if (!value || CFGetTypeID(value) != CFDictionaryGetTypeID()) return 0;
    CFDictionaryRef dict = value;
    int page, usage;
    if (CFDictionaryContainsKey(dict, CFSTR(kIOHIDVendorIDKey))) return 0;
    if (!dict_int(dict, CFSTR(kIOHIDDeviceUsagePageKey), &page) &&
        !dict_int(dict, CFSTR(kIOHIDPrimaryUsagePageKey), &page))
        return 0;
    if (page != kHIDPage_GenericDesktop) return 0;
    if (!dict_int(dict, CFSTR(kIOHIDDeviceUsageKey), &usage) &&
        !dict_int(dict, CFSTR(kIOHIDPrimaryUsageKey), &usage))
        return 1;
    return usage == kHIDUsage_GD_Joystick || usage == kHIDUsage_GD_GamePad ||
           usage == kHIDUsage_GD_MultiAxisController;
}

// The game's dicts plus DeviceUsagePairs dicts for Joystick, Gamepad and MultiAxis, so a
// pad whose primary usage is something else (the GameSir over Bluetooth: Consumer) is
// enumerated too. NULL when nothing needs adding.
static CFArrayRef extend_matching(CFArrayRef multiple) {
    CFIndex count = CFArrayGetCount(multiple);
    int wanted = 0;
    for (CFIndex i = 0; i < count && !wanted; i++)
        wanted = wants_pads(CFArrayGetValueAtIndex(multiple, i));
    if (!wanted) return NULL;
    CFMutableArrayRef all = CFArrayCreateMutableCopy(kCFAllocatorDefault, 0, multiple);
    if (!all) return NULL;
    static const int usages[] = { kHIDUsage_GD_Joystick, kHIDUsage_GD_GamePad,
                                  kHIDUsage_GD_MultiAxisController };
    CFNumberRef page = make_number(kHIDPage_GenericDesktop);
    for (unsigned i = 0; page && i < sizeof usages / sizeof *usages; i++) {
        CFNumberRef usage = make_number(usages[i]);
        CFMutableDictionaryRef dict = CFDictionaryCreateMutable(kCFAllocatorDefault, 2,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (usage && dict) {
            CFDictionarySetValue(dict, CFSTR(kIOHIDDeviceUsagePageKey), page);
            CFDictionarySetValue(dict, CFSTR(kIOHIDDeviceUsageKey), usage);
            CFArrayAppendValue(all, dict);
        }
        if (usage) CFRelease(usage);
        if (dict) CFRelease(dict);
    }
    if (page) CFRelease(page);
    return all;
}

static void set_matching_multiple(const void *caller, IOHIDManagerRef manager,
                                  CFArrayRef multiple) {
    CFArrayRef all = NULL;
    if (multiple && CFGetTypeID(multiple) == CFArrayGetTypeID() && serve(caller))
        all = extend_matching(multiple);
    IOHIDManagerSetDeviceMatchingMultiple(manager, all ? all : multiple);
    if (all) CFRelease(all);
}

static void np_IOHIDManagerSetDeviceMatchingMultiple(IOHIDManagerRef manager, CFArrayRef multiple) {
    set_matching_multiple(CALLER, manager, multiple);
}
INTERPOSE(np_IOHIDManagerSetDeviceMatchingMultiple, IOHIDManagerSetDeviceMatchingMultiple)

static void set_matching(const void *caller, IOHIDManagerRef manager, CFDictionaryRef matching) {
    CFArrayRef all = NULL;
    if (matching && serve(caller) && wants_pads(matching)) {
        CFArrayRef one = CFArrayCreate(kCFAllocatorDefault, (const void **)&matching, 1,
                                       &kCFTypeArrayCallBacks);
        if (one) {
            all = extend_matching(one);
            CFRelease(one);
        }
    }
    if (all) {
        IOHIDManagerSetDeviceMatchingMultiple(manager, all);
        CFRelease(all);
    } else {
        IOHIDManagerSetDeviceMatching(manager, matching);
    }
}

static void np_IOHIDManagerSetDeviceMatching(IOHIDManagerRef manager, CFDictionaryRef matching) {
    set_matching(CALLER, manager, matching);
}
INTERPOSE(np_IOHIDManagerSetDeviceMatching, IOHIDManagerSetDeviceMatching)

// ---- dlsym (P/Invoke) --------------------------------------------------------------

static const struct { const char *name; const void *original; void *replacement; } hooked[] = {
#define HOOK(f) { #f, (const void *)&f, (void *)np_##f }
    HOOK(IOHIDDeviceGetProperty),
    HOOK(IOHIDDeviceRegisterInputReportCallback),
    HOOK(IOHIDDeviceRegisterInputReportWithTimeStampCallback),
    HOOK(IOHIDManagerSetDeviceMatching),
    HOOK(IOHIDManagerSetDeviceMatchingMultiple),
    HOOK(IOHIDManagerRegisterDeviceRemovalCallback),
#undef HOOK
};

// Our replacement when symbol is one of the real IOKit functions we hook (inside this
// image those names still mean the originals), else symbol itself.
static void *hook_symbol(const char *name, void *symbol) {
    if (!symbol || !hid_mode()) return symbol;
    for (unsigned i = 0; i < sizeof hooked / sizeof *hooked; i++)
        if (symbol == hooked[i].original && strcmp(name, hooked[i].name) == 0)
            return hooked[i].replacement;
    return symbol;
}

// RTLD_NEXT / RTLD_SELF on behalf of the image at caller: the first image at or after
// it (after it for RTLD_NEXT) in load order that defines name.
static void *relative_dlsym(const void *caller, const char *name, int include_self) {
    Dl_info info;
    if (!dladdr(caller, &info) || !info.dli_fbase) return NULL;
    uint32_t count = _dyld_image_count();
    uint32_t start = UINT32_MAX;
    for (uint32_t i = 0; i < count; i++)
        if ((const void *)_dyld_get_image_header(i) == info.dli_fbase) {
            start = include_self ? i : i + 1;
            break;
        }
    if (start == UINT32_MAX) return NULL;
    for (uint32_t i = start; i < count; i++) {
        const void *header = _dyld_get_image_header(i);
        const char *path = _dyld_get_image_name(i);
        if (!header || !path) continue;
        void *handle = dlopen(path, RTLD_LAZY | RTLD_NOLOAD);
        if (!handle) continue;
        void *symbol = dlsym(handle, name);
        dlclose(handle);
        Dl_info found;
        // dlsym on a handle also searches its dependencies; keep only this image's own.
        if (symbol && dladdr(symbol, &found) && found.dli_fbase == header) return symbol;
    }
    return NULL;
}

static void *np_dlsym(void *handle, const char *name) {
    const void *caller = CALLER;
    if (!name || from_system(caller)) return dlsym(handle, name);
    Dl_info info;
    // A caller we cannot place (JIT) has no image to be relative to: real dlsym.
    if ((handle == RTLD_NEXT || handle == RTLD_SELF) && dladdr(caller, &info) && info.dli_fbase)
        return hook_symbol(name, relative_dlsym(caller, name, handle == RTLD_SELF));
    return hook_symbol(name, dlsym(handle, name));
}
INTERPOSE(np_dlsym, dlsym)
