#import <UIKit/UIKit.h>

/// Launcher palette (dark values taken from the design concept; light mode falls back to system colors).
@interface LauncherTheme : NSObject
/// Sidebar, bottom bar and status area
+ (UIColor *)chromeBackground;
/// Main content area behind the instance dashboard
+ (UIColor *)contentBackground;
/// Large panel that holds groups of settings
+ (UIColor *)panelBackground;
/// Rows/cards inside a panel
+ (UIColor *)rowBackground;
/// Selected sidebar row
+ (UIColor *)selectionBackground;
/// Small status pills (JIT)
+ (UIColor *)pillBackground;
+ (UIColor *)separator;
/// Play button and sliders
+ (UIColor *)accent;

/// Opaque bar appearance in the given background (navigation bars and toolbars)
+ (void)applyBarBackground:(UIColor *)color toNavigationController:(UINavigationController *)nav;
@end
