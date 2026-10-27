#import <UIKit/UIKit.h>

@class ModpackAPI;

/// Searchable list of modpacks from one source (Modrinth, CurseForge); picking a version installs it.
@interface ModpackInstallViewController : UITableViewController<UISearchResultsUpdating>
/// Defaults to Modrinth when nil.
@property(nonatomic) ModpackAPI *api;
/// Embedded in the New Instance window: no Close button, and errors don't close anything.
@property(nonatomic) BOOL embedded;
@end
