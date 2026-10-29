#import <Foundation/Foundation.h>

/// Posted (main thread) whenever the set of profiles/instances, or the selected one, changes.
extern NSNotificationName const PLProfilesDidChangeNotification;

@interface PLProfiles : NSObject

@property(nonatomic) NSString *profilePath;
@property(nonatomic) NSMutableDictionary<NSString *, id> *profileDict;

/// "./instances/<name>" (relative to the Documents folder) with characters that are unsafe in a folder name replaced.
+ (NSString *)isolatedGameDirForName:(NSString *)name;
/// An unused instance folder, including when two names sanitize to the same name or old files were kept.
+ (NSString *)availableGameDirForName:(NSString *)name;
/// Documents/instances: one folder per instance. The shared libraries, versions and assets are in
/// Documents/game_data instead (GAME_DIR). Upgraded installations may retain their legacy shared location.
+ (NSString *)instancesDirectory;
/// The folder a profile's "gameDir" value points at. Empty or "." is the shared game_data folder (profiles
/// that were made without an instance folder).
+ (NSString *)absolutePathForGameDir:(NSString *)gameDir;
/// "<name>" for exactly "./instances/<name>", nil for anything else (including the shared folder)
+ (NSString *)instanceFolderNameForGameDir:(NSString *)gameDir;

+ (PLProfiles *)current;
+ (void)updateCurrent;

//+ (id)profile:(NSMutableDictionary *)profile resolveKey:(id)key;
+ (NSString *)resolveKeyForCurrentProfile:(id)key;

- (id)initWithCurrentInstance;
- (NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSString *> *> *)profiles;

- (NSMutableDictionary<NSString *, NSString *> *)selectedProfile;
- (NSString *)selectedProfileName;
- (void)setSelectedProfileName:(NSString *)name;
- (BOOL)save;
/// Saves without presenting UI, so callers that own an operation can report its failure once.
- (BOOL)saveWithError:(NSError **)error;

@end
