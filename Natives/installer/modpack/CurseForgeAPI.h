#import <Foundation/Foundation.h>
#import "ModpackAPI.h"

/// CurseForge modpack (manifest.json .zip) installer.
/// Browses CurseForge modpacks (search + versions) and installs a pack, either downloaded from there or imported from a local file.
/// Needs the CurseForge API key the build was made with.
@interface CurseForgeAPI : ModpackAPI
@end
