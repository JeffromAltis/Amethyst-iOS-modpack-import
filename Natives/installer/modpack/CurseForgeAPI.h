#import <Foundation/Foundation.h>
#import "ModpackAPI.h"

/// CurseForge modpack (manifest.json .zip) installer.
/// Only importing a local pack is supported for now; searching CurseForge is not.
@interface CurseForgeAPI : ModpackAPI
@end
