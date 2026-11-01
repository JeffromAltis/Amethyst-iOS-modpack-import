#import <UIKit/UIKit.h>

/// Settings landing page: a short list of categories, each with a one-line summary of its current state.
/// A category either opens a filtered LauncherPreferencesViewController, or (Controls) another hub.
@interface LauncherSettingsHubViewController : UITableViewController

/// Top-level Settings hub
- (instancetype)init;
/// Nested hub for a category that has sub-categories
- (instancetype)initWithTitle:(NSString *)title entries:(NSArray<NSDictionary *> *)entries;

@end
