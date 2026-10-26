#import <Foundation/Foundation.h>

/// Helpers for packs that run Minecraft 1.7.10 on modern Java through lwjgl3ify
/// (e.g. GT New Horizons Mobile). Such packs ship lwjgl3ify in their mods folder
/// and declare no mod loader: the lwjgl3ify jar carries a complete launch profile
/// (Forge + RetroFuturaBootstrap + LWJGL 3) that the launcher has to install.
/// Ported from Amethyst Android's LWJGL3ifyUtils.
@interface LWJGL3ifyUtils : NSObject

/// Finds the lwjgl3ify mod jar in `modsDir`. Returns nil if there is none.
/// Fails (nil + error) if more than one is present, since the game can't start that way.
+ (NSString *)findJarInModsDirectory:(NSString *)modsDir error:(NSError **)error;

/// The launcher version id for a given lwjgl3ify jar, "1.7.10-LWJGL3ify-<version>".
+ (NSString *)versionIdForJar:(NSString *)jarPath error:(NSError **)error;

/// Writes the launch profile embedded in the jar to versions/<id>/<id>.json
/// (replacing an older copy if it differs). Returns the version id.
+ (NSString *)installVersionFromJar:(NSString *)jarPath error:(NSError **)error;

/// Turns off lwjgl3ify options in the instance's config that can't work on iOS
/// (its libspng texture loader). Leaves every other setting alone.
+ (void)applyRequiredConfigToGameDirectory:(NSString *)gameDir;

/// If the instance at `gameDir` (absolute) contains lwjgl3ify, installs its profile, applies
/// applyRequiredConfigToGameDirectory: and
/// returns the version id the launcher profile should use. Returns `currentVersionId`
/// unchanged when the instance has no lwjgl3ify or already points at an lwjgl3ify version.
+ (NSString *)versionIdForGameDirectory:(NSString *)gameDir
                       currentVersionId:(NSString *)currentVersionId
                                  error:(NSError **)error;

@end
