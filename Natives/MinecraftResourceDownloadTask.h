#import <UIKit/UIKit.h>

@class ModpackAPI;

@interface MinecraftResourceDownloadTask : NSObject
@property NSProgress *progress, *textProgress;
@property NSMutableArray *fileList, *progressList;
@property NSMutableDictionary* metadata;
@property(nonatomic, copy) void(^handleError)(void);

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path;
- (void)finishDownloadWithErrorString:(NSString *)error;

- (void)downloadVersion:(NSDictionary *)version;
- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;
/// Installs a modpack the user picked from their files (.zip CurseForge pack or Prism/MultiMC instance, .mrpack Modrinth pack).
/// Must be called off the main thread. The file at packagePath is consumed (deleted when done).
- (void)importModpackFromPath:(NSString *)packagePath;
/// Marks the task as finished when an install had nothing to download (e.g. everything was already cached).
- (void)completeIfNothingQueued;

@end
