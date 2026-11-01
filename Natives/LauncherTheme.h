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
/// Type scale. Every launcher screen takes its fonts from here instead of picking sizes and weights itself, so a
/// title looks like a title and a subtitle like a subtitle everywhere (all system font, SF).
/// Large screen heading (instance dashboard title)
+ (UIFont *)pageTitleFont;
/// Dialog and card headings
+ (UIFont *)sectionTitleFont;
/// Primary text of a row or card: setting names, list items
+ (UIFont *)rowTitleFont;
/// Plain text and the value shown at the right of a row
+ (UIFont *)bodyFont;
/// Button labels
+ (UIFont *)buttonFont;
/// Label above an input field
+ (UIFont *)fieldLabelFont;
/// Descriptions and secondary lines under a title
+ (UIFont *)subtitleFont;
/// Small uppercase section header
+ (UIFont *)headerFont;
/// Code, paths, arguments
+ (UIFont *)monoFont;

@end
