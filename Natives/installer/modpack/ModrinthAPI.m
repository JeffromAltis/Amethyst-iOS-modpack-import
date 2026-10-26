#import "MinecraftResourceDownloadTask.h"
#import "LWJGL3ifyUtils.h"
#import "ModrinthAPI.h"
#import "PLProfiles.h"

@implementation ModrinthAPI

- (instancetype)init {
    return [super initWithURL:@"https://api.modrinth.com/v2"];
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters previousPageResult:(NSMutableArray *)modrinthSearchResult {
    int limit = 50;

    NSMutableString *facetString = [NSMutableString new];
    [facetString appendString:@"["];
    [facetString appendFormat:@"[\"project_type:%@\"]", searchFilters[@"isModpack"].boolValue ? @"modpack" : @"mod"];
    if (searchFilters[@"mcVersion"].length > 0) {
        [facetString appendFormat:@",[\"versions:%@\"]", searchFilters[@"mcVersion"]];
    }
    [facetString appendString:@"]"];

    NSDictionary *params = @{
        @"facets": facetString,
        @"query": [searchFilters[@"name"] stringByReplacingOccurrencesOfString:@" " withString:@"+"],
        @"limit": @(limit),
        @"index": @"relevance",
        @"offset": @(modrinthSearchResult.count)
    };
    NSDictionary *response = [self getEndpoint:@"search" params:params];
    if (!response) {
        return nil;
    }

    NSMutableArray *result = modrinthSearchResult ?: [NSMutableArray new];
    for (NSDictionary *hit in response[@"hits"]) {
        BOOL isModpack = [hit[@"project_type"] isEqualToString:@"modpack"];
        [result addObject:@{
            @"apiSource": @(1), // Constant MODRINTH
            @"isModpack": @(isModpack),
            @"id": hit[@"project_id"],
            @"title": hit[@"title"],
            @"description": hit[@"description"],
            @"imageUrl": hit[@"icon_url"]
        }.mutableCopy];
    }
    self.reachedLastPage = result.count >= [response[@"total_hits"] unsignedLongValue];
    return result;
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSArray *response = [self getEndpoint:[NSString stringWithFormat:@"project/%@/version", item[@"id"]] params:nil];
    if (!response) {
        return;
    }
    NSArray<NSString *> *names = [response valueForKey:@"name"];
    NSMutableArray<NSString *> *mcNames = [NSMutableArray new];
    NSMutableArray<NSString *> *urls = [NSMutableArray new];
    NSMutableArray<NSString *> *hashes = [NSMutableArray new];
    NSMutableArray<NSString *> *sizes = [NSMutableArray new];
    [response enumerateObjectsUsingBlock:
  ^(NSDictionary *version, NSUInteger i, BOOL *stop) {
        NSDictionary *file = [version[@"files"] firstObject];
        mcNames[i] = [version[@"game_versions"] firstObject];
        sizes[i] = file[@"size"];
        urls[i] = file[@"url"];
        NSDictionary *hashesMap = file[@"hashes"];
        hashes[i] = hashesMap[@"sha1"] ?: [NSNull null];
    }];
    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionSizes"] = sizes;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionDetailsLoaded"] = @(YES);
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open modpack package: %@", error.localizedDescription]];
        return;
    }

    NSData *indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&error];
    NSDictionary* indexDict = indexData ? [NSJSONSerialization JSONObjectWithData:indexData options:kNilOptions error:&error] : nil;
    if (!indexDict) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse modrinth.index.json: %@", error.localizedDescription ?: @"file not found"]];
        return;
    }

    BOOL queuedAny = NO;
    downloader.progress.totalUnitCount = [indexDict[@"files"] count];
    for (NSDictionary *indexFile in indexDict[@"files"]) {
        // Never let a pack write outside of its own instance directory
        if (![ModpackUtils isSafeRelativePath:indexFile[@"path"]]) {
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Modpack contains an invalid file path: %@", indexFile[@"path"]]];
            return;
        }
        NSString *url = [indexFile[@"downloads"] firstObject];
        NSString *sha = indexFile[@"hashes"][@"sha1"];
        NSString *path = [destPath stringByAppendingPathComponent:indexFile[@"path"]];
        NSUInteger size = [indexFile[@"fileSize"] unsignedLongLongValue];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url size:size sha:sha altName:nil toPath:path];
        if (task) {
            queuedAny = YES;
            [task resume];
        } else if (!downloader.progress.cancelled) {
            downloader.progress.completedUnitCount++;
        } else {
            return; // cancelled
        }
    }

    // "overrides" is applied to both client and server, "client-overrides" is client only
    for (NSString *dir in @[@"overrides", @"client-overrides"]) {
        [ModpackUtils archive:archive extractDirectory:dir toPath:destPath error:&error];
        if (error) {
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract %@ from modpack package: %@", dir, error.localizedDescription]];
            return;
        }
    }

    // Delete package cache
    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];

    // Download dependency client json (if available)
    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:indexDict[@"dependencies"]];

    // Loader-less 1.7.10 packs that bundle lwjgl3ify (e.g. GT New Horizons Mobile) run through the
    // launch profile inside the lwjgl3ify jar, which brings Forge and the Java 9+ bootstrap along
    NSString *versionId = depInfo[@"id"] ?: indexDict[@"dependencies"][@"minecraft"];
    if (!depInfo[@"json"]) {
        NSError *lwjgl3ifyError;
        NSString *lwjgl3ifyVersion = [LWJGL3ifyUtils versionIdForGameDirectory:destPath currentVersionId:versionId error:&lwjgl3ifyError];
        if (!lwjgl3ifyVersion) {
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to set up lwjgl3ify: %@", lwjgl3ifyError.localizedDescription]];
            return;
        }
        versionId = lwjgl3ifyVersion;
    }
    if (depInfo[@"json"]) {
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("GAME_DIR"), depInfo[@"id"]];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] size:0 sha:nil altName:nil toPath:jsonPath];
        if (task) {
            queuedAny = YES;
            [task resume];
        }
    }
    // TODO: automation for Forge

    // Create profile
    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    NSData *iconData = [NSData dataWithContentsOfFile:tmpIconPath];
    [ModpackUtils createProfileNamed:indexDict[@"name"]
        version:indexDict[@"versionId"]
        gameDir:[NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent]
        versionId:versionId
        iconBase64:[iconData base64EncodedStringWithOptions:0]];

    if (!queuedAny) {
        [downloader completeIfNothingQueued];
    }
}

@end
