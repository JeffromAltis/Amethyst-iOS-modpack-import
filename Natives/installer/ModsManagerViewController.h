#import <UIKit/UIKit.h>

/// The instance's installed mods (like Prism's Mods page): enable/disable, delete, update,
/// and a button that opens the Modrinth/CurseForge browser.
@interface ModsManagerViewController : UITableViewController
/// versionId is the profile's lastVersionId, gameDirPath the absolute path of the instance folder.
- (instancetype)initWithVersionId:(NSString *)versionId gameDirPath:(NSString *)gameDirPath;
@end
