#import "LauncherTheme.h"

static UIColor *Dynamic(UIColor *light, unsigned int darkHex) {
    UIColor *dark = [UIColor colorWithRed:((darkHex >> 16) & 0xFF) / 255.0
                                    green:((darkHex >> 8) & 0xFF) / 255.0
                                     blue:(darkHex & 0xFF) / 255.0 alpha:1.0];
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
    }];
}

@implementation LauncherTheme

+ (UIColor *)chromeBackground { return Dynamic(UIColor.secondarySystemBackgroundColor, 0x1c1c1e); }
+ (UIColor *)contentBackground { return Dynamic(UIColor.systemBackgroundColor, 0x020202); }
+ (UIColor *)panelBackground { return Dynamic(UIColor.secondarySystemBackgroundColor, 0x1d1d1d); }
+ (UIColor *)rowBackground { return Dynamic(UIColor.tertiarySystemBackgroundColor, 0x262628); }
+ (UIColor *)selectionBackground { return Dynamic(UIColor.systemGray5Color, 0x3f4042); }
+ (UIColor *)pillBackground { return Dynamic(UIColor.systemGray5Color, 0x353736); }
+ (UIColor *)separator { return Dynamic(UIColor.separatorColor, 0x323335); }
+ (UIColor *)accent { return Dynamic([UIColor colorWithRed:0x6f/255.0 green:0x2f/255.0 blue:0x9d/255.0 alpha:1], 0x6f2f9d); }

+ (void)applyBarBackground:(UIColor *)color toNavigationController:(UINavigationController *)nav {
    UINavigationBarAppearance *bar = [UINavigationBarAppearance new];
    [bar configureWithOpaqueBackground];
    bar.backgroundColor = color;
    bar.shadowColor = UIColor.clearColor;
    nav.navigationBar.standardAppearance = bar;
    nav.navigationBar.scrollEdgeAppearance = bar;

    UIToolbarAppearance *tool = [UIToolbarAppearance new];
    [tool configureWithOpaqueBackground];
    tool.backgroundColor = [self chromeBackground];
    tool.shadowColor = UIColor.clearColor;
    nav.toolbar.standardAppearance = tool;
    nav.toolbar.scrollEdgeAppearance = tool;
    if (@available(iOS 15.0, *)) {
        nav.toolbar.compactAppearance = tool;
    }
}

@end
