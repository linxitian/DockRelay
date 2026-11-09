#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ServiceManagement/ServiceManagement.h>
#import "Relay.h"

static NSString *Text(NSString *zh, NSString *en) {
    return [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"] ? zh : en;
}

@interface Controller : NSObject <NSApplicationDelegate, NSMenuDelegate>
@end

@implementation Controller {
    Relay *_relay;
    NSStatusItem *_item;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    _relay = [Relay new];
    [_relay start];
    _item = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    _item.button.image = [NSImage imageWithSystemSymbolName:@"dock.rectangle"
                                  accessibilityDescription:@"DockRelay"];
    if (!_item.button.image) _item.button.title = @"DR";
    _item.button.toolTip = @"DockRelay";
    _item.menu = [NSMenu new];
    _item.menu.delegate = self;
    if (!AXIsProcessTrusted()) [self authorize:nil];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible {
    (void)app;
    (void)visible;
    [_relay refresh];
    if (!AXIsProcessTrusted()) [self authorize:nil];
    else [_item.button performClick:nil];
    return NO;
}

- (void)menuWillOpen:(NSMenu *)menu {
    [_relay refresh];
    [menu removeAllItems];
    BOOL trusted = AXIsProcessTrusted();
    NSString *status = Text(@"等待系统授权", @"Waiting for Accessibility");
    if (trusted) {
        status = _relay.listening && CGPreflightPostEventAccess()
            ? Text(@"正在监听 Dock", @"Watching Dock")
            : Text(@"事件权限未就绪", @"Event access unavailable");
    }
    [menu addItemWithTitle:status action:NULL keyEquivalent:@""];
    NSString *counts = [NSString stringWithFormat:
        Text(@"收到离开事件 %lu · 观察到恢复 %lu", @"Exits %lu · Recoveries %lu"),
        (unsigned long)_relay.exits, (unsigned long)_relay.repairs];
    [menu addItemWithTitle:counts action:NULL keyEquivalent:@""];
    if (!trusted || !CGPreflightPostEventAccess()) {
        [self add:Text(@"设备控制权限…", @"Allow Accessibility…") action:@selector(authorize:) menu:menu];
    }
    if (trusted && !_relay.listening && !CGPreflightListenEventAccess()) {
        [self add:Text(@"输入监控授权…", @"Allow Input Monitoring…") action:@selector(allowListening:) menu:menu];
    }
    [menu addItem:NSMenuItem.separatorItem];

    SMAppServiceStatus login = SMAppService.mainAppService.status;
    if (login == SMAppServiceStatusRequiresApproval) {
        [self add:Text(@"打开登录项设置…", @"Open Login Items…") action:@selector(openLogin:) menu:menu];
    }
    NSMenuItem *item = [self add:Text(@"登录时启动", @"Launch at Login")
                          action:@selector(toggleLogin:) menu:menu];
    item.state = login == SMAppServiceStatusEnabled || login == SMAppServiceStatusRequiresApproval
        ? NSControlStateValueOn : NSControlStateValueOff;
    [self add:Text(@"退出 DockRelay", @"Quit DockRelay") action:@selector(quit:) menu:menu];
}

- (NSMenuItem *)add:(NSString *)title action:(SEL)action menu:(NSMenu *)menu {
    NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    return item;
}

- (void)authorize:(id)sender {
    (void)sender;
    if (!AXIsProcessTrusted()) {
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{
            (__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES
        });
    } else {
        CGRequestPostEventAccess();
    }
}

- (void)allowListening:(id)sender {
    (void)sender;
    CGRequestListenEventAccess();
}

- (void)openLogin:(id)sender {
    (void)sender;
    [SMAppService openSystemSettingsLoginItems];
}

- (void)toggleLogin:(id)sender {
    (void)sender;
    SMAppService *service = SMAppService.mainAppService;
    NSError *error = nil;
    BOOL registered = service.status == SMAppServiceStatusEnabled ||
        service.status == SMAppServiceStatusRequiresApproval;
    BOOL success = registered ? [service unregisterAndReturnError:&error] : [service registerAndReturnError:&error];
    if (service.status == SMAppServiceStatusRequiresApproval) {
        [SMAppService openSystemSettingsLoginItems];
    } else if (!success) {
        NSAlert *alert = [NSAlert alertWithError:error];
        [NSApp activateIgnoringOtherApps:YES];
        [alert runModal];
    }
}

- (void)quit:(id)sender {
    [NSApp terminate:sender];
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        __attribute__((objc_precise_lifetime)) Controller *controller = [Controller new];
        app.delegate = controller;
        [app run];
    }
    return 0;
}
