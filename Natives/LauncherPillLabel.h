#import <UIKit/UIKit.h>

/// Small rounded tag ("Recommended", "Java 25"): launcher-styled text on a tinted capsule.
@interface LauncherPillLabel : UILabel
+ (instancetype)pillWithText:(NSString *)text color:(UIColor *)color;
@end
