// curtain.m — black "loading" overlay on every display while a theme applies,
// so the Dock/Finder/widget restarts and app relaunches happen out of sight.
//
//   curtain [--ready FILE] [--status FILE] [--timeout SECS]
//
// --status FILE: a one-line message shown under the spinner, re-read every
// 150ms (shiny-apply writes what it's doing there).
//
// Fades in, then creates FILE (if given) once the screen is fully black.
// SIGTERM / SIGINT fades out and exits. A click dismisses it early (it never
// takes focus, so whatever you were in stays frontmost), and
// it gives up on its own after --timeout (default 90s) so it can't get stuck.
//
// Built on demand by shiny-apply with: clang -fobjc-arc -framework AppKit
//   -framework QuartzCore curtain.m -o curtain
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <signal.h>

static const NSTimeInterval kFadeIn = 0.35, kFadeOut = 0.5;

@interface CurtainWindow : NSWindow
@end
@implementation CurtainWindow
- (void)sendEvent:(NSEvent *)e {   // any click dismisses, even the one that would activate us
  if (e.type == NSEventTypeLeftMouseDown || e.type == NSEventTypeRightMouseDown) [NSApp terminate:nil];
  else [super sendEvent:e];
}
@end

@interface Curtain : NSObject <NSApplicationDelegate>
@property NSMutableArray<NSWindow *> *windows;
@property NSString *readyFile;
@property NSString *statusFile;
@property NSString *lastStatus;
@property NSMutableArray<NSTextField *> *labels;
@property NSTimeInterval timeout;
@property BOOL closing;
@end

@implementation Curtain
- (NSWindow *)windowForScreen:(NSScreen *)screen {
  CurtainWindow *w = [[CurtainWindow alloc] initWithContentRect:screen.frame
                                                      styleMask:NSWindowStyleMaskBorderless
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
  w.level = CGShieldingWindowLevel();   // above the menu bar, Dock and everything else
  w.backgroundColor = NSColor.blackColor;
  w.opaque = NO;
  w.hasShadow = NO;
  w.alphaValue = 0;
  w.releasedWhenClosed = NO;
  w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                         NSWindowCollectionBehaviorStationary |
                         NSWindowCollectionBehaviorFullScreenAuxiliary |
                         NSWindowCollectionBehaviorIgnoresCycle;
  [w setFrame:screen.frame display:NO];

  NSView *content = w.contentView;
  content.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

  NSProgressIndicator *spin = [NSProgressIndicator new];
  spin.style = NSProgressIndicatorStyleSpinning;
  spin.controlSize = NSControlSizeSmall;
  spin.translatesAutoresizingMaskIntoConstraints = NO;
  [spin startAnimation:nil];

  NSTextField *label = [NSTextField labelWithString:@""];
  label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
  label.textColor = [NSColor colorWithWhite:1 alpha:0.55];
  label.alignment = NSTextAlignmentCenter;
  label.translatesAutoresizingMaskIntoConstraints = NO;
  [self.labels addObject:label];

  [content addSubview:spin];
  [content addSubview:label];
  [NSLayoutConstraint activateConstraints:@[
    [spin.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
    [spin.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
    [label.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
    [label.topAnchor constraintEqualToAnchor:spin.bottomAnchor constant:14],
  ]];
  return w;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
  self.windows = [NSMutableArray array];
  self.labels = [NSMutableArray array];
  for (NSScreen *s in NSScreen.screens) {
    NSWindow *w = [self windowForScreen:s];
    [w orderFrontRegardless];
    [self.windows addObject:w];
  }

  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
    ctx.duration = kFadeIn;
    ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    for (NSWindow *w in self.windows) w.animator.alphaValue = 1;
  } completionHandler:^{
    if (self.readyFile) [[NSFileManager defaultManager] createFileAtPath:self.readyFile contents:nil attributes:nil];
  }];

  if (self.statusFile) {
    [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer *t) { [self refreshStatus]; }];
    [self refreshStatus];
  }

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.timeout * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{ [self lift]; });
}

- (void)refreshStatus {
  NSString *text = [NSString stringWithContentsOfFile:self.statusFile encoding:NSUTF8StringEncoding error:nil];
  text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
  if ([text isEqualToString:self.lastStatus ?: @""]) return;
  self.lastStatus = text;
  for (NSTextField *l in self.labels) l.stringValue = text;
}

- (void)lift {
  if (self.closing) return;
  self.closing = YES;
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
    ctx.duration = kFadeOut;
    ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    for (NSWindow *w in self.windows) w.animator.alphaValue = 0;
  } completionHandler:^{ exit(0); }];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app {
  [self lift];   // click: fade out instead of vanishing
  return NSTerminateCancel;
}
@end

static dispatch_source_t onSignal(int sig, Curtain *c) {
  signal(sig, SIG_IGN);
  dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, sig, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(src, ^{ [c lift]; });
  dispatch_resume(src);
  return src;
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    Curtain *c = [Curtain new];
    c.timeout = 90;
    for (int i = 1; i + 1 < argc; i += 2) {
      NSString *k = @(argv[i]), *v = @(argv[i + 1]);
      if ([k isEqualToString:@"--ready"]) c.readyFile = v;
      else if ([k isEqualToString:@"--status"]) c.statusFile = v;
      else if ([k isEqualToString:@"--timeout"]) c.timeout = MAX(1, v.doubleValue);
    }
    NSApplication *app = [NSApplication sharedApplication];
    app.activationPolicy = NSApplicationActivationPolicyAccessory;   // no Dock icon
    app.delegate = c;
    dispatch_source_t term = onSignal(SIGTERM, c), intr = onSignal(SIGINT, c);
    (void)term; (void)intr;
    [app run];
  }
  return 0;
}
