#import <UIKit/UIKit.h>
#import "ModCatalog.h"

/// The instance's installed mods (like Prism's Mods page): enable/disable, delete, update,
/// and a button that opens the Modrinth/CurseForge browser.
@interface ModsManagerViewController : UITableViewController
/// versionId is the profile's lastVersionId, gameDirPath the absolute path of the instance folder.
- (instancetype)initWithVersionId:(NSString *)versionId gameDirPath:(NSString *)gameDirPath;
/// Same page for another kind of content (resource packs: the resourcepacks folder, no loader filter).
- (instancetype)initWithVersionId:(NSString *)versionId gameDirPath:(NSString *)gameDirPath kind:(ModContentKind)kind;
@end
