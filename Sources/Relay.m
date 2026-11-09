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
// Check close together while the animation is settling, then back off.
static const double CheckTimes[] = {0, 0.038, 0.075, 0.125, 0.18, 0.25, 0.325, 0.485, 0.695, 1.0, 1.35, 1.65};
static const double ExitCheckTimes[] = {0.02, 0.05, 0.09, 0.14, 0.20, 0.245};
// Dock can still report its hover state during the shrink animation.
static const double ReplayIntervals[] = {0, 0.185, 0.235, 0.30};
static const double StationaryHoverRetry = 0.070;

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
    NSTimeInterval _replayedAt;
    CGRect _firstHoverFrame;
    NSUInteger _unchangedHoverChecks;
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
    _attempts = 0;
    _replayedAt = 0;
    _firstHoverFrame = CGRectNull;
    _unchangedHoverChecks = 0;
    _previous = DockUnknown;
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
        if (_exit) [self checkEarly:0 generation:_generation exitAt:_exitAt previous:DockUnknown];
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
        self->_previous = DockUnknown;
        self->_firstHoverFrame = CGRectNull;
        self->_unchangedHoverChecks = 0;
        [self schedule:0 generation:++self->_generation soonerAt:0];
    });
}

- (BOOL)hasCandidate {
    return _exit && _exitAt >= _changedAt - MaxLead && _exitAt <= _changedAt + MaxLag;
}

- (void)schedule:(NSUInteger)index generation:(NSUInteger)generation soonerAt:(NSTimeInterval)sooner {
    if (index >= sizeof(CheckTimes) / sizeof(CheckTimes[0])) return;
    NSTimeInterval due = _changedAt + CheckTimes[index];
    if (sooner > 0) due = MIN(due, sooner);
    NSTimeInterval wait = MAX(0, due - NSProcessInfo.processInfo.systemUptime);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self->_generation != generation || !self.listening) return;
        if (![self hasCandidate]) {
            // Allow a genuine exit arriving just after the space notification.
            if (CheckTimes[index] <= MaxLag) [self schedule:index + 1 generation:generation soonerAt:0];
            return;
        }

        [self inspect:generation completion:^(DockState state, DockGeometry geometry) {
            [self evaluate:state geometry:geometry index:index generation:generation];
        }];
    });
}

- (void)checkEarly:(NSUInteger)index generation:(NSUInteger)generation
               exitAt:(NSTimeInterval)exitAt previous:(DockState)previous {
    if (index >= sizeof(ExitCheckTimes) / sizeof(ExitCheckTimes[0])) return;
    NSTimeInterval wait = MAX(0, exitAt + ExitCheckTimes[index] - NSProcessInfo.processInfo.systemUptime);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self->_generation != generation || self->_exitAt != exitAt || !self.listening ||
            self->_attempts || [self hasCandidate]) return;
        [self inspect:generation completion:^(DockState state, DockGeometry geometry) {
            CGRect pointerGuard = geometry.pointerGuard;
            NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
            if (self->_exitAt != exitAt || !self->_exit || now - exitAt > 0.27) return;
            if (state == DockUnknown) {
                // Dock's accessibility tree can briefly be unavailable during a switch.
                if (index < 2) {
                    [self checkEarly:index + 1 generation:generation exitAt:exitAt previous:state];
                }
                return;
            }

            DockExitOrigin origin = DockClassifyExit(pointerGuard, CGEventGetLocation(self->_exit));
            if (origin == DockExitOutside) return;
            BOOL confirmed = state == DockStuckHover &&
                (origin == DockExitInside || previous == DockStuckHover);
            if (confirmed && [self replayOutside:pointerGuard at:now early:YES]) return;
            if (state == DockBusy || state == DockStuckHover || (state == DockClear && index < 2)) {
                [self checkEarly:index + 1 generation:generation exitAt:exitAt previous:state];
            }
        }];
    });
}

- (void)inspect:(NSUInteger)generation completion:(void (^)(DockState, DockGeometry))completion {
    pid_t dock = _pid;
    pid_t front = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    NSTimeInterval exitAt = _exitAt;
    NSMutableArray<NSValue *> *screens = [NSMutableArray array];
    for (NSScreen *screen in NSScreen.screens) {
        NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
        if (number) [screens addObject:[NSValue valueWithRect:CGDisplayBounds(number.unsignedIntValue)]];
    }
    dispatch_async(_inspection, ^{
        DockGeometry geometry = { CGRectNull, CGRectNull };
        DockState state = DockReadState(dock, front, screens, &geometry);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_generation != generation || !self.listening || self->_pid != dock) return;
            if (self->_exitAt != exitAt) {
                completion(DockUnknown, (DockGeometry){ CGRectNull, CGRectNull });
                return;
            }
            completion(state, geometry);
        });
    });
}

