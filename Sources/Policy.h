#pragma once
#import <CoreGraphics/CoreGraphics.h>

typedef NS_ENUM(NSInteger, DockState) {
    DockUnknown,
    DockClear,
    DockBusy,
    DockStuckHover,
    DockStuckVisible,
};

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
