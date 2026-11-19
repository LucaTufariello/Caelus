// main.mm — application entry point and menu bar.

#import <Cocoa/Cocoa.h>

#import "AppController.h"

@interface CaelusAppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) AppController* controller;
@property(nonatomic, strong) NSWindow* window;
@end

@implementation CaelusAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    NSWindow* window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 1320, 860)
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    [window center];
    window.title = @"Caelus";
    window.tabbingMode = NSWindowTabbingModeDisallowed;
    self.window = window;

    self.controller = [[AppController alloc] init];
    [self.controller installInWindow:window];
    [NSApp setMainMenu:[self buildMenu]];

    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    [self.controller captureSnapshotIfRequested];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    return YES;
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication*)app {
    return YES;
}

- (NSMenu*)buildMenu {
    NSMenu* mainMenu = [[NSMenu alloc] init];

    // Application menu.
    NSMenuItem* appItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:appItem];
    NSMenu* appMenu = [[NSMenu alloc] init];
    NSString* appName = @"Caelus";
    [appMenu addItemWithTitle:[NSString stringWithFormat:@"About %@", appName]
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem* hide = [appMenu addItemWithTitle:[NSString stringWithFormat:@"Hide %@", appName]
                                          action:@selector(hide:)
                                   keyEquivalent:@"h"];
    hide.target = NSApp;
    NSMenuItem* quit = [appMenu addItemWithTitle:[NSString stringWithFormat:@"Quit %@", appName]
                                          action:@selector(terminate:)
                                   keyEquivalent:@"q"];
    quit.target = NSApp;
    appItem.submenu = appMenu;

    // File.
    NSMenuItem* fileItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:fileItem];
    NSMenu* fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    NSMenuItem* save = [fileMenu addItemWithTitle:@"Save Image…"
                                           action:@selector(saveImage:)
                                    keyEquivalent:@"S"];
    save.target = self.controller;
    NSMenuItem* refresh = [fileMenu addItemWithTitle:@"Refresh Catalog"
                                              action:@selector(refreshCatalog:)
                                       keyEquivalent:@"r"];
    refresh.target = self.controller;
    NSMenuItem* settings = [fileMenu addItemWithTitle:@"Settings…"
                                               action:@selector(showSettings:)
                                        keyEquivalent:@","];
    settings.target = self.controller;
    fileItem.submenu = fileMenu;

    // Edit.
    NSMenuItem* editItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:editItem];
    NSMenu* editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    NSMenuItem* find = [editMenu addItemWithTitle:@"Find Satellite"
                                           action:@selector(focusSearch:)
                                    keyEquivalent:@"f"];
    find.target = self.controller;
    NSMenuItem* favorite = [editMenu addItemWithTitle:@"Toggle Favourite"
                                               action:@selector(toggleFavoriteSelection:)
                                        keyEquivalent:@"d"];
    favorite.target = self.controller;
    NSMenuItem* clear = [editMenu addItemWithTitle:@"Clear Selection"
                                            action:@selector(clearSelection:)
                                     keyEquivalent:@"\e"];
    clear.target = self.controller;
    editItem.submenu = editMenu;

    // View.
    NSMenuItem* viewItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:viewItem];
    NSMenu* viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    NSMenuItem* reset = [viewMenu addItemWithTitle:@"Reset Camera"
                                            action:@selector(resetCamera:)
                                     keyEquivalent:@"0"];
    reset.target = self.controller;
    [viewMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem* orbit = [viewMenu addItemWithTitle:@"Show Orbit Path"
                                            action:@selector(toggleOrbitPath:)
                                     keyEquivalent:@"o"];
    orbit.keyEquivalentModifierMask = NSEventModifierFlagOption | NSEventModifierFlagCommand;
    orbit.target = self.controller;

    NSMenuItem* ground = [viewMenu addItemWithTitle:@"Show Ground Track"
                                             action:@selector(toggleGroundTrack:)
                                      keyEquivalent:@"g"];
    ground.keyEquivalentModifierMask = NSEventModifierFlagOption | NSEventModifierFlagCommand;
    ground.target = self.controller;

    NSMenuItem* station = [viewMenu addItemWithTitle:@"Show Ground Station"
                                              action:@selector(toggleObserver:)
                                       keyEquivalent:@"g"];
    station.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand;
    station.target = self.controller;

    [viewMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem* groups = [viewMenu addItemWithTitle:@"Toggle All Groups"
                                             action:@selector(toggleAllGroups:)
                                      keyEquivalent:@"A"];
    groups.keyEquivalentModifierMask = NSEventModifierFlagShift | NSEventModifierFlagCommand;
    groups.target = self.controller;
    viewItem.submenu = viewMenu;

    // Window.
    NSMenuItem* windowItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:windowItem];
    NSMenu* windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItemWithTitle:@"Minimize"
                          action:@selector(performMiniaturize:)
                   keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Zoom"
                          action:@selector(performZoom:)
                   keyEquivalent:@""];
    windowItem.submenu = windowMenu;
    [NSApp setWindowsMenu:windowMenu];

    return mainMenu;
}

@end

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSApplication* application = [NSApplication sharedApplication];
        application.activationPolicy = NSApplicationActivationPolicyRegular;

        CaelusAppDelegate* delegate = [[CaelusAppDelegate alloc] init];
        application.delegate = delegate;

        [application run];
    }
    return 0;
}
