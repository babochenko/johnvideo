// johnvideo — entry point (Objective-C++)
#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        AppDelegate *delegate = [[AppDelegate alloc] init];
        [app setDelegate:delegate];

        // Minimal menu so Cmd+Q works without a nib.
        NSMenu *menubar = [[NSMenu alloc] init];
        NSMenuItem *appItem = [[NSMenuItem alloc] init];
        [menubar addItem:appItem];
        NSMenu *appMenu = [[NSMenu alloc] init];
        [appMenu addItemWithTitle:@"Quit johnvideo"
                           action:@selector(terminate:)
                    keyEquivalent:@"q"];
        [appItem setSubmenu:appMenu];

        // File menu: Open / Save project (routes to AppDelegate via the chain).
        NSMenuItem *fileItem = [[NSMenuItem alloc] init];
        [menubar addItem:fileItem];
        NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
        [fileMenu addItemWithTitle:@"Open Project…" action:@selector(openProject:) keyEquivalent:@"o"];
        [fileMenu addItemWithTitle:@"Save Project…" action:@selector(saveProject:) keyEquivalent:@"s"];
        [fileItem setSubmenu:fileMenu];

        // Edit menu so Cmd+V routes paste: down the responder chain to the
        // focused view (preview or timeline).
        NSMenuItem *editItem = [[NSMenuItem alloc] init];
        [menubar addItem:editItem];
        NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
        [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
        [editItem setSubmenu:editMenu];

        [app setMainMenu:menubar];

        [app run];
    }
    return 0;
}
