// Makes a Bluetooth GameSir G7 Pro usable in native macOS games that read pads through
// raw HID (Unity's Input System among them). Over Bluetooth the pad's primary usage is
// Consumer and its name is unknown to those games, so they skip it. Loaded with
// DYLD_INSERT_LIBRARIES, this presents the pad as an Xbox Wireless Controller and
// rewrites its gamepad report (ID 7) into the Xbox Bluetooth report layout. The button
// bits already match Xbox's; sticks, triggers and the hat differ.
//
// Build: clang -arch arm64 -arch x86_64 -dynamiclib -O2 -framework IOKit
//        -framework CoreFoundation -o libnp_gamepad.dylib gamepad_shim.c

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDLib.h>
#include <stdlib.h>
#include <string.h>

#define GS_VENDOR 0x3537
#define GS_PRODUCT 0x1022
#define XB_VENDOR 0x045E
#define XB_PRODUCT 0x0B13
#define GS_PAD_REPORT 7
#define XB_REPORT_LEN 18

#define INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *r; const void *o; } \
    interpose_##original __attribute__((section("__DATA,__interpose"))) = \
        { (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&original };

static int number_property(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    int out = -1;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &out);
    return out;
}

static int is_bluetooth_gamesir(IOHIDDeviceRef device) {
    if (!device || number_property(device, CFSTR(kIOHIDVendorIDKey)) != GS_VENDOR ||
        number_property(device, CFSTR(kIOHIDProductIDKey)) != GS_PRODUCT)
        return 0;
    CFTypeRef transport = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDTransportKey));
    return transport && CFGetTypeID(transport) == CFStringGetTypeID() &&
           CFStringCompare((CFStringRef)transport, CFSTR("Bluetooth"), 0) == kCFCompareEqualTo;
}

static CFNumberRef make_number(int value) {
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
}

static CFTypeRef np_IOHIDDeviceGetProperty(IOHIDDeviceRef device, CFStringRef key) {
    if (!is_bluetooth_gamesir(device))
        return IOHIDDeviceGetProperty(device, key);
    // Get rule: the caller does not release, so the spoofed values are made once.
    static CFNumberRef vendor, product, page, usage, size;
    if (!vendor) {
        size = make_number(XB_REPORT_LEN);
        vendor = make_number(XB_VENDOR);
        product = make_number(XB_PRODUCT);
        page = make_number(kHIDPage_GenericDesktop);
        usage = make_number(kHIDUsage_GD_GamePad);
    }
    if (CFEqual(key, CFSTR(kIOHIDProductKey))) return CFSTR("Xbox Wireless Controller");
    if (CFEqual(key, CFSTR(kIOHIDManufacturerKey))) return CFSTR("Microsoft");
    if (CFEqual(key, CFSTR(kIOHIDVendorIDKey))) return vendor;
    if (CFEqual(key, CFSTR(kIOHIDProductIDKey))) return product;
    if (CFEqual(key, CFSTR(kIOHIDPrimaryUsagePageKey))) return page;
    if (CFEqual(key, CFSTR(kIOHIDPrimaryUsageKey))) return usage;
    // Callers size their report buffer from this; the pad's own 11 would cut the
    // translated report off before the hat and the buttons.
    if (CFEqual(key, CFSTR(kIOHIDMaxInputReportSizeKey))) return size;
    return IOHIDDeviceGetProperty(device, key);
}
INTERPOSE(np_IOHIDDeviceGetProperty, IOHIDDeviceGetProperty)

struct relay {
    IOHIDReportCallback callback;
    void *context;
    uint8_t out[XB_REPORT_LEN];
};

static void put16(uint8_t *at, unsigned value) {
    at[0] = value & 0xff;
    at[1] = (value >> 8) & 0xff;
}

// GameSir report 7: [7, X, Y, Z, Rz, hat(low nibble, 0=up clockwise, >7 none),
// buttons lo, buttons hi, accel (right trigger), brake (left trigger), pad].
// Xbox: [1, LX16, LY16, RX16, RY16, LT10, RT10, hat(1=up clockwise, 0 none), buttons32].
static void relay_report(void *context, IOReturn result, void *sender, IOHIDReportType type,
                         uint32_t reportID, uint8_t *report, CFIndex length) {
    struct relay *r = context;
    if (reportID != GS_PAD_REPORT || length < 10) return;
    uint8_t *x = r->out;
    memset(x, 0, sizeof r->out);
    x[0] = 1;
    put16(x + 1, report[1] * 257u);
    put16(x + 3, report[2] * 257u);
    put16(x + 5, report[3] * 257u);
    put16(x + 7, report[4] * 257u);
    put16(x + 9, report[9] * 1023u / 255u);
    put16(x + 11, report[8] * 1023u / 255u);
    unsigned hat = report[5] & 0x0f;
    x[13] = hat < 8 ? hat + 1 : 0;
    x[14] = report[6];
    x[15] = report[7];
    r->callback(r->context, result, sender, type, 1, x, XB_REPORT_LEN);
}

static void np_IOHIDDeviceRegisterInputReportCallback(IOHIDDeviceRef device, uint8_t *report,
                                                      CFIndex length, IOHIDReportCallback callback,
                                                      void *context) {
    if (!callback || !is_bluetooth_gamesir(device)) {
        IOHIDDeviceRegisterInputReportCallback(device, report, length, callback, context);
        return;
    }
    // One registration per open device for the life of the game; the relay is kept.
    struct relay *r = calloc(1, sizeof *r);
    r->callback = callback;
    r->context = context;
    IOHIDDeviceRegisterInputReportCallback(device, report, length, relay_report, r);
}
INTERPOSE(np_IOHIDDeviceRegisterInputReportCallback, IOHIDDeviceRegisterInputReportCallback)

// Games that match on primary usage would never be handed the pad; ask for it by id too.
static void np_IOHIDManagerSetDeviceMatchingMultiple(IOHIDManagerRef manager, CFArrayRef multiple) {
    if (!multiple) {
        IOHIDManagerSetDeviceMatchingMultiple(manager, multiple);
        return;
    }
    CFMutableArrayRef all = CFArrayCreateMutableCopy(kCFAllocatorDefault, 0, multiple);
    CFMutableDictionaryRef pad = CFDictionaryCreateMutable(kCFAllocatorDefault, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFNumberRef vendor = make_number(GS_VENDOR), product = make_number(GS_PRODUCT);
    CFDictionarySetValue(pad, CFSTR(kIOHIDVendorIDKey), vendor);
    CFDictionarySetValue(pad, CFSTR(kIOHIDProductIDKey), product);
    CFArrayAppendValue(all, pad);
    IOHIDManagerSetDeviceMatchingMultiple(manager, all);
    CFRelease(vendor);
    CFRelease(product);
    CFRelease(pad);
    CFRelease(all);
}
INTERPOSE(np_IOHIDManagerSetDeviceMatchingMultiple, IOHIDManagerSetDeviceMatchingMultiple)
