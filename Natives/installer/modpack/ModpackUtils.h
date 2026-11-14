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

/// Group for the instance the running install creates (nil = none). Set when each install starts.
@property(class, nonatomic, copy) NSString *pendingInstanceGroup;

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
/// For imported pack files (no store icon): an "icon.png" at the top of the pack (or in its overrides) is added
/// to the icon picker's custom icons. Returns the icon key, or nil when the pack has no usable icon.
+ (NSString *)iconKeyFromArchive:(UZKArchive *)archive packName:(NSString *)name;
/// Prism Launcher / MultiMC instance icon, found the way Prism imports it: an image named after instance.cfg's
/// iconKey next to instance.cfg (Prism exports custom icons as "<iconKey>.png"), else the built-in icon of that
/// name (Prism's built-in names match ours), else icon.png / overrides/icon.png in the instance folder.
/// `root` is the instance folder inside the archive ("" or "<name>/"). Returns an icon key or nil.
+ (NSString *)iconKeyFromMultiMCArchive:(UZKArchive *)archive root:(NSString *)root iconKey:(NSString *)iconKey packName:(NSString *)name;
/// For store installs: saves the logo the store list showed (left in tmp/icon.png when a version was picked) as a
/// custom icon named "<prefix><pack name>" (e.g. "curseforge_RLCraft", like Prism), replacing an older copy.
/// Returns the icon key, or nil when there is no logo or it could not be saved.
+ (NSString *)storeIconKeyWithPrefix:(NSString *)prefix packName:(NSString *)name;
/// Sets an imported pack's icon key on a profile created by createProfileNamed: (store icons are left alone).
+ (void)applyIconKey:(NSString *)iconKey toProfileNamed:(NSString *)profileName;
+ (NSString *)createProfileNamed:(NSString *)name
                         version:(NSString *)packVersion
                         gameDir:(NSString *)gameDir
                       versionId:(NSString *)versionId
                      iconBase64:(NSString *)iconBase64;

@end
