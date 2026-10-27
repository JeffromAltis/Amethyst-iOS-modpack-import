#import <UIKit/UIKit.h>

#define TYPE_INSTALLED 0
#define TYPE_RELEASE 1
#define TYPE_SNAPSHOT 2
#define TYPE_OLDBETA 3
#define TYPE_OLDALPHA 4

@interface MinecraftResourceUtils : NSObject

+ (void)processVersion:(NSMutableDictionary *)json inheritsFrom:(NSMutableDictionary *)inheritsFrom;
+ (void)tweakVersionJson:(NSMutableDictionary *)json;

/// Relative Maven path for "group:artifact:version[:classifier][@ext]", or nil if malformed.
+ (NSString *)pathForLibraryName:(NSString *)name;
/// YES if the version's JVM arguments replace the system class loader (e.g. RetroFuturaBootstrap).
+ (BOOL)versionRequestsCustomSystemClassLoader:(NSDictionary *)json;

+ (NSObject *)findVersion:(NSString *)version inList:(NSArray *)list;
+ (NSObject *)findNearestVersion:(NSObject *)version expectedType:(int)type;

@end
