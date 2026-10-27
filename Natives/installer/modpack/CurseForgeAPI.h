#import <Foundation/Foundation.h>
#import "ModpackAPI.h"

/// CurseForge modpack (manifest.json .zip) installer.
/// Browses CurseForge modpacks (search + versions) and installs a pack, either downloaded from there or imported from a local file.
/// Needs the CurseForge API key the build was made with.
/// Posted on the main queue when a pack has mods their authors don't let apps download. userInfo:
/// pack (NSString), folder (NSString, where to put the files, relative to the game directory),
/// mods (NSArray of @{name, url}: file name and the mod's CurseForge page).
extern NSNotificationName const CurseForgeBlockedModsNotification;

@interface CurseForgeAPI : ModpackAPI
@end
