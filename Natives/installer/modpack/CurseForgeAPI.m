#import "config.h"
#import "CurseForgeAPI.h"
#import "MinecraftResourceDownloadTask.h"
#import "ModLoaderInstaller.h"
#import "ModpackUtils.h"

// Files per POST /mods/files request
#define kCurseForgeBatchSize 100
#define kCurseForgeHashAlgoSHA1 1

@implementation CurseForgeAPI

- (instancetype)init {
    self = [super initWithURL:@"https://api.curseforge.com/v1"];
    self.apiKey = @(CONFIG_CURSEFORGE_API_KEY);
    return self;
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary *)filters previousPageResult:(NSMutableArray *)prevResult {
    self.lastError = [NSError errorWithDomain:@"CurseForgeAPI" code:1
        userInfo:@{NSLocalizedDescriptionKey: @"Searching CurseForge is not supported yet."}];
    return nil;
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    // Unsupported, see searchModWithFilters
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
    for (NSDictionary *file in files) {
        NSDictionary *data = fileData[file[@"fileID"]];
        NSString *url = data ? [self downloadURLForFileData:data] : nil;
        NSString *fileName = data[@"fileName"];
        if (!url || ![ModpackUtils isSafeRelativePath:fileName]) {
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
    if (depInfo[@"json"]) {
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("GAME_DIR"), depInfo[@"id"]];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] size:1 sha:nil altName:nil toPath:jsonPath]; // size 1 is a placeholder so it is counted immediately; the real size is picked up when it completes
        if (task) {
            [task resume];
        }
    }
    NSString *versionId = depInfo[@"id"] ?: info[@"mcVersion"];
    // Forge/NeoForge get installed right away, like Amethyst Android and Prism do
    if ([ModLoaderInstaller needsInstallForVersionId:versionId]) {
        NSError *loaderError;
        NSString *installedVersion = [ModLoaderInstaller installLoaderForVersionId:versionId downloader:downloader error:&loaderError];
        if (installedVersion) {
            versionId = installedVersion;
        } else {
            // Keep the pack: pressing Play tries again and reports what went wrong
            NSLog(@"[ModpackDL] Could not install %@ yet: %@", versionId, loaderError.localizedDescription);
        }
    }

    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    NSData *iconData = [NSData dataWithContentsOfFile:tmpIconPath];
    [ModpackUtils createProfileNamed:info[@"name"]
        version:info[@"version"]
        gameDir:[NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent]
        versionId:versionId
        iconBase64:[iconData base64EncodedStringWithOptions:0]];

    [downloader finishQueueingPackFiles];
}

@end
