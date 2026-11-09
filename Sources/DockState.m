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

static BOOL IsApplicationItem(AXUIElementRef item) {
    return item && [AXGet(item, kAXSubroleAttribute)
        isEqual:(__bridge NSString *)kAXApplicationDockItemSubrole];
}

static void ReadHoverTarget(AXUIElementRef root, AXUIElementRef list, CGPoint cursor, DockGeometry *geometry) {
    geometry->hoverState = DockHoverUnknown;
    AXUIElementRef hit = NULL;
    AXUIElementCopyElementAtPosition(root, (float)cursor.x, (float)cursor.y, &hit);
    __attribute__((objc_precise_lifetime)) id hitOwner = CFBridgingRelease(hit);
    AXUIElementRef target = AXElement(hitOwner);
    CGRect targetFrame = IsApplicationItem(target) ? AXFrame(target) : CGRectNull;
    __attribute__((objc_precise_lifetime)) id items = AXGet(list, kAXChildrenAttribute);
    if (![items isKindOfClass:NSArray.class]) return;

    if (!CGRectContainsPoint(targetFrame, cursor)) {
        // Some Dock versions do not return individual items in an AX hit test.
        target = NULL;
        for (id item in items) {
            AXUIElementRef element = AXElement(item);
            if (!element) continue;
            CGRect frame = AXFrame(element);
            if (!CGRectContainsPoint(frame, cursor) || !IsApplicationItem(element)) continue;
            if (target) return; // Overlapping targets are ambiguous.
            target = element;
            targetFrame = frame;
        }
    }

    if (!target || !CGRectContainsPoint(CGRectInset(targetFrame, 2, 2), cursor)) return;
    geometry->hoverTarget = targetFrame;
    id selected = AXGet(target, kAXSelectedAttribute);
    if ([selected isEqual:@YES]) {
        geometry->hoverState = DockHoverAligned;
        return;
    }
    if (![selected isEqual:@NO]) return;
    geometry->hoverState = DockHoverUnselected;
    for (id item in items) {
        AXUIElementRef element = AXElement(item);
        if (!element || CFEqual(element, target) ||
            ![AXGet(element, kAXSelectedAttribute) isEqual:@YES] || !IsApplicationItem(element)) continue;
        CGRect previous = AXFrame(element);
        if (!CGRectIsNull(previous) && !CGRectContainsPoint(CGRectInset(previous, -4, -4), cursor)) {
            geometry->hoverState = DockHoverMismatch;
            return;
        }
    }
}

DockState DockReadState(pid_t dock, pid_t front, NSArray<NSValue *> *screens,
                        BOOL inspectHover, DockGeometry *geometry) {
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
    geometry->pointerGuard = CGRectInset(frame, -16, -16);
    if (CGRectContainsPoint(geometry->pointerGuard, cursor)) {
        if (inspectHover) ReadHoverTarget(root, list, cursor, geometry);
        return DockBusy;
    }

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
    BOOL completeHoverFrame = YES;
    for (id item in items) {
        AXUIElementRef element = AXElement(item);
        if (element && [AXGet(element, kAXSelectedAttribute) isEqual:@YES]) {
            hovered = YES;
            // The magnified item may extend beyond the list's reported frame.
            CGRect itemFrame = AXFrame(element);
            if (CGRectIsNull(itemFrame)) {
                completeHoverFrame = NO;
                continue;
            }
            geometry->hoverFrame = CGRectUnion(geometry->hoverFrame, itemFrame);
            geometry->pointerGuard = CGRectUnion(geometry->pointerGuard, CGRectInset(itemFrame, -16, -16));
            if (CGRectContainsPoint(geometry->pointerGuard, cursor)) return DockBusy;
        }
    }

    if (!completeHoverFrame) geometry->hoverFrame = CGRectNull;

    BOOL shouldHide = [settings boolForKey:@"autohide"];
    if (!hovered && !shouldHide && front != dock) {
        CGRect fullScreen = FrontFullscreenFrame(front);
        shouldHide = DockIsOnScreen(frame, fullScreen, edge);
    }
    return DockClassify(visible, NO, ButtonDown(), hovered, shouldHide);
}
