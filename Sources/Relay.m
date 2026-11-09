#import "Relay.h"
#import "DockState.h"
#import <ApplicationServices/ApplicationServices.h>
#import <os/log.h>
#import <time.h>
#import <math.h>

// AppKit declares these tracking event values. Their use as Quartz event types
// delivered to Dock is an observed implementation detail, not a Quartz contract.
static const CGEventType Entered = (CGEventType)NSEventTypeMouseEntered;
static const CGEventType Exited = (CGEventType)NSEventTypeMouseExited;
static const NSTimeInterval MaxLead = 1.0;
static const NSTimeInterval MaxLag = 0.2;
static const double CheckTimes[] = {0.18, 0.36, 0.63, 1.05, 1.65};

static pid_t DockPID(void) {
    return [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"]
        .firstObject.processIdentifier;
}

@interface Relay ()
- (void)track:(CGEventType)type event:(CGEventRef)event;
@end

static CGEventRef Track(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    (void)proxy;
    [(__bridge Relay *)context track:type event:event];
    return event;
}

@implementation Relay {
    CFMachPortRef _tap;
    CFRunLoopSourceRef _source;
    pid_t _pid;
    CGEventRef _exit;
    NSTimeInterval _exitAt;
    CGEventTimestamp _replayTimestamp;
    NSUInteger _generation;
    NSTimeInterval _changedAt;
    DockState _previous;
    NSUInteger _attempts;
    dispatch_queue_t _inspection;
    os_log_t _log;
}

- (void)start {
    _inspection = dispatch_queue_create("io.github.linxitian.dockrelay.inspect", DISPATCH_QUEUE_SERIAL);
    _log = os_log_create("io.github.linxitian.dockrelay", "relay");
    dispatch_async(_inspection, ^{
        AXUIElementRef system = AXUIElementCreateSystemWide();
        AXUIElementSetMessagingTimeout(system, 0.08);
        CFRelease(system);
    });

    NSNotificationCenter *workspace = NSWorkspace.sharedWorkspace.notificationCenter;
    [workspace addObserver:self selector:@selector(spaceChanged:)
                      name:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
    [workspace addObserver:self selector:@selector(sessionResumed:)
                      name:NSWorkspaceDidWakeNotification object:nil];
    [workspace addObserver:self selector:@selector(sessionResumed:)
                      name:NSWorkspaceSessionDidBecomeActiveNotification object:nil];
    [workspace addObserver:self selector:@selector(sessionSuspended:)
                      name:NSWorkspaceSessionDidResignActiveNotification object:nil];
    [self refresh];
}

- (BOOL)listening {
    return _tap && CGEventTapIsEnabled(_tap) && _pid == DockPID() && AXIsProcessTrusted();
}

- (void)clearExit {
    if (_exit) CFRelease(_exit);
    _exit = NULL;
    _exitAt = 0;
}

- (void)detach {
    _generation++;
    [self clearExit];
    if (_source) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
        CFRelease(_source);
        _source = NULL;
    }
    if (_tap) {
        CFMachPortInvalidate(_tap);
        CFRelease(_tap);
        _tap = NULL;
    }
    _pid = 0;
}

- (void)refresh {
    if (self.listening) return;
    [self detach];
    pid_t dock = DockPID();
    if (dock <= 0 || !AXIsProcessTrusted()) return;
    CGEventMask mask = CGEventMaskBit(Entered) | CGEventMaskBit(Exited);
    _tap = CGEventTapCreateForPid(dock, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly,
                                 mask, Track, (__bridge void *)self);
    if (!_tap) {
        os_log_error(_log, "Unable to attach Dock event tap");
        return;
    }
    _source = CFMachPortCreateRunLoopSource(NULL, _tap, 0);
    if (!_source) {
        [self detach];
        return;
    }
    _pid = dock;
    CFRunLoopAddSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
    CGEventTapEnable(_tap, true);
    os_log(_log, "Attached to Dock");
}

- (void)track:(CGEventType)type event:(CGEventRef)event {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        [self clearExit];
        _generation++;
        if (_tap) CGEventTapEnable(_tap, true);
        return;
    }
    if (type == Exited && _replayTimestamp && CGEventGetTimestamp(event) == _replayTimestamp) return;
    [self clearExit];
    if (type == Exited) {
        _exit = CGEventCreateCopy(event);
        _exitAt = NSProcessInfo.processInfo.systemUptime;
        _exits++;
    }
}

