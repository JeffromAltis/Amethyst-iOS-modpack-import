#import <Foundation/Foundation.h>

@class MinecraftResourceDownloadTask;

/// Helpers for packs that run Minecraft 1.7.10 on modern Java through lwjgl3ify
/// (e.g. GT New Horizons Mobile). Such packs ship lwjgl3ify in their mods folder
/// and declare no mod loader: the lwjgl3ify jar carries a complete launch profile
/// (Forge + RetroFuturaBootstrap + LWJGL 3) that the launcher has to install.
/// Ported from Amethyst Android's LWJGL3ifyUtils.
@interface LWJGL3ifyUtils : NSObject

/// Turns off settings in the instance's mod configs that can't work on iOS
/// (lwjgl3ify's libspng texture loader, BetterLoadingScreen's threaded rendering), for the mods the
/// instance actually has. Leaves every other setting alone.
+ (void)applyRequiredConfigToGameDirectory:(NSString *)gameDir;

/// Applies applyRequiredConfigToGameDirectory: (for any instance), and if the instance at `gameDir`
/// (absolute) contains lwjgl3ify, installs its profile and returns the version id the launcher profile should use. Returns `currentVersionId`
/// unchanged when the instance has no lwjgl3ify or already points at an lwjgl3ify version.
+ (NSString *)versionIdForGameDirectory:(NSString *)gameDir
                       currentVersionId:(NSString *)currentVersionId
                                  error:(NSError **)error;

/// versionIdForGameDirectory:currentVersionId:error: for a modpack import: on failure the import is ended
/// through `downloader` with an error message and nil is returned.
+ (NSString *)versionIdForModpackGameDirectory:(NSString *)gameDir
                                     versionId:(NSString *)versionId
                                    downloader:(MinecraftResourceDownloadTask *)downloader;

@end
