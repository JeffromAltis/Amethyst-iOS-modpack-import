#import <UIKit/UIKit.h>

/// Searchable Modrinth / CurseForge mod list for one instance, like Prism's "Download mods".
/// Results are filtered to the instance's Minecraft version and mod loader, and the picked
/// version (plus its required dependencies) is downloaded into the instance's mods folder.
@interface ModBrowserViewController : UITableViewController<UISearchResultsUpdating>
/// versionId is the profile's lastVersionId, gameDirPath the absolute path of the instance folder.
- (instancetype)initWithVersionId:(NSString *)versionId gameDirPath:(NSString *)gameDirPath;
@end
