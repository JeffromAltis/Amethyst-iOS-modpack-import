#import <Foundation/Foundation.h>
#import "UnzipKit.h"

@class MinecraftResourceDownloadTask;

// Modpack package formats that can be detected inside an archive.
extern NSString * const ModpackFormatModrinth;   // modrinth.index.json (.mrpack)
extern NSString * const ModpackFormatCurseForge; // manifest.json (.zip)
extern NSString * const ModpackFormatMultiMC;    // mmc-pack.json (Prism Launcher / MultiMC instance export, .zip)

@interface ModpackUtils : NSObject

/// Receives human readable import status. fraction is 0...1 for determinate steps (extraction) or -1 when unknown.
/// Always invoked on the main queue. Set by whoever shows the import UI, cleared with nil.
@property(class, nonatomic, copy) void (^statusHandler)(NSString *status, double fraction);
/// Thread safe. Updates faster than ~10 per second are dropped unless fraction is 0 or 1.
+ (void)reportStatus:(NSString *)status fraction:(double)fraction;

+ (void)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path error:(NSError **)error;
+ (NSDictionary *)infoForDependencies:(NSDictionary *)dependency;

/// Queues the download of the version JSON a pack's loader dependency points at (`depInfo[@"json"]`), if it has one.
+ (void)downloadVersionJsonForDependencyInfo:(NSDictionary<NSString *, NSString *> *)depInfo downloader:(MinecraftResourceDownloadTask *)downloader;

#pragma mark - Import helpers

/// Detects whether the archive is a Modrinth pack, a CurseForge pack or a Prism/MultiMC instance.
/// If both Modrinth and CurseForge manifests are present, the file extension (.mrpack) breaks the tie.
/// An instance export is only assumed when neither of those manifests is present.
/// Returns nil and fills `error` if the archive is not a modpack.
+ (NSString *)formatOfArchive:(UZKArchive *)archive extension:(NSString *)extension error:(NSError **)error;

/// Reads the pack's manifest and returns @{manifest, name, version, mcVersion}.
/// Prism/MultiMC instances also return @"root" (the folder holding mmc-pack.json inside the
/// archive, "" or "<folder>/") and @"instanceConfig" (instance.cfg as a dictionary).
/// Returns nil and fills `error` if the manifest is unreadable or incomplete.
+ (NSDictionary *)manifestInfoForArchive:(UZKArchive *)archive format:(NSString *)format error:(NSError **)error;

/// Version of the component with `uid` (e.g. "net.minecraft") in a parsed mmc-pack.json, or nil.
+ (NSString *)versionOfComponent:(NSString *)uid inMultiMCPack:(NSDictionary *)pack;

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

@end
