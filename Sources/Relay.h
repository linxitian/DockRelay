#pragma once
#import <AppKit/AppKit.h>

@interface Relay : NSObject
@property(nonatomic, readonly) NSUInteger repairs;
@property(nonatomic, readonly) BOOL listening;
@property(nonatomic, readonly) NSUInteger exits;
- (void)start;
- (void)refresh;
@end
