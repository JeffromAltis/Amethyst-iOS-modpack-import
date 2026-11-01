#import <UIKit/UIKit.h>
#import "PLPrefTableViewController.h"

@interface LauncherPreferencesViewController : PLPrefTableViewController

/// A Settings category page: only the rows whose key is in `keys` (or, when `excluded` is given, every row whose
/// key is NOT in `excluded`), shown flat. Pass nil for both to get the full list (what the in-game menu uses).
- (instancetype)initWithTitle:(NSString *)title keys:(NSArray<NSString *> *)keys excluding:(NSArray<NSString *> *)excluded;

@end
