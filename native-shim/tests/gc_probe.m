// gc_probe: what a GameController-framework game sees.
//
// Prints every GCController (already present or connecting later), then for N seconds
// (default 5, argv[1]) prints extendedGamepad leftThumbstick / buttonA whenever they change,
// both from the game-style valueChangedHandler and from polling (so a missing handler shows).
//
//   clang -fobjc-arc -framework Foundation -framework GameController tests/gc_probe.m -o gc_probe
//   ./gc_probe 5
//   NP_PAD_MODE=gc DYLD_INSERT_LIBRARIES=libnp_gamepad.dylib ./gc_probe 5

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>

static NSMutableSet *watched;

static void describe(const char *tag, GCController *c) {
    printf("%s vendorName=\"%s\" category=\"%s\" snapshot=%d extended=%d players=%ld\n", tag,
           c.vendorName.UTF8String ?: "(null)", c.productCategory.UTF8String ?: "(null)",
           (int)c.isSnapshot, c.extendedGamepad != nil, (long)c.playerIndex);
    fflush(stdout);
}

static void watch(GCController *c) {
    if (!c.extendedGamepad || [watched containsObject:c]) return;
    [watched addObject:c];
    NSString *name = c.vendorName ?: @"?";
    c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *pad, GCControllerElement *el) {
        if (el == pad.leftThumbstick || el == pad.leftThumbstick.xAxis || el == pad.leftThumbstick.yAxis)
            printf("  [handler %s] leftThumbstick x=%+.3f y=%+.3f\n", name.UTF8String,
                   pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value);
        else if (el == pad.buttonA)
            printf("  [handler %s] buttonA value=%.2f pressed=%d\n", name.UTF8String,
                   pad.buttonA.value, pad.buttonA.pressed);
        fflush(stdout);
    };
}

int main(int argc, char **argv) {
    @autoreleasepool {
        double seconds = argc > 1 ? atof(argv[1]) : 5;
        watched = [NSMutableSet set];
        if (@available(macOS 11.3, *)) GCController.shouldMonitorBackgroundEvents = YES;

        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *n) { describe("connect:", n.object); watch(n.object); }];
        [nc addObserverForName:GCControllerDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *n) { describe("disconnect:", n.object); [watched removeObject:n.object]; }];

        NSArray *initial = GCController.controllers;
        printf("initial controllers: %lu\n", (unsigned long)initial.count);
        for (GCController *c in initial) { describe("initial:", c); watch(c); }

        __block NSMutableDictionary *last = [NSMutableDictionary dictionary];
        NSTimer *poll = [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *t) {
            for (GCController *c in GCController.controllers) {
                GCExtendedGamepad *p = c.extendedGamepad;
                if (!p) continue;
                NSString *s = [NSString stringWithFormat:@"x=%+.3f y=%+.3f A=%.2f",
                               p.leftThumbstick.xAxis.value, p.leftThumbstick.yAxis.value, p.buttonA.value];
                NSValue *key = [NSValue valueWithNonretainedObject:c];
                if (![last[key] isEqualToString:s]) {
                    last[key] = s;
                    printf("  [poll %s] %s\n", c.vendorName.UTF8String ?: "?", s.UTF8String);
                    fflush(stdout);
                }
            }
        }];
        (void)poll;

        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];

        NSArray *final = GCController.controllers;
        printf("final controllers: %lu\n", (unsigned long)final.count);
        for (GCController *c in final) describe("final:", c);
        if (@available(macOS 11.0, *)) {
            GCController *cur = GCController.current;
            printf("current: %s\n", cur ? (cur.vendorName.UTF8String ?: "(null)") : "(none)");
        }
    }
    return 0;
}
