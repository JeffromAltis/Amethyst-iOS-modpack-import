#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, ModSource) { ModSourceModrinth, ModSourceCurseForge };
typedef NS_ENUM(NSInteger, ModSort) { ModSortRelevance, ModSortDownloads, ModSortUpdated, ModSortNewest };
/// What the catalog manages: jars in mods/, or zips in resourcepacks/ (no loader filter, like Prism's resource packs page).
typedef NS_ENUM(NSInteger, ModContentKind) { ModContentKindMods, ModContentKindResourcePacks };

/// One downloadable mod file, from either site.
@interface ModFile : NSObject
@property(nonatomic, copy) NSString *label, *fileName, *url, *sha1;
/// Modrinth version id or CurseForge file id, and the project (mod) it belongs to
@property(nonatomic, copy) NSString *versionId, *projectId;
@property(nonatomic, copy) NSString *releaseType; // release, beta, alpha
@property(nonatomic) NSArray<NSDictionary *> *dependencies; // @{id: project/mod id, versionId: optional exact Modrinth version}
@end

/// A jar in the instance's mods folder, matched to a Modrinth/CurseForge project when it is known there.
/// Treated as immutable once it is in -installed (changes replace it with a copy), so it can be read from any thread.
@interface InstalledMod : NSObject<NSCopying>
@property(nonatomic, copy) NSString *path, *fileName, *sha1;
@property(nonatomic) BOOL enabled;
@property(nonatomic) BOOL known;
@property(nonatomic) ModSource source;
@property(nonatomic, copy) NSString *title, *iconURL, *projectId, *versionId, *versionLabel;
/// release, beta or alpha
@property(nonatomic, copy) NSString *releaseType;
/// A newer file that fits the instance, if there is one
@property(nonatomic) ModFile *update;
@end

/// Everything the mod browser and mods page need: searching, versions, downloading,
/// and recognizing what is already installed. Network methods block, so call them
/// from -perform: (a serial queue, which also keeps the shared API objects single-threaded).
@interface ModCatalog : NSObject
/// loader: fabric, quilt, forge, neoforge or nil (always nil for resource packs). modsDir is the content folder (mods or resourcepacks).
@property(nonatomic, readonly, copy) NSString *mcVersion, *loader, *modsDir;
@property(nonatomic, readonly) ModContentKind kind;
/// Result of the last -refreshInstalled, replaced as a whole so it can be read from any thread
@property(atomic, readonly) NSArray<InstalledMod *> *installed;
@property(nonatomic, readonly) NSError *lastError;

/// versionId is the profile's lastVersionId, gameDirPath the absolute path of the instance folder.
- (instancetype)initWithVersionId:(NSString *)versionId gameDirPath:(NSString *)gameDirPath;
- (instancetype)initWithVersionId:(NSString *)versionId gameDirPath:(NSString *)gameDirPath kind:(ModContentKind)kind;
- (void)perform:(void (^)(void))block;

+ (NSString *)titleForSort:(ModSort)sort;
- (NSArray<NSDictionary *> *)categoriesForSource:(ModSource)source; // @{id, title}, cached

/// One page of results (@{id, title, description, imageUrl}); nil on error.
- (NSArray<NSDictionary *> *)searchSource:(ModSource)source query:(NSString *)query offset:(NSUInteger)offset
    sort:(ModSort)sort category:(id)category last:(BOOL *)last;
/// Files of a project that fit the instance, newest first; nil on error.
- (NSArray<ModFile *> *)filesForProject:(NSString *)projectId source:(ModSource)source;

/// Lists the jars without any network access.
- (NSArray<InstalledMod *> *)scanLocal;
/// Scans, recognizes the jars and looks for updates. Updates -installed.
- (void)refreshInstalled;
- (InstalledMod *)installedModForProject:(NSString *)projectId source:(ModSource)source;

/// Downloads the file and its required dependencies (skipping projects that are installed already).
/// If `old` is given, it is the installed version being replaced and is removed afterwards.
- (void)installFile:(ModFile *)file source:(ModSource)source replacing:(InstalledMod *)old
    installed:(NSMutableArray<NSString *> *)installed problems:(NSMutableArray<NSString *> *)problems;

/// Modrinth serves most icons as WebP, which AFNetworking's image downloader refuses by default.
/// Call once before loading mod icons.
+ (void)allowWebPIcons;

/// Enables or disables the exact listed file (.jar <-> .jar.disabled), without replacing an existing target.
/// Refresh the list if the path is no longer present. Returns a copy in its new state, or nil on error.
- (InstalledMod *)setMod:(InstalledMod *)mod enabled:(BOOL)enabled error:(NSError **)error;
- (BOOL)deleteMod:(InstalledMod *)mod error:(NSError **)error;
@end
