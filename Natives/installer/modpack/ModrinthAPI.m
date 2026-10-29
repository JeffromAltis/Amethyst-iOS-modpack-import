#import "MinecraftResourceDownloadTask.h"
#import "LWJGL3ifyUtils.h"
#import "ModLoaderInstaller.h"
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

    NSDictionary *info = [ModpackUtils manifestInfoForArchive:archive format:ModpackFormatModrinth error:&error];
    NSDictionary *indexDict = info[@"manifest"];
    if (!info) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse modrinth.index.json: %@", error.localizedDescription ?: @"file not found"]];
        return;
    }

    NSArray *archiveNames = [archive listFilenames:&error];
    if (!archiveNames) {
        [downloader finishDownloadWithErrorString:error.localizedDescription];
        return;
    }
    // Preflight destinations before any download is queued. Overrides take
    // precedence, so never queue a competing write to an overridden file.
    NSMutableSet *overridden = [NSMutableSet new];
    for (NSString *name in archiveNames) {
        for (NSString *prefix in @[@"overrides/", @"client-overrides/"]) {
            if (![name hasPrefix:prefix] || name.length <= prefix.length) continue;
            NSString *relative = [name substringFromIndex:prefix.length];
            if ([name hasSuffix:@"/"] && [relative.stringByStandardizingPath isEqualToString:@"."]) continue;
            if (![ModpackUtils destinationForRelativePath:relative underDirectory:destPath error:&error]) {
                [downloader finishDownloadWithErrorString:error.localizedDescription];
                return;
            }
            if (![name hasSuffix:@"/"]) [overridden addObject:relative.stringByStandardizingPath.precomposedStringWithCanonicalMapping.lowercaseString];
        }
    }
    NSMutableSet *destinations = overridden.mutableCopy;
    for (NSDictionary *file in indexDict[@"files"]) {
        if (![file[@"env"][@"client"] isEqual:@"unsupported"]) [destinations addObject:file[@"path"]];
        if (![file[@"env"][@"client"] isEqual:@"unsupported"] &&
            ![ModpackUtils destinationForRelativePath:file[@"path"] underDirectory:destPath error:&error]) {
            [downloader finishDownloadWithErrorString:error.localizedDescription];
            return;
        }
    }
    if (![ModpackUtils validateFilePaths:destinations underDirectory:destPath error:&error]) {
        [downloader finishDownloadWithErrorString:error.localizedDescription];
        return;
    }

    [ModpackUtils reportStatus:[NSString stringWithFormat:@"Queueing %lu downloads...", (unsigned long)[indexDict[@"files"] count]] fraction:-1];
    for (NSDictionary *indexFile in indexDict[@"files"]) {
        if (downloader.progress.cancelled) return;
        if ([indexFile[@"env"][@"client"] isEqual:@"unsupported"]) continue;
        NSString *identity = [indexFile[@"path"] stringByStandardizingPath].precomposedStringWithCanonicalMapping.lowercaseString;
        if ([overridden containsObject:identity]) continue;
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
            [task resume];
        } else if (downloader.progress.cancelled) {
            return; // cancelled
        }
    }

    // "overrides" is applied to both client and server, "client-overrides" is client only
    for (NSString *dir in @[@"overrides", @"client-overrides"]) {
        [ModpackUtils archive:archive extractDirectory:dir toPath:destPath progress:downloader.progress error:&error];
        if (downloader.progress.cancelled) return;
        if (error) {
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract %@ from modpack package: %@", dir, error.localizedDescription]];
            return;
        }
    }

    if (downloader.progress.cancelled) return;
    // Delete package cache
    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];

    // Download dependency client json (if available)
    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:indexDict[@"dependencies"]];

    // Loader-less 1.7.10 packs that bundle lwjgl3ify (e.g. GT New Horizons Mobile) run through the
    // launch profile inside the lwjgl3ify jar, which brings Forge and the Java 9+ bootstrap along
    NSString *versionId = depInfo[@"id"] ?: indexDict[@"dependencies"][@"minecraft"];
    if (!depInfo[@"json"]) {
        versionId = [LWJGL3ifyUtils versionIdForModpackGameDirectory:destPath versionId:versionId downloader:downloader];
        if (!versionId) {
            return;
        }
    }
    [ModpackUtils downloadVersionJsonForDependencyInfo:depInfo downloader:downloader];
    // Forge/NeoForge get installed right away, like Amethyst Android and Prism do
    versionId = [ModLoaderInstaller installIfNeededForVersionId:versionId downloader:downloader];


    if (downloader.progress.cancelled) return;
    // Create profile
    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    NSData *iconData = [NSData dataWithContentsOfFile:tmpIconPath];
    if (downloader.progress.cancelled) return;
    NSString *profileName = [ModpackUtils createProfileNamed:indexDict[@"name"]
        version:indexDict[@"versionId"]
        gameDir:[NSString stringWithFormat:@"./instances/%@", destPath.lastPathComponent]
        versionId:versionId
        iconBase64:[iconData base64EncodedStringWithOptions:0] error:&error];

    if (!profileName) {
        [downloader finishDownloadWithErrorString:error.localizedDescription ?: @"Could not save the imported instance profile."];
        return;
    }
    [downloader finishQueueingPackFiles];
}

@end
