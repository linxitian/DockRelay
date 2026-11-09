#import "DockState.h"
#import <ApplicationServices/ApplicationServices.h>
#import <math.h>

static id AXGet(AXUIElementRef element, CFStringRef attribute) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}

static AXUIElementRef AXElement(id value) {
    if (!value || CFGetTypeID((__bridge CFTypeRef)value) != AXUIElementGetTypeID()) return NULL;
    return (__bridge AXUIElementRef)value;
}

static CGRect AXFrame(AXUIElementRef element) {
    NSArray *attributes = @[(__bridge NSString *)kAXPositionAttribute,
                            (__bridge NSString *)kAXSizeAttribute];
    CFArrayRef values = NULL;
    if (AXUIElementCopyMultipleAttributeValues(element, (__bridge CFArrayRef)attributes,
            kAXCopyMultipleAttributeOptionStopOnError, &values) != kAXErrorSuccess) return CGRectNull;
    NSArray *pair = CFBridgingRelease(values);
    if (pair.count != 2) return CGRectNull;
    AXValueRef position = (__bridge AXValueRef)pair[0];
    AXValueRef size = (__bridge AXValueRef)pair[1];
    CGPoint origin;
    CGSize extent;
    if (CFGetTypeID(position) != AXValueGetTypeID() || CFGetTypeID(size) != AXValueGetTypeID() ||
        !AXValueGetValue(position, kAXValueCGPointType, &origin) ||
        !AXValueGetValue(size, kAXValueCGSizeType, &extent) ||
        !isfinite(origin.x) || !isfinite(origin.y) ||
        !isfinite(extent.width) || !isfinite(extent.height) ||
        extent.width <= 0 || extent.height <= 0) return CGRectNull;
    return (CGRect){ origin, extent };
}

static BOOL ButtonDown(void) {
    for (CGMouseButton button = kCGMouseButtonLeft; button <= kCGMouseButtonCenter; button++) {
        if (CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, button)) return YES;
    }
    return NO;
}

static CGRect FrontFullscreenFrame(pid_t front) {
    if (front <= 0) return CGRectNull;
    __attribute__((objc_precise_lifetime)) id app = CFBridgingRelease(AXUIElementCreateApplication(front));
    __attribute__((objc_precise_lifetime)) id focused = AXGet(AXElement(app), kAXFocusedWindowAttribute);
    AXUIElementRef window = AXElement(focused);
    if (!window || ![AXGet(window, CFSTR("AXFullScreen")) isEqual:@YES]) return CGRectNull;
    return AXFrame(window);
}

DockState DockReadState(pid_t dock, pid_t front, NSArray<NSValue *> *screens, CGRect *pointerGuard) {
    if (screens.count == 0) return DockUnknown;
    if (ButtonDown()) return DockBusy;

    __attribute__((objc_precise_lifetime)) id app = CFBridgingRelease(AXUIElementCreateApplication(dock));
    AXUIElementRef root = AXElement(app);
    __attribute__((objc_precise_lifetime)) id focused = AXGet(root, kAXFocusedUIElementAttribute);
    AXUIElementRef focusedElement = AXElement(focused);
    if (focusedElement) {
        id role = AXGet(focusedElement, kAXRoleAttribute);
        if ([role isEqual:(__bridge NSString *)kAXMenuRole] ||
            [role isEqual:(__bridge NSString *)kAXMenuItemRole]) return DockBusy;
    }

    __attribute__((objc_precise_lifetime)) id children = AXGet(root, kAXChildrenAttribute);
    if (![children isKindOfClass:NSArray.class]) return DockUnknown;
    AXUIElementRef list = NULL;
    for (id child in children) {
        AXUIElementRef element = AXElement(child);
        if (!element) continue;
        id role = AXGet(element, kAXRoleAttribute);
        if ([role isEqual:(__bridge NSString *)kAXMenuRole]) return DockBusy;
        if ([role isEqual:(__bridge NSString *)kAXListRole]) list = element;
    }
    if (!list) return DockUnknown;
    CGRect frame = AXFrame(list);
    if (CGRectIsNull(frame)) return DockUnknown;

    CGEventRef sample = CGEventCreate(NULL);
    if (!sample) return DockUnknown;
    CGPoint cursor = CGEventGetLocation(sample);
    CFRelease(sample);
    *pointerGuard = CGRectInset(frame, -16, -16);
    if (CGRectContainsPoint(*pointerGuard, cursor)) return DockBusy;

    NSUserDefaults *settings = [[NSUserDefaults alloc] initWithSuiteName:@"com.apple.dock"];
    NSString *orientation = [settings stringForKey:@"orientation"];
    DockEdge edge = DockBottom;
    if ([orientation isEqualToString:@"left"]) edge = DockLeft;
    if ([orientation isEqualToString:@"right"]) edge = DockRight;

    BOOL visible = NO;
    for (NSValue *screen in screens) {
        if (DockIsOnScreen(frame, screen.rectValue, edge)) {
            visible = YES;
            break;
        }
    }
    if (!visible) return DockClear;

    id items = AXGet(list, kAXChildrenAttribute);
    if (![items isKindOfClass:NSArray.class]) return DockUnknown;
    BOOL hovered = NO;
    for (id item in items) {
        AXUIElementRef element = AXElement(item);
        if (element && [AXGet(element, kAXSelectedAttribute) isEqual:@YES]) {
            hovered = YES;
            // The magnified item may extend beyond the list's reported frame.
            CGRect itemFrame = AXFrame(element);
            if (!CGRectIsNull(itemFrame)) {
                *pointerGuard = CGRectUnion(*pointerGuard, CGRectInset(itemFrame, -16, -16));
                if (CGRectContainsPoint(*pointerGuard, cursor)) return DockBusy;
            }
        }
    }

    BOOL shouldHide = [settings boolForKey:@"autohide"];
    if (!hovered && !shouldHide && front != dock) {
        CGRect fullScreen = FrontFullscreenFrame(front);
        shouldHide = DockIsOnScreen(frame, fullScreen, edge);
    }
    return DockClassify(visible, NO, ButtonDown(), hovered, shouldHide);
}
