#import "LauncherPreferences.h"
#import "SceneExternalDelegate.h"
#import "SurfaceViewController.h"
#import "utils.h"

// Tag of the "shown on the external display" note placed over the iPad's touch area
static const NSInteger AMExternalNoteTag = 0xA1E7;

// The external display's scene, only when it is a separate screen from both the iPad's own display
// and the screen the app window is on. With Stage Manager the app window itself can be on the monitor;
// iPadOS then hands the external-display scene the iPad's built-in screen, which must not be used.
static UIWindowScene *AMExternalScene(void) {
    UIScreen *appScreen = UIWindow.mainWindow.windowScene.screen;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.session.role == UIWindowSceneSessionRoleApplication) continue;
        UIScreen *screen = ((UIWindowScene *)scene).screen;
        if (screen == nil || screen == UIScreen.mainScreen || screen == appScreen) continue;
        return (UIWindowScene *)scene;
    }
    return nil;
}

UIScreen *AMExternalScreen(void) {
    return AMExternalScene().screen;
}

static NSString *AMModeKey(UIScreenMode *mode) {
    return [NSString stringWithFormat:@"%dx%d", (int)mode.size.width, (int)mode.size.height];
}

NSString *AMExternalDisplayModeTitle(NSString *key) {
    if (key.length == 0 || [key isEqualToString:@"auto"]) {
        return localize(@"preference.title.external_mode-auto", nil);
    }
    return [key stringByReplacingOccurrencesOfString:@"x" withString:@" × "];
}

NSArray<NSArray<NSString *> *> *AMExternalDisplayModeChoices(void) {
    NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithObject:@"auto"];
    NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithObject:AMExternalDisplayModeTitle(@"auto")];
    UIScreen *screen = AMExternalScreen();
    // Largest first; iOS can list the same size more than once (different pixel aspect ratios)
    NSArray<UIScreenMode *> *modes = [screen.availableModes sortedArrayUsingComparator:^NSComparisonResult(UIScreenMode *a, UIScreenMode *b) {
        CGFloat areaA = a.size.width * a.size.height, areaB = b.size.width * b.size.height;
        return areaA > areaB ? NSOrderedAscending : (areaA < areaB ? NSOrderedDescending : NSOrderedSame);
    }];
    for (UIScreenMode *mode in modes) {
        NSString *key = AMModeKey(mode);
        if ([keys containsObject:key]) continue;
        [keys addObject:key];
        NSString *title = AMExternalDisplayModeTitle(key);
        if ([mode isEqual:screen.preferredMode]) {
            title = [NSString stringWithFormat:@"%@ (%@)", title, localize(@"preference.title.external_mode-native", nil)];
        }
        [titles addObject:title];
    }
    return @[keys, titles];
}

@implementation SurfaceViewController(ExternalDisplay)

- (void)applyExternalDisplaySettings {
    UIScreen *screen = AMExternalScreen();
    if (screen == nil) return;

    // Overscan: how iOS fits the picture on TVs that crop the edges
    NSString *overscan = getPrefObject(@"video.external_overscan");
    if ([overscan isEqualToString:@"inset"]) {
        screen.overscanCompensation = UIScreenOverscanCompensationInsetBounds;
    } else if ([overscan isEqualToString:@"none"]) {
        screen.overscanCompensation = UIScreenOverscanCompensationNone;
    } else {
        screen.overscanCompensation = UIScreenOverscanCompensationScale;
    }

    // Output resolution. iOS chooses the refresh rate itself; apps can only pick the size.
    NSString *wanted = getPrefObject(@"video.external_mode");
    UIScreenMode *target = screen.preferredMode;
    if (wanted.length > 0 && ![wanted isEqualToString:@"auto"]) {
        for (UIScreenMode *mode in screen.availableModes) {
            if ([AMModeKey(mode) isEqualToString:wanted]) {
                target = mode;
                break;
            }
        }
    }
    if (target != nil && ![screen.currentMode isEqual:target]) {
        screen.currentMode = target;
        // iOS may refuse the mode; log what the screen actually uses
        NSLog(@"[Display] External mode requested %@, now %@ at %d Hz", AMModeKey(target),
              screen.currentMode ? AMModeKey(screen.currentMode) : @"?", (int)screen.maximumFramesPerSecond);
    }
}

- (void)layoutExternalWindow {
    UIWindow *window = UIWindow.externalWindow;
    if (window == nil) return;
    window.frame = window.windowScene.coordinateSpace.bounds;
    [window layoutIfNeeded];
}

- (void)switchToExternalDisplay {
    UIWindow *secondWindow = UIWindow.externalWindow;
    if (secondWindow == nil || self.isOnExternalDisplay) return;
    if (AMExternalScene() == nil || secondWindow.windowScene != AMExternalScene()) {
        NSLog(@"[Display] Not moving the game: no separate external screen (Stage Manager window on the monitor?)");
        return;
    }
    // Moving the game resizes it and makes it render; from the background that loses the GPU device
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground ||
        UIWindow.mainWindow.windowScene.activationState == UISceneActivationStateBackground) {
        NSLog(@"[Display] Not moving the game while the app is in the background");
        return;
    }

    [self.surfaceView removeFromSuperview];
    [self.mousePointerView removeFromSuperview];

    UILabel *noteLabel = [[UILabel alloc] initWithFrame:self.touchView.bounds];
    noteLabel.tag = AMExternalNoteTag;
    noteLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    noteLabel.numberOfLines = 0;
    noteLabel.textAlignment = NSTextAlignmentCenter;
    noteLabel.textColor = UIColor.whiteColor;
    noteLabel.text = localize(@"game.note.airplay", nil);
    [self.touchView addSubview:noteLabel];

    if (secondWindow.rootViewController == nil) {
        secondWindow.rootViewController = [[UIViewController alloc] init];
        secondWindow.rootViewController.view.backgroundColor = UIColor.blackColor;
    }
    [secondWindow.rootViewController.view addSubview:self.surfaceView];
    [secondWindow.rootViewController.view addSubview:self.mousePointerView];

    secondWindow.hidden = NO;
    [self applyExternalDisplaySettings];
    [self layoutExternalWindow];
    [self updateSavedResolution];
}

- (void)switchToInternalDisplay {
    if (!self.isOnExternalDisplay) return;

    [self.surfaceView removeFromSuperview];
    [self.mousePointerView removeFromSuperview];

    UIWindow *secondWindow = UIWindow.externalWindow;
    secondWindow.hidden = YES;
    // Hand the external screen back to iOS's default mode for mirroring
    UIScreen *screen = AMExternalScreen();
    if (screen.preferredMode != nil && ![screen.currentMode isEqual:screen.preferredMode]) {
        screen.currentMode = screen.preferredMode;
    }

    [[self.touchView viewWithTag:AMExternalNoteTag] removeFromSuperview];
    // Back underneath anything else in the touch area, as at launch
    [self.touchView insertSubview:self.surfaceView atIndex:0];
    [self.touchView addSubview:self.mousePointerView];
    [self updateSavedResolution];
}

@end
