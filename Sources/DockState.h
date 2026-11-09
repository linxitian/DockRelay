#pragma once
#import <Foundation/Foundation.h>
#import "Policy.h"

typedef NS_ENUM(NSInteger, DockHoverState) {
    DockHoverNotInspected,
    DockHoverUnknown,
    DockHoverAligned,
    DockHoverUnselected,
    DockHoverMismatch,
};

typedef struct {
    CGRect pointerGuard;
    CGRect hoverFrame;
    CGRect hoverTarget;
    DockHoverState hoverState;
} DockGeometry;

DockState DockReadState(pid_t dock, pid_t front, NSArray<NSValue *> *screens,
                        BOOL inspectHover, DockGeometry *geometry);