- (void)sessionSuspended:(NSNotification *)note {
    (void)note;
    dispatch_async(dispatch_get_main_queue(), ^{ [self detach]; });
}

- (void)sessionResumed:(NSNotification *)note {
    (void)note;
    dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
}

- (void)spaceChanged:(NSNotification *)note {
    (void)note;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refresh];
        if (!self.listening) return;
        self->_changedAt = now;
        self->_attempts = 0;
        self->_previous = DockUnknown;
        [self schedule:0 generation:++self->_generation];
    });
}

- (BOOL)hasCandidate {
    return _exit && _exitAt >= _changedAt - MaxLead && _exitAt <= _changedAt + MaxLag;
}

- (void)schedule:(NSUInteger)index generation:(NSUInteger)generation {
    if (index >= sizeof(CheckTimes) / sizeof(CheckTimes[0])) return;
    NSTimeInterval wait = MAX(0, _changedAt + CheckTimes[index] - NSProcessInfo.processInfo.systemUptime);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self->_generation != generation || !self.listening) return;
        if (![self hasCandidate]) {
            // Allow a genuine exit arriving just after the space notification.
            if (index == 0) [self schedule:1 generation:generation];
            return;
        }

        pid_t dock = self->_pid;
        pid_t front = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
        NSTimeInterval exitAt = self->_exitAt;
        NSMutableArray<NSValue *> *screens = [NSMutableArray array];
        for (NSScreen *screen in NSScreen.screens) {
            NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
            if (number) [screens addObject:[NSValue valueWithRect:CGDisplayBounds(number.unsignedIntValue)]];
        }
        dispatch_async(self->_inspection, ^{
            CGPoint cursor = CGPointZero;
            DockState state = DockReadState(dock, front, screens, &cursor);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self->_generation != generation || !self.listening || self->_pid != dock) return;
                if (self->_exitAt != exitAt) {
                    self->_previous = DockUnknown;
                    [self schedule:index + 1 generation:generation];
                    return;
                }
                [self evaluate:state cursor:cursor index:index generation:generation];
            });
        });
    });
}

- (void)evaluate:(DockState)state cursor:(CGPoint)cursor index:(NSUInteger)index generation:(NSUInteger)generation {
    if (NSProcessInfo.processInfo.systemUptime - _changedAt > 1.9) return;
    if (state == DockClear) {
        if (_attempts) {
            _repairs++;
            os_log(_log, "Dock cleared after replay");
            [self clearExit];
        }
        return;
    }

    BOOL stuck = state == DockStuckHover || state == DockStuckVisible;
    BOOL confirmed = stuck && (_previous == state ||
        (_previous == DockStuckHover && state == DockStuckVisible));
    _previous = state;
    if (confirmed && _attempts < 2 && index + 1 < sizeof(CheckTimes) / sizeof(CheckTimes[0])) {
        [self replayNear:cursor];
    }
    [self schedule:index + 1 generation:generation];
}

- (void)replayNear:(CGPoint)cursor {
    if (![self hasCandidate] || _pid != DockPID() || !CGPreflightPostEventAccess()) return;
    for (CGMouseButton button = kCGMouseButtonLeft; button <= kCGMouseButtonCenter; button++) {
        if (CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, button)) return;
    }

    CGEventRef pointer = CGEventCreate(NULL);
    if (!pointer) return;
    CGPoint current = CGEventGetLocation(pointer);
    CFRelease(pointer);
    // The worker sampled the pointer before making further AX calls. If the
    // user has since moved, leave Dock alone until the next fresh observation.
    if (fabs(current.x - cursor.x) > 8 || fabs(current.y - cursor.y) > 8) return;

    CGEventRef event = CGEventCreateCopy(_exit);
    if (event) {
        _replayTimestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        CGEventSetTimestamp(event, _replayTimestamp);
        CGEventSetLocation(event, current);
        CGEventPostToPid(_pid, event);
        _attempts++;
        os_log(_log, "Replayed a Dock tracking exit");
        CFRelease(event);
    }
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    [self detach];
}
@end
