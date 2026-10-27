#import <UIKit/UIKit.h>

/// The "Profiles" destination: the list of instances (1 profile = 1 instance) plus game folder options.
@interface LauncherProfilesViewController : UITableViewController

/// Where creation editors and pickers are presented from. Defaults to this controller, which only
/// works while it is on screen, so the sidebar sets this to the split view controller.
@property(nonatomic, weak) UIViewController *presentationHost;

/// Menu with every way of creating a new instance (vanilla, Fabric/Quilt, Forge, modpack, import).
- (UIMenu *)createInstanceMenu;

@end
