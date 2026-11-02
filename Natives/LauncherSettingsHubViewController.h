#import <UIKit/UIKit.h>

/// Settings landing page: a short list of categories, each with a one-line summary of its current state.
/// A category either opens a filtered LauncherPreferencesViewController, or (Controls) another hub.
@interface LauncherSettingsHubViewController : UITableViewController

/// Top-level Settings hub
- (instancetype)init;
/// Nested hub for a category that has sub-categories
- (instancetype)initWithTitle:(NSString *)title entries:(NSArray<NSDictionary *> *)entries;
/// When set, picking a category hands its page to this block (the two-pane Settings page) instead of pushing it
@property(nonatomic, copy) void (^onSelectPage)(UIViewController *page);
/// Opens the category at this row (used by the two-pane page to show the first category)
- (void)selectRow:(NSInteger)row;

@end

/// Settings as one page: categories on the left, the chosen category on the right (wide screens)
@interface LauncherSettingsPageViewController : UIViewController
@end
