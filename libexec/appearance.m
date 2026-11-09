// appearance.m — set macOS accent, text highlight and icon tint the way
// System Settings does, so running apps / Dock / widgets update live.
//
//   appearance [--dark] [--accent N] [--highlight "r g b"] [--tint "r g b a"]
//   appearance --read
//
// `defaults write` alone only changes the stored value: nothing is told.
// Icon tint goes through SkyLight's SLSIconAppearanceConfiguration (what the
// Appearance pane uses; -save broadcasts the change to the window server).
// Accent/highlight are written to the global domain, then the same distributed
// notifications the Appearance pane posts are sent. --dark switches to Dark
// (not Auto) through SkyLight too: live, and no Automation prompt like
// System Events' "set dark mode".
//
// Built on demand by shiny-apply with: clang -fobjc-arc -framework Foundation
//   -framework CoreGraphics appearance.m -o appearance
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>

@interface SLSIconAppearanceConfiguration : NSObject
+ (instancetype)fetchCurrentIconAppearanceConfiguration;
- (unsigned)iconAppearanceTheme;
- (unsigned)iconTintColorName;
- (void)setIconTintColorName:(unsigned)name;
- (CGColorRef)otherIconTintColor;
- (void)setOtherIconTintColor:(CGColorRef)color;
- (void)save;
@end

static const unsigned kTintOther = 10;   // "Other" (custom colour), observed on macOS 27

static void setGlobal(NSString *key, id value) {
  CFPreferencesSetValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value,
                        kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
}

static void post(NSString *name) {
  [[NSDistributedNotificationCenter defaultCenter] postNotificationName:name object:nil
                                                               userInfo:nil deliverImmediately:YES];
}

static NSArray<NSNumber *> *floats(const char *s, NSUInteger want) {
  NSMutableArray *out = [NSMutableArray array];
  for (NSString *p in [@(s) componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet])
    if (p.length) [out addObject:@(p.doubleValue)];
  if (out.count != want) { fprintf(stderr, "appearance: expected %lu numbers in \"%s\"\n", want, s); exit(2); }
  return out;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (!dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)) {
      fprintf(stderr, "appearance: couldn't load SkyLight\n"); return 1;
    }
    Class cfg = NSClassFromString(@"SLSIconAppearanceConfiguration");
    BOOL colours = NO;
    for (int i = 1; i < argc; i++) {
      NSString *a = @(argv[i]);
      if ([a isEqual:@"--read"]) {
        SLSIconAppearanceConfiguration *c = [cfg fetchCurrentIconAppearanceConfiguration];
        printf("icon style %u, tint %u", [c iconAppearanceTheme], [c iconTintColorName]);
        CGColorRef col = [c otherIconTintColor];
        if (col) { const CGFloat *k = CGColorGetComponents(col);
          for (size_t j = 0; j < CGColorGetNumberOfComponents(col); j++) printf(" %.4f", k[j]); }
        printf("\n"); continue;
      }
      if ([a isEqual:@"--dark"]) {
        void (*autoSwitch)(BOOL) = dlsym(RTLD_DEFAULT, "SLSSetAppearanceThemeSwitchesAutomatically");
        void (*setDark)(BOOL) = dlsym(RTLD_DEFAULT, "SLSSetAppearanceThemeLegacy");
        if (!setDark) { fprintf(stderr, "appearance: no SLSSetAppearanceThemeLegacy\n"); return 1; }
        if (autoSwitch) autoSwitch(NO);
        setDark(YES);
        continue;
      }
      if (i + 1 >= argc) { fprintf(stderr, "appearance: %s needs a value\n", argv[i]); return 2; }
      const char *v = argv[++i];
      if ([a isEqual:@"--accent"]) {
        int n = atoi(v);
        setGlobal(@"AppleAccentColor", n == 99 ? nil : @(n));   // 99 = multicolour (key removed)
        colours = YES;
      } else if ([a isEqual:@"--highlight"]) {
        NSArray *f = floats(v, 3);
        setGlobal(@"AppleHighlightColor", [NSString stringWithFormat:@"%.6f %.6f %.6f Other",
                   [f[0] doubleValue], [f[1] doubleValue], [f[2] doubleValue]]);
        colours = YES;
      } else if ([a isEqual:@"--tint"]) {
        NSArray *f = floats(v, 4);
        CGColorRef col = CGColorCreateSRGB([f[0] doubleValue], [f[1] doubleValue], [f[2] doubleValue], [f[3] doubleValue]);
        SLSIconAppearanceConfiguration *c = [cfg fetchCurrentIconAppearanceConfiguration];
        if (!c) { fprintf(stderr, "appearance: no icon appearance configuration\n"); return 1; }
        [c setIconTintColorName:kTintOther];
        [c setOtherIconTintColor:col];
        [c save];
        CGColorRelease(col);
      } else {
        fprintf(stderr, "appearance: unknown option %s\n", argv[i]); return 2;
      }
    }
    if (colours) {
      CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
      post(@"AppleAquaColorVariantChanged");
      post(@"AppleColorPreferencesChangedNotification");
    }
  }
  return 0;
}
