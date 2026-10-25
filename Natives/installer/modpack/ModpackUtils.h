#import <Foundation/Foundation.h>
#import "UnzipKit.h"

// Modpack package formats that can be detected inside an archive.
extern NSString * const ModpackFormatModrinth;   // modrinth.index.json (.mrpack)
extern NSString * const ModpackFormatCurseForge; // manifest.json (.zip)

@interface ModpackUtils : NSObject

+ (void)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path error:(NSError **)error;
+ (NSDictionary *)infoForDependencies:(NSDictionary *)dependency;

#pragma mark - Import helpers

/// Detects whether the archive is a Modrinth or CurseForge pack.
/// If both manifests are present, the file extension (.mrpack) breaks the tie.
/// Returns nil and fills `error` if the archive is not a modpack.
+ (NSString *)formatOfArchive:(UZKArchive *)archive extension:(NSString *)extension error:(NSError **)error;

/// Reads the pack's manifest and returns @{manifest, name, version, mcVersion}.
/// Returns nil and fills `error` if the manifest is unreadable or incomplete.
+ (NSDictionary *)manifestInfoForArchive:(UZKArchive *)archive format:(NSString *)format error:(NSError **)error;

/// Lowercase hex SHA-1 of a file, read in chunks (safe for large packs).
+ (NSString *)sha1ForFileAtPath:(NSString *)path;

/// Replaces characters that are illegal in file names with "_" and caps the length at 255.
+ (NSString *)sanitizedFileName:(NSString *)name;

/// YES if the relative path cannot escape its base directory (no "..", not absolute).
+ (BOOL)isSafeRelativePath:(NSString *)path;

/// Creates (or updates) the launcher profile for an installed pack and selects it.
/// `iconBase64` may be nil. Returns the key the profile was stored under.
+ (NSString *)createProfileNamed:(NSString *)name
                         version:(NSString *)packVersion
                         gameDir:(NSString *)gameDir
                       versionId:(NSString *)versionId
                      iconBase64:(NSString *)iconBase64;

#pragma mark - LWJGL3ify (GTNH and other 1.7.10 packs on modern Java)

/// If `gameDir`/mods contains an lwjgl3ify jar, installs the launch profile bundled inside it
/// (me/eigenraven/lwjgl3ify/relauncher/version.json) as versions/1.7.10-LWJGL3ify-<ver> and
/// returns that version id, like Android's "Add LWJGL3ify" flow. Returns nil if not applicable.
+ (NSString *)installLWJGL3ifyVersionFromGameDir:(NSString *)gameDir;

#pragma mark - Mod loader (Forge / NeoForge) installation

/// Returns @{vendor, mc, version} if the pack needs Forge or NeoForge installed, else nil.
/// (Fabric/Quilt only need a version JSON, which the pack installers already download.)
+ (NSDictionary *)pendingLoaderForDependencies:(NSDictionary *)dependency;

/// Finds the installer JAR URL for a loader returned by pendingLoaderForDependencies.
/// Performs blocking HEAD requests; call off the main thread. Returns nil if not found.
+ (NSString *)installerURLForLoader:(NSDictionary *)loader;

/// Remembers that `profileKey` still needs its loader installed.
+ (void)markProfile:(NSString *)profileKey pendingLoader:(NSDictionary *)loader;

/// After a loader installer ran, points profiles waiting for one at the version folder it created
/// (e.g. "1.7.10-Forge10.13.4.1614-1.7.10"), whose name differs between Forge generations.
+ (void)fixupPendingLoaderProfiles;

@end
