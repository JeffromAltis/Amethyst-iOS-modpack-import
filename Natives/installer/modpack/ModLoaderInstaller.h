#import <Foundation/Foundation.h>

@class MinecraftResourceDownloadTask;

/// Installs Forge and NeoForge without running their installer's window, the way Prism Launcher
/// and Amethyst Android set up a modpack's loader.
///
/// The installer jar is downloaded and taken apart here: its launcher profile is written to
/// versions/<id>/<id>.json, the libraries it bundles are extracted and the ones its processors need
/// are queued. Modern installers (Minecraft 1.13+) also have processors, Java programs that build the
/// patched game jar; those run inside the game's own JVM right before Minecraft starts, see
/// ModLoaderPostInstall.java. No launcher profile is created for the loader.
@interface ModLoaderInstaller : NSObject

/// YES for the version ids modpacks use for Forge ("<mc>-forge-<version>") and NeoForge ("neoforge-<version>").
+ (BOOL)isLoaderVersionId:(NSString *)versionId;

/// YES if `versionId` names a Forge/NeoForge version whose profile is not installed yet.
+ (BOOL)needsInstallForVersionId:(NSString *)versionId;

/// Downloads and unpacks the installer for `versionId`. Blocks; never call it on the main thread.
/// When `downloader` is given, the libraries the processors need are queued on it; otherwise they
/// are fetched at launch. Returns the id of the installed version (older Forge uses its own naming,
/// e.g. "1.7.10-Forge10.13.4.1614-1.7.10"), or nil and fills `error`.
+ (NSString *)installLoaderForVersionId:(NSString *)versionId
                             downloader:(MinecraftResourceDownloadTask *)downloader
                                  error:(NSError **)error;

@end
