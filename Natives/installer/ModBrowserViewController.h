#import <UIKit/UIKit.h>

@class ModCatalog;

/// Searchable Modrinth / CurseForge mod list for one instance, like Prism's "Download mods".
/// Results are filtered to the instance's Minecraft version and mod loader, and the picked
/// version (plus its required dependencies) is downloaded into the instance's mods folder.
@interface ModBrowserViewController : UITableViewController<UISearchResultsUpdating>
- (instancetype)initWithCatalog:(ModCatalog *)catalog;
@end
