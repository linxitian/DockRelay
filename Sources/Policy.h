#pragma once
#import <CoreGraphics/CoreGraphics.h>

typedef NS_ENUM(NSInteger, DockState) {
    DockUnknown,
    DockClear,
    DockBusy,
    DockStuckHover,
    DockStuckVisible,
};

static inline BOOL DockHasReplayEvidence(DockState state, DockState previous, BOOL exitFromDock) {
    if (state == DockStuckHover) return exitFromDock || previous == DockStuckHover;
    if (state == DockStuckVisible) return previous == DockStuckHover || previous == DockStuckVisible;
    return NO;
}

static inline BOOL DockHoverFrameUnchanged(CGRect before, CGRect after) {
    if (CGRectIsNull(before) || CGRectIsNull(after)) return NO;
    const CGFloat tolerance = 0.75;
    return fabs(CGRectGetMinX(before) - CGRectGetMinX(after)) < tolerance &&
        fabs(CGRectGetMinY(before) - CGRectGetMinY(after)) < tolerance &&
        fabs(CGRectGetWidth(before) - CGRectGetWidth(after)) < tolerance &&
        fabs(CGRectGetHeight(before) - CGRectGetHeight(after)) < tolerance;
}

static inline BOOL DockIsHoverTransfer(CGRect origin, CGRect target, CGPoint exit, CGPoint pointer) {
    if (CGRectIsNull(origin) || CGRectIsNull(target)) return NO;
    return CGRectContainsPoint(origin, exit) &&
        !CGRectContainsPoint(target, exit) &&
        !CGRectContainsPoint(CGRectInset(origin, -4, -4), pointer) &&
        CGRectContainsPoint(CGRectInset(target, 2, 2), pointer);
}

typedef NS_ENUM(NSInteger, DockExitOrigin) {
    DockExitOutside,
    DockExitNearEdge,
    DockExitInside,
};

static inline DockExitOrigin DockClassifyExit(CGRect pointerGuard, CGPoint point) {
    // The observation pads the actual Dock and selected item by 16 points.
    // Leave a margin inside the frame so ordinary boundary exits never qualify.
    if (CGRectIsNull(pointerGuard) || CGRectGetWidth(pointerGuard) <= 36 ||
        CGRectGetHeight(pointerGuard) <= 36 ||
        !CGRectContainsPoint(CGRectInset(pointerGuard, 18, 18), point)) return DockExitOutside;
    if (CGRectGetWidth(pointerGuard) > 48 && CGRectGetHeight(pointerGuard) > 48 &&
        CGRectContainsPoint(CGRectInset(pointerGuard, 24, 24), point)) return DockExitInside;
    return DockExitNearEdge;
}

typedef NS_ENUM(NSInteger, DockEdge) {
    DockBottom,
    DockLeft,
    DockRight,
};

static inline BOOL DockIsOnScreen(CGRect frame, CGRect screen, DockEdge edge) {
    if (CGRectIsNull(screen)) return NO;
    CGRect overlap = CGRectIntersection(frame, screen);
    if (CGRectIsNull(overlap) ||
        CGRectGetWidth(overlap) <= 2 || CGRectGetHeight(overlap) <= 2) return NO;

    // An auto-hidden Dock can be parked inside a neighboring display's bounds.
    // Its outer edge must also be near that display's corresponding edge.
    const CGFloat inset = 48;
    switch (edge) {
        case DockLeft: return fabs(CGRectGetMinX(frame) - CGRectGetMinX(screen)) <= inset;
        case DockRight: return fabs(CGRectGetMaxX(frame) - CGRectGetMaxX(screen)) <= inset;
        case DockBottom: return fabs(CGRectGetMaxY(frame) - CGRectGetMaxY(screen)) <= inset;
    }
    return NO;
}

static inline DockState DockClassify(BOOL visible, BOOL pointerNear, BOOL interacting,
                                     BOOL hovered, BOOL shouldHide) {
    if (pointerNear || interacting) return DockBusy;
    if (!visible) return DockClear;
    if (hovered) return DockStuckHover;
    return shouldHide ? DockStuckVisible : DockClear;
}
