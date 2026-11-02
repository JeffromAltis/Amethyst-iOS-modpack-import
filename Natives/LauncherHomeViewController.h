#import <UIKit/UIKit.h>

extern NSNotificationName const LauncherJITStatusDidChangeNotification;

/// Home screen: every instance as a large icon tile (Prism-style grid). The toolbar holds what used to be in the
/// sidebar: New Instance, News, Settings, the JIT status, tools and the account.
@interface LauncherHomeViewController : UIViewController
/// "1.20.1 · Forge", "1.21.4 · Vanilla", worked out from the profile's version id
+ (NSString *)versionSummaryForProfile:(NSDictionary *)profile;
/// Pushes the instance page for a profile (selecting it first).
- (void)openInstanceNamed:(NSString *)name animated:(BOOL)animated;
@end
