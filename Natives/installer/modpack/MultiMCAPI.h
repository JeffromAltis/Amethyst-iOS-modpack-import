#import <Foundation/Foundation.h>
#import "ModpackAPI.h"

/// Imports a Prism Launcher / MultiMC instance export (a .zip holding mmc-pack.json,
/// instance.cfg and a .minecraft or minecraft folder with the mods and configs).
/// Everything is already in the archive, so nothing but the game itself is downloaded.
@interface MultiMCAPI : ModpackAPI
@end
