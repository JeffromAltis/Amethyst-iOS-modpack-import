#import "LauncherPreferences.h"
#import "SceneExternalDelegate.h"
#import "SurfaceViewController.h"

extern UIWindow *externalWindow;

@interface SceneExternalDelegate ()

@end

@implementation SceneExternalDelegate


- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    self.window.frame = windowScene.coordinateSpace.bounds; 
    externalWindow = self.window;
    if (SurfaceViewController.isRunning && getPrefBool(@"video.fullscreen_airplay")) {
        [UIWindow.mainWindow.rootViewController performSelector:@selector(switchToExternalDisplay)];
    }
}

// The external screen's size changes when its mode changes (or the TV reconnects at another resolution)
- (void)windowScene:(UIWindowScene *)windowScene didUpdateCoordinateSpace:(id<UICoordinateSpace>)previousCoordinateSpace
    interfaceOrientation:(UIInterfaceOrientation)previousInterfaceOrientation traitCollection:(UITraitCollection *)previousTraitCollection {
    self.window.frame = windowScene.coordinateSpace.bounds;
    [self.window layoutIfNeeded];
    if (SurfaceViewController.isRunning) {
        SurfaceViewController *vc = (id)UIWindow.mainWindow.rootViewController;
        [vc updateDisplayPlacement];
        if (vc.isOnExternalDisplay) [vc updateSavedResolution];
    }
}


- (void)sceneDidDisconnect:(UIScene *)scene {
    // Called as the scene is being released by the system.
    // This occurs shortly after the scene enters the background, or when its session is discarded.
    // Release any resources associated with this scene that can be re-created the next time the scene connects.
    // The scene may re-connect later, as its session was not neccessarily discarded (see `application:didDiscardSceneSessions` instead).
    // switchToInternalDisplay does nothing unless the game is on the external display
    if (SurfaceViewController.isRunning) {
        [UIWindow.mainWindow.rootViewController performSelector:@selector(switchToInternalDisplay)];
    }
}


- (void)sceneDidBecomeActive:(UIScene *)scene {
    // Called when the scene has moved from an inactive state to an active state.
    // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
}


- (void)sceneWillResignActive:(UIScene *)scene {
    // Called when the scene will move from an active state to an inactive state.
    // This may occur due to temporary interruptions (ex. an incoming phone call).
}


- (void)sceneWillEnterForeground:(UIScene *)scene {
    // Called as the scene transitions from the background to the foreground.
    // Use this method to undo the changes made on entering the background.
}


- (void)sceneDidEnterBackground:(UIScene *)scene {
    // Called as the scene transitions from the foreground to the background.
    // Use this method to save data, release shared resources, and store enough scene-specific state information
    // to restore the scene back to its current state.
}

@end
