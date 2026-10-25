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

@end