- (void)evaluate:(DockState)state geometry:(DockGeometry)geometry
           index:(NSUInteger)index generation:(NSUInteger)generation {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    double elapsed = now - _changedAt;
    if (elapsed > 1.9) return;
    if (state == DockClear) {
        if (_attempts) {
            _repairs++;
            os_log(_log, "Dock cleared; space=%{public}ld ms since exit=%{public}ld ms since replay=%{public}ld ms attempts=%{public}lu",
                   lround(elapsed * 1000), lround((now - _exitAt) * 1000),
                   lround((now - _replayedAt) * 1000), (unsigned long)_attempts);
            [self clearExit];
        } else if (CheckTimes[index] < 0.12) {
            // An early snapshot may see Dock before the Space animation has settled.
            _previous = DockClear;
            [self schedule:index + 1 generation:generation soonerAt:0];
        }
        return;
    }

    // An exit recorded over Dock near the switch is characteristic of this bug.
    // With a stale selected item, that is enough evidence for the first replay.
    BOOL exitFromDock = [self hasCandidate] && fabs(_exitAt - _changedAt) <= 0.4 &&
        CGRectContainsPoint(geometry.pointerGuard, CGEventGetLocation(_exit));
    BOOL confirmed = DockHasReplayEvidence(state, _previous, exitFromDock);
    _previous = state;
    // If the first replay followed the Space notification, look for a change
    // before waiting out the full animation interval. Any motion or uncertain
    // observation disables the shorter retry for this exit.
    if (_attempts == 1 && !CGRectIsNull(_firstHoverFrame)) {
        if (state == DockStuckHover && DockHoverFrameUnchanged(_firstHoverFrame, geometry.hoverFrame)) {
            _unchangedHoverChecks++;
        } else {
            _firstHoverFrame = CGRectNull;
            _unchangedHoverChecks = 0;
        }
    }

    NSTimeInterval retryAt = 0;
    if (confirmed && _attempts < sizeof(ReplayIntervals) / sizeof(ReplayIntervals[0]) &&
        index + 1 < sizeof(CheckTimes) / sizeof(CheckTimes[0])) {
        BOOL stalledHover = _attempts == 1 && _unchangedHoverChecks >= 2;
        NSTimeInterval interval = stalledHover ? StationaryHoverRetry : ReplayIntervals[_attempts];
        NSTimeInterval earliest = _replayedAt + interval;
        if (now >= earliest) {
            BOOL firstReplay = _attempts == 0;
            NSTimeInterval lastReplay = _replayedAt;
            if ([self replayOutside:geometry.pointerGuard at:now early:NO]) {
                if (firstReplay && state == DockStuckHover) _firstHoverFrame = geometry.hoverFrame;
                if (stalledHover) {
                    os_log(_log, "Retried stationary Dock hover; after first replay=%{public}ld ms",
                           lround((now - lastReplay) * 1000));
                }
            }
        } else {
            // Observe again at the retry deadline if the next planned check is later.
            retryAt = earliest;
        }
    }
    [self schedule:index + 1 generation:generation soonerAt:retryAt];
}

- (BOOL)replayOutside:(CGRect)pointerGuard at:(NSTimeInterval)now early:(BOOL)early {
    if (CGRectIsNull(pointerGuard) || !_exit || (!early && ![self hasCandidate]) ||
        _pid != DockPID() || !CGPreflightPostEventAccess()) return NO;
    for (CGMouseButton button = kCGMouseButtonLeft; button <= kCGMouseButtonCenter; button++) {
        if (CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, button)) return NO;
    }

    CGEventRef pointer = CGEventCreate(NULL);
    if (!pointer) return NO;
    CGPoint current = CGEventGetLocation(pointer);
    CFRelease(pointer);
    // The user can keep moving as long as the current pointer is outside Dock.
    if (CGRectContainsPoint(pointerGuard, current)) return NO;

    CGEventRef event = CGEventCreateCopy(_exit);
    if (!event) return NO;
    _replayTimestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    CGEventSetTimestamp(event, _replayTimestamp);
    CGEventSetLocation(event, current);
    CGEventPostToPid(_pid, event);
    CFRelease(event);
    _replayedAt = now;
    _attempts++;
    if (early) {
        os_log(_log, "Replayed Dock exit before Space; since exit=%{public}ld ms",
               lround((now - _exitAt) * 1000));
    } else {
        os_log(_log, "Replayed Dock exit; space=%{public}ld ms since exit=%{public}ld ms attempt=%{public}lu",
               lround((now - _changedAt) * 1000), lround((now - _exitAt) * 1000),
               (unsigned long)_attempts);
    }
    return YES;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    [self detach];
}
@end
