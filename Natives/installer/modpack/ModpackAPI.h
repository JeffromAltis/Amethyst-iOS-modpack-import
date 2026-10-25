#import <Foundation/Foundation.h>
#import "ModpackUtils.h"
#import "UnzipKit.h"

@class MinecraftResourceDownloadTask;

@interface ModpackAPI : NSObject
@property(nonatomic) NSString *baseURL;
/// Optional API key, sent as the "x-api-key" header (CurseForge).
@property(nonatomic) NSString *apiKey;
@property(nonatomic) NSError *lastError;
@property(nonatomic) BOOL reachedLastPage;

- (instancetype)initWithURL:(NSString *)url;
- (NSMutableArray *)searchModWithFilters:(NSDictionary *)filters previousPageResult:(NSMutableArray *)prevResult;
- (void)loadDetailsOfMod:(NSMutableDictionary *)item;

- (void)installModpackFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;

/// Installs a downloaded or user-imported package into destPath and creates its profile.
/// Blocking network calls may be made, so this must not be called on the main thread.
- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath;

- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params;
/// Synchronous JSON POST. Returns the decoded response or nil (see lastError).
- (id)postEndpoint:(NSString *)endpoint body:(NSDictionary *)body;

@end
