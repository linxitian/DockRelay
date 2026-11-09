#import <Foundation/Foundation.h>
#import <assert.h>
#import "Policy.h"

int main(void) {
    CGRect primary = CGRectMake(0, 0, 1440, 900);
    CGRect above = CGRectMake(0, -900, 1440, 900);
    CGRect below = CGRectMake(0, 900, 1440, 900);
    CGRect left = CGRectMake(-1280, 0, 1280, 900);
    CGRect right = CGRectMake(1440, 0, 1280, 900);

    assert(DockIsOnScreen(CGRectMake(450, 836, 540, 56), primary, DockBottom));
    assert(DockIsOnScreen(CGRectMake(450, -64, 540, 56), above, DockBottom));
    assert(DockIsOnScreen(CGRectMake(-1272, 200, 56, 500), left, DockLeft));
    assert(DockIsOnScreen(CGRectMake(2656, 200, 56, 500), right, DockRight));
    CGRect hiddenBottom = CGRectMake(450, 900, 540, 56);
    assert(!DockIsOnScreen(hiddenBottom, primary, DockBottom));
    assert(!DockIsOnScreen(hiddenBottom, below, DockBottom));
    assert(!DockIsOnScreen(CGRectMake(-56, 200, 56, 500), left, DockLeft));
    assert(!DockIsOnScreen(CGRectMake(1440, 200, 56, 500), right, DockRight));
    assert(!DockIsOnScreen(CGRectMake(450, 836, 540, 56), CGRectNull, DockBottom));

    assert(DockClassify(YES, NO, NO, YES, NO) == DockStuckHover);
    assert(DockClassify(YES, NO, NO, NO, YES) == DockStuckVisible);
    assert(DockClassify(YES, NO, NO, NO, NO) == DockClear);
    assert(DockClassify(NO, NO, NO, YES, YES) == DockClear);
    assert(DockClassify(YES, YES, NO, YES, YES) == DockBusy);
    assert(DockClassify(YES, NO, YES, YES, YES) == DockBusy);
    assert(DockHasReplayEvidence(DockStuckHover, DockUnknown, YES));
    assert(!DockHasReplayEvidence(DockStuckHover, DockUnknown, NO));
    assert(!DockHasReplayEvidence(DockStuckVisible, DockUnknown, YES));
    assert(DockHasReplayEvidence(DockStuckVisible, DockStuckHover, NO));
    assert(!DockHasReplayEvidence(DockBusy, DockStuckHover, YES));
    CGRect dockGuard = CGRectInset(CGRectMake(450, 836, 540, 56), -16, -16);
    assert(DockClassifyExit(dockGuard, CGPointMake(500, 860)) == DockExitInside);
    assert(DockClassifyExit(dockGuard, CGPointMake(500, 840)) == DockExitNearEdge);
    assert(DockClassifyExit(dockGuard, CGPointMake(500, 837)) == DockExitOutside);
    assert(DockClassifyExit(dockGuard, CGPointMake(500, 815)) == DockExitOutside);
    assert(DockClassifyExit(CGRectNull, CGPointZero) == DockExitOutside);
    CGRect hovered = CGRectMake(500, 828, 52, 52);
    assert(DockHoverFrameUnchanged(hovered, hovered));
    assert(DockHoverFrameUnchanged(hovered, CGRectOffset(hovered, 0, 0.25)));
    assert(!DockHoverFrameUnchanged(hovered, CGRectInset(hovered, 1, 1)));
    assert(!DockHoverFrameUnchanged(hovered, CGRectOffset(hovered, 52, 0)));
    assert(!DockHoverFrameUnchanged(hovered, CGRectNull));
    puts("Dock geometry and decision checks passed");
}
