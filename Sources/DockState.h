#pragma once
#import <Foundation/Foundation.h>
#import "Policy.h"

DockState DockReadState(pid_t dock, pid_t front, NSArray<NSValue *> *screens, CGPoint *cursor);
