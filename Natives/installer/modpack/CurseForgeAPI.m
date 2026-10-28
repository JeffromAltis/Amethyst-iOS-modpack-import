#import "config.h"
#import "CurseForgeAPI.h"
#import "MinecraftResourceDownloadTask.h"
#import "ModLoaderInstaller.h"
#import "ModpackUtils.h"

// Files per POST /mods/files request
#define kCurseForgeBatchSize 100
#define kCurseForgeHashAlgoSHA1 1

NSNotificationName const CurseForgeBlockedModsNotification = @"CurseForgeBlockedMods";

@implementation CurseForgeAPI

- (instancetype)init {
    self = [super initWithURL:@"https://api.curseforge.com/v1"];
    self.apiKey = @(CONFIG_CURSEFORGE_API_KEY);
    return self;
}

#define kCurseForgeGameIDMinecraft 432
#define kCurseForgeClassIDModpack 4471
#define kCurseForgeSortPopularity 2
#define kCurseForgePageSize 50

static NSError *CurseForgeError(NSString *message) {
    return [NSError errorWithDomain:@"CurseForgeAPI" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

// GET /v1/mods/search for modpacks, most popular first (what Amethyst Android lists too)
- (NSMutableArray *)searchModWithFilters:(NSDictionary *)filters previousPageResult:(NSMutableArray *)prevResult {
    if (self.apiKey.length == 0) {
        self.lastError = CurseForgeError(@"This build has no CurseForge API key, so CurseForge can't be searched. Modrinth still works.");
        return nil;
    }
    NSString *name = [filters[@"name"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableDictionary *params = @{
        @"gameId": @(kCurseForgeGameIDMinecraft),
        @"classId": @(kCurseForgeClassIDModpack),
        @"sortField": @(kCurseForgeSortPopularity),
        @"sortOrder": @"desc",
        @"pageSize": @(kCurseForgePageSize),
        @"index": @(prevResult.count)
    }.mutableCopy;
    if (name.length > 0) {
        params[@"searchFilter"] = name;
    }
    NSDictionary *response = [self getEndpoint:@"mods/search" params:params];
    if (![response isKindOfClass:NSDictionary.class] || ![response[@"data"] isKindOfClass:NSArray.class]) {
        if (!self.lastError) self.lastError = CurseForgeError(@"Unexpected response from CurseForge.");
        return nil;
    }

    NSMutableArray *result = prevResult ?: [NSMutableArray new];
    for (NSDictionary *mod in response[@"data"]) {
        NSString *icon = [mod[@"logo"] isKindOfClass:NSDictionary.class] ? (mod[@"logo"][@"thumbnailUrl"] ?: mod[@"logo"][@"url"]) : nil;
        [result addObject:@{
            @"apiSource": @(0), // Constant CURSEFORGE
            @"isModpack": @(YES),
            @"id": mod[@"id"],
            @"title": mod[@"name"] ?: @"",
            @"description": mod[@"summary"] ?: @"",
            @"imageUrl": icon ?: @""
        }.mutableCopy];
    }
    NSUInteger total = [response[@"pagination"][@"totalCount"] unsignedLongValue];
    self.reachedLastPage = [response[@"data"] count] == 0 || result.count >= total;
    return result;
}

// GET /v1/mods/{id}/files: the pack versions the user can pick from
- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSDictionary *response = [self getEndpoint:[NSString stringWithFormat:@"mods/%@/files", item[@"id"]]
        params:@{@"pageSize": @(kCurseForgePageSize)}];
    NSArray *files = [response isKindOfClass:NSDictionary.class] ? response[@"data"] : nil;
    if (![files isKindOfClass:NSArray.class]) {
        if (!self.lastError) self.lastError = CurseForgeError(@"Unexpected response from CurseForge.");
        return;
    }

    NSMutableArray<NSString *> *names = [NSMutableArray new], *mcNames = [NSMutableArray new];
    NSMutableArray<NSString *> *urls = [NSMutableArray new];
    NSMutableArray *hashes = [NSMutableArray new], *sizes = [NSMutableArray new];
    for (NSDictionary *file in files) {
        // Server packs are for dedicated servers, and only .zip files are modpacks
        if ([file[@"isServerPack"] boolValue] || ![[file[@"fileName"] lowercaseString] hasSuffix:@".zip"]) continue;
        NSString *url = [self downloadURLForFileData:file];
        if (!url) continue;

        NSString *mcVersion = nil;
        for (NSString *version in file[@"gameVersions"]) {
            // gameVersions mixes Minecraft versions with loader names ("Forge", "Fabric", ...)
            if (version.length > 0 && [version characterAtIndex:0] >= '0' && [version characterAtIndex:0] <= '9') {
                mcVersion = version;
                break;
            }
        }
        [names addObject:file[@"displayName"] ?: file[@"fileName"]];
        [mcNames addObject:mcVersion ?: @""];
        [urls addObject:url];
        [sizes addObject:file[@"fileLength"] ?: @(0)];
        [hashes addObject:[self sha1FromFileData:file] ?: [NSNull null]];
    }
    if (names.count == 0) {
        self.lastError = CurseForgeError(@"This pack has no versions that can be downloaded here. Its author may have disabled downloads outside of CurseForge.");
        return;
    }
    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionSizes"] = sizes;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionDetailsLoaded"] = @(YES);
}

// Mirrors CurseforgeApi.verifyManifest on Android
- (BOOL)verifyManifest:(NSDictionary *)manifest {
    if (![manifest[@"manifestType"] isEqualToString:@"minecraftModpack"]) return NO;
    if ([manifest[@"manifestVersion"] integerValue] != 1) return NO;
    NSDictionary *minecraft = manifest[@"minecraft"];
    if (![minecraft[@"version"] isKindOfClass:NSString.class]) return NO;
    return [minecraft[@"modLoaders"] count] >= 1;
}

// CurseForge lists loaders as "forge-47.2.0", "fabric-0.15.7", "neoforge-21.1.1", ...
// Translate the primary one into the dependency dictionary Modrinth packs use.
- (NSDictionary *)dependenciesFromMinecraft:(NSDictionary *)minecraft {
    NSDictionary *primary = nil;
    for (NSDictionary *loader in minecraft[@"modLoaders"]) {
        if ([loader[@"primary"] boolValue]) {
            primary = loader;
            break;
        }
    }
    primary = primary ?: [minecraft[@"modLoaders"] firstObject];

    NSString *loaderId = primary[@"id"];
    NSRange dash = [loaderId rangeOfString:@"-"];
    NSMutableDictionary *deps = @{@"minecraft": minecraft[@"version"]}.mutableCopy;
    if (dash.location == NSNotFound) {
        return deps;
    }
    NSString *name = [loaderId substringToIndex:dash.location];
    NSString *version = [loaderId substringFromIndex:dash.location + 1];
    if ([name isEqualToString:@"forge"]) {
        deps[@"forge"] = version;
    } else if ([name isEqualToString:@"fabric"]) {
        deps[@"fabric-loader"] = version;
    } else if ([name isEqualToString:@"neoforge"]) {
        deps[@"neoforge"] = version;
    } else if ([name isEqualToString:@"quilt"]) {
        deps[@"quilt-loader"] = version;
    }
    return deps;
}

- (NSString *)sha1FromFileData:(NSDictionary *)data {
    for (NSDictionary *hash in data[@"hashes"]) {
        if ([hash[@"algo"] integerValue] == kCurseForgeHashAlgoSHA1) {
            return hash[@"value"];
        }
    }
    return nil;
}

// Same URL resolution as Android: the official downloadUrl, else the edge CDN link
- (NSString *)downloadURLForFileData:(NSDictionary *)data {
    id url = data[@"downloadUrl"];
    if ([url isKindOfClass:NSString.class] && [url length] > 0) {
        return url;
    }
    NSInteger fileId = [data[@"id"] integerValue];
    NSString *fileName = data[@"fileName"];
    if (fileId <= 0 || fileName.length == 0) {
        return nil;
    }
    return [NSString stringWithFormat:@"https://edge.forgecdn.net/files/%ld/%ld/%@",
        (long)(fileId / 1000), (long)(fileId % 1000), fileName];
}

/// YES if the CDN refuses this file (403/404). Network trouble is not "blocked": the download itself reports that.
- (BOOL)isBlockedURL:(NSString *)url {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    request.HTTPMethod = @"HEAD";
    request.timeoutInterval = 15;
    __block NSInteger status = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if ([response isKindOfClass:NSHTTPURLResponse.class]) status = ((NSHTTPURLResponse *)response).statusCode;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return status == 403 || status == 404;
}

// Resolves fileID -> file metadata with POST /mods/files, so a 200-mod pack costs a few requests
// instead of several hundred. Returns nil on failure.
- (NSDictionary<NSNumber *, NSDictionary *> *)fetchFileDataForIDs:(NSArray<NSNumber *> *)fileIDs {
    NSMutableDictionary *result = [NSMutableDictionary new];
    for (NSUInteger i = 0; i < fileIDs.count; i += kCurseForgeBatchSize) {
        NSRange range = NSMakeRange(i, MIN(kCurseForgeBatchSize, fileIDs.count - i));
        NSDictionary *response = [self postEndpoint:@"mods/files" body:@{@"fileIds": [fileIDs subarrayWithRange:range]}];
        NSArray *data = [response isKindOfClass:NSDictionary.class] ? response[@"data"] : nil;
        if (![data isKindOfClass:NSArray.class]) {
            return nil;
        }
        for (NSDictionary *fileData in data) {
            result[fileData[@"id"]] = fileData;
        }
    }
    return result;
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    if (self.apiKey.length == 0) {
        [downloader finishDownloadWithErrorString:@"This build has no CurseForge API key, so CurseForge modpacks can't be imported. Modrinth (.mrpack) packs still work."];
        return;
    }

    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open modpack package: %@", error.localizedDescription]];
        return;
    }
    NSDictionary *info = [ModpackUtils manifestInfoForArchive:archive format:ModpackFormatCurseForge error:&error];
    NSDictionary *manifest = info[@"manifest"];
    if (!info || ![self verifyManifest:manifest]) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to read manifest.json: %@", error.localizedDescription ?: @"unsupported manifest"]];
        return;
    }

    // Resolve every mod in as few requests as possible
    NSArray<NSDictionary *> *files = manifest[@"files"] ?: @[];
    NSMutableArray<NSNumber *> *fileIDs = [NSMutableArray new];
    for (NSDictionary *file in files) {
        [fileIDs addObject:file[@"fileID"]];
    }
    NSDictionary<NSNumber *, NSDictionary *> *fileData = [self fetchFileDataForIDs:fileIDs];
    if (!fileData) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to query CurseForge: %@",
            self.lastError.localizedDescription ?: @"invalid response"]];
        return;
    }

    NSString *modsDir = [destPath stringByAppendingPathComponent:@"mods"];
    NSMutableArray<NSDictionary *> *blockedMods = [NSMutableArray new];
    for (NSDictionary *file in files) {
        NSDictionary *data = fileData[file[@"fileID"]];
        NSString *fileName = data[@"fileName"];
        NSString *url = nil;
        if (data && [ModpackUtils isSafeRelativePath:fileName]) {
            id direct = data[@"downloadUrl"];
            if ([direct isKindOfClass:NSString.class] && [direct length] > 0) {
                url = direct;
            } else {
                // The author disallows downloads by other apps: there is no official link. The CDN address
                // sometimes still works, so ask it before giving up on the file.
                NSString *edge = [self downloadURLForFileData:data];
                if (edge && ![self isBlockedURL:edge]) {
                    url = edge;
                } else {
                    // Don't fail the whole pack: the user is told to download this one by hand (see below)
                    [blockedMods addObject:@{
                        @"name": fileName,
                        @"url": [NSString stringWithFormat:@"https://www.curseforge.com/projects/%@", file[@"projectID"]]
                    }];
                    continue;
                }
            }
        }
        if (!url) {
            // Optional files that can't be resolved are skipped, required ones abort (as on Android)
            if ([file[@"required"] boolValue] || file[@"required"] == nil) {
                [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to obtain download URL for %@ %@",
                    file[@"projectID"], file[@"fileID"]]];
                return;
            }
            continue;
        }

        NSUInteger size = [data[@"fileLength"] unsignedLongLongValue];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url size:size
            sha:[self sha1FromFileData:data] altName:nil
            toPath:[modsDir stringByAppendingPathComponent:fileName]];
        if (task) {
            [task resume];
        } else if (downloader.progress.cancelled) {
            return; // cancelled
        }
    }

    NSString *overridesDir = [manifest[@"overrides"] isKindOfClass:NSString.class] ? manifest[@"overrides"] : @"overrides";
    if (![ModpackUtils isSafeRelativePath:overridesDir]) {
        [downloader finishDownloadWithErrorString:@"Modpack declares an invalid overrides folder."];
        return;
    }
    [ModpackUtils archive:archive extractDirectory:overridesDir toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract %@ from modpack package: %@", overridesDir, error.localizedDescription]];
        return;
    }

    // Delete package cache
    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];

    NSDictionary *deps = [self dependenciesFromMinecraft:manifest[@"minecraft"]];
    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:deps];
    [ModpackUtils downloadVersionJsonForDependencyInfo:depInfo downloader:downloader];
    NSString *versionId = depInfo[@"id"] ?: info[@"mcVersion"];
    // Forge/NeoForge get installed right away, like Amethyst Android and Prism do
    versionId = [ModLoaderInstaller installIfNeededForVersionId:versionId downloader:downloader];

    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    NSData *iconData = [NSData dataWithContentsOfFile:tmpIconPath];
    [ModpackUtils createProfileNamed:info[@"name"]
        version:info[@"version"]
        gameDir:[NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent]
        versionId:versionId
        iconBase64:[iconData base64EncodedStringWithOptions:0]];

    if (blockedMods.count > 0) {
        NSDictionary *userInfo = @{
            @"pack": info[@"name"] ?: @"",
            @"mods": blockedMods,
            @"folder": [NSString stringWithFormat:@"./custom_gamedir/%@/mods", destPath.lastPathComponent]
        };
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter postNotificationName:CurseForgeBlockedModsNotification object:nil userInfo:userInfo];
        });
    }

    [downloader finishQueueingPackFiles];
}

@end
