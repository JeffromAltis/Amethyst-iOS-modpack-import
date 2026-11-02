#import <UIKit/UIKit.h>

extern NSNotificationName const LauncherJITStatusDidChangeNotification;

/// Home screen: every instance as a large icon tile (Prism-style grid). The toolbar holds what used to be in the
/// sidebar: New Instance, News, Settings, the JIT status, tools and the account.
@interface LauncherHomeViewController : UIViewController
/// Pushes the instance page for a profile (selecting it first).
- (void)openInstanceNamed:(NSString *)name animated:(BOOL)animated;
@end
