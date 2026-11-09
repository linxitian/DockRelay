#pragma once
#import <Foundation/Foundation.h>
#import "Policy.h"

typedef struct {
    CGRect pointerGuard;
    CGRect hoverFrame;
} DockGeometry;

DockState DockReadState(pid_t dock, pid_t front, NSArray<NSValue *> *screens, DockGeometry *geometry);
