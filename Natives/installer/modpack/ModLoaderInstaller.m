#import "MinecraftResourceDownloadTask.h"
#import "MinecraftResourceUtils.h"
#import "ModLoaderInstaller.h"
#import "ModpackUtils.h"
#import "UnzipKit.h"
#import "utils.h"

/// Read by ModLoaderPostInstall.java; keep the name and keys in sync.
static NSString * const kPostInstallMarker = @"amethyst-postinstall.json";

static NSError *LoaderError(NSString *message) {
    return [NSError errorWithDomain:@"ModLoaderInstaller" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *GameDirectory(void) {
    return @(getenv("GAME_DIR"));
}

static NSString *LibrariesDirectory(void) {
    return [GameDirectory() stringByAppendingPathComponent:@"libraries"];
}

static NSString *VersionJSONPath(NSString *versionId) {
    return [NSString stringWithFormat:@"%1$@/versions/%2$@/%2$@.json", GameDirectory(), versionId];
}

@implementation ModLoaderInstaller

#pragma mark - Version ids

/// Where the installer for `versionId` can be downloaded from, most likely first. Each entry is
/// @{url, path} (path relative to libraries/). nil if the id is not a Forge/NeoForge one.
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)installerCandidatesForVersionId:(NSString *)versionId {
    NSMutableArray *candidates = [NSMutableArray new];
    void (^add)(NSString *, NSString *, NSString *, NSString *) = ^(NSString *repo, NSString *group, NSString *artifact, NSString *version) {
        NSString *path = [NSString stringWithFormat:@"%@/%@/%@/%@-%@-installer.jar",
            [group stringByReplacingOccurrencesOfString:@"." withString:@"/"], artifact, version, artifact, version];
        [candidates addObject:@{@"url": [repo stringByAppendingString:path], @"path": path}];
    };

    if ([versionId hasPrefix:@"neoforge-"]) {
        NSString *version = [versionId substringFromIndex:@"neoforge-".length];
        if (version.length == 0) return nil;
        if ([version hasPrefix:@"47."]) {
            // NeoForge for 1.20.1 was still published as net.neoforged:forge:1.20.1-47.1.x
            add(@"https://maven.neoforged.net/releases/", @"net.neoforged", @"forge", [@"1.20.1-" stringByAppendingString:version]);
        }
        add(@"https://maven.neoforged.net/releases/", @"net.neoforged", @"neoforge", version);
        return candidates;
    }

    NSRange forge = [versionId rangeOfString:@"-forge-"];
    if (forge.location == NSNotFound || forge.location == 0 || NSMaxRange(forge) >= versionId.length) {
        return nil;
    }
    NSString *mcVersion = [versionId substringToIndex:forge.location];
    NSString *version = [versionId substringFromIndex:NSMaxRange(forge)];
    NSString *repo = @"https://maven.minecraftforge.net/";
    if ([version hasPrefix:[mcVersion stringByAppendingString:@"-"]]) {
        add(repo, @"net.minecraftforge", @"forge", version);
    } else {
        add(repo, @"net.minecraftforge", @"forge", [NSString stringWithFormat:@"%@-%@", mcVersion, version]);
        // 1.7.10 and some 1.8.x/1.9.x builds carry the Minecraft version again as a suffix
        add(repo, @"net.minecraftforge", @"forge", [NSString stringWithFormat:@"%@-%@-%@", mcVersion, version, mcVersion]);
    }
    return candidates;
}

+ (BOOL)isLoaderVersionId:(NSString *)versionId {
    return [versionId isKindOfClass:NSString.class] && [self installerCandidatesForVersionId:versionId].count > 0;
}

+ (BOOL)needsInstallForVersionId:(NSString *)versionId {
    return [self isLoaderVersionId:versionId] &&
        ![NSFileManager.defaultManager fileExistsAtPath:VersionJSONPath(versionId)];
}

#pragma mark - Downloading

/// Synchronous download into `destPath`. Returns NO (with `error`, or `*notFound` for a 404).
+ (BOOL)downloadURL:(NSString *)url toPath:(NSString *)destPath notFound:(BOOL *)notFound error:(NSError **)error {
    __block NSError *taskError;
    __block NSInteger status = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURLSessionDownloadTask *task = [NSURLSession.sharedSession downloadTaskWithURL:[NSURL URLWithString:url]
    completionHandler:^(NSURL *location, NSURLResponse *response, NSError *responseError) {
        status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        taskError = responseError;
        if (!taskError && status == 200) {
            // The temporary file is deleted when this handler returns, so move it now
            NSFileManager *fm = NSFileManager.defaultManager;
            NSString *partPath = [destPath stringByAppendingString:@".part"];
            [fm createDirectoryAtPath:destPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            [fm removeItemAtPath:partPath error:nil];
            if ([fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:partPath] error:&taskError]) {
                [fm removeItemAtPath:destPath error:nil];
                [fm moveItemAtPath:partPath toPath:destPath error:&taskError];
            }
        }
        dispatch_semaphore_signal(done);
    }];
    [task resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);

    if (notFound) *notFound = status == 404;
    if (taskError) {
        if (error) *error = taskError;
        return NO;
    }
    if (status != 200) {
        if (error) *error = LoaderError([NSString stringWithFormat:@"HTTP %ld for %@", (long)status, url]);
        return NO;
    }
    return YES;
}

/// Downloads the installer (or reuses a previous download). Returns its path relative to libraries/.
+ (NSString *)fetchInstallerForVersionId:(NSString *)versionId error:(NSError **)error {
    NSArray<NSDictionary<NSString *, NSString *> *> *candidates = [self installerCandidatesForVersionId:versionId];
    for (NSDictionary<NSString *, NSString *> *candidate in candidates) {
        NSString *path = [LibrariesDirectory() stringByAppendingPathComponent:candidate[@"path"]];
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
            // Only complete downloads are moved into place, but make sure it is a readable jar
            UZKArchive *existing = [[UZKArchive alloc] initWithPath:path error:nil];
            if ([existing listFilenames:nil] != nil) {
                return candidate[@"path"];
            }
        }
        NSLog(@"[ModLoaderInstaller] Downloading %@", candidate[@"url"]);
        BOOL notFound = NO;
        NSError *downloadError;
        if ([self downloadURL:candidate[@"url"] toPath:path notFound:&notFound error:&downloadError]) {
            return candidate[@"path"];
        }
        if (!notFound) {
            if (error) *error = downloadError;
            return nil;
        }
    }
    if (error) *error = LoaderError([NSString stringWithFormat:@"No installer was found for %@.", versionId]);
    return nil;
}

#pragma mark - Installing

+ (NSDictionary *)JSONInArchive:(UZKArchive *)archive file:(NSString *)file error:(NSError **)error {
    NSData *data = [archive extractDataFromFile:file error:error];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:error] : nil;
    if (![json isKindOfClass:NSDictionary.class]) {
        if (error && !*error) *error = LoaderError([NSString stringWithFormat:@"The installer's %@ is unreadable.", file]);
        return nil;
    }
    return json;
}

+ (BOOL)writeVersion:(NSDictionary *)version error:(NSError **)error {
    NSString *versionId = version[@"id"];
    if (![versionId isKindOfClass:NSString.class] || ![ModpackUtils isSafeRelativePath:versionId] ||
        [versionId containsString:@"/"]) {
        if (error) *error = LoaderError(@"The installer's version profile has no valid id.");
        return NO;
    }
    NSString *path = VersionJSONPath(versionId);
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:nil];
    NSError *saveError = saveJSONToFile(version, path);
    if (saveError) {
        if (error) *error = saveError;
        return NO;
    }
    return YES;
}

/// Forge for Minecraft 1.12.2 and older: the profile is "versionInfo" and the only file to
/// install is the universal jar inside the installer.
+ (NSString *)installLegacyProfile:(NSDictionary *)profile archive:(UZKArchive *)archive error:(NSError **)error {
    NSDictionary *install = profile[@"install"];
    NSString *libraryPath = [install[@"path"] isKindOfClass:NSString.class] ?
        [MinecraftResourceUtils pathForLibraryName:install[@"path"]] : nil;
    NSString *fileName = install[@"filePath"];
    if (libraryPath && [fileName isKindOfClass:NSString.class] && [ModpackUtils isSafeRelativePath:fileName]) {
        NSData *jar = [archive extractDataFromFile:fileName error:error];
        NSString *dest = [LibrariesDirectory() stringByAppendingPathComponent:libraryPath];
        [NSFileManager.defaultManager createDirectoryAtPath:dest.stringByDeletingLastPathComponent
            withIntermediateDirectories:YES attributes:nil error:nil];
        if (!jar || ![jar writeToFile:dest options:NSDataWritingAtomic error:error]) {
            return nil;
        }
    }
    NSDictionary *version = profile[@"versionInfo"];
    return [self writeVersion:version error:error] ? version[@"id"] : nil;
}

/// Minecraft 1.13+ Forge and NeoForge (install profile spec 0/1).
+ (NSString *)installModernProfile:(NSDictionary *)profile
                         archive:(UZKArchive *)archive
                   installerPath:(NSString *)installerPath
                      downloader:(MinecraftResourceDownloadTask *)downloader
                           error:(NSError **)error {
    NSString *versionFile = [profile[@"json"] isKindOfClass:NSString.class] ? profile[@"json"] : @"/version.json";
    if ([versionFile hasPrefix:@"/"]) versionFile = [versionFile substringFromIndex:1];
    NSMutableDictionary *version = (NSMutableDictionary *)[self JSONInArchive:archive file:versionFile error:error];
    if (!version) {
        return nil;
    }

    // Files the installer carries itself (e.g. the loader's own jars) go straight to libraries/
    NSError *extractError;
    [ModpackUtils archive:archive extractDirectory:@"maven" toPath:LibrariesDirectory() error:&extractError];
    if (extractError) {
        if (error) *error = extractError;
        return nil;
    }

    // Libraries the processors run with. The game's own libraries are fetched at launch as usual.
    for (NSDictionary *library in profile[@"libraries"]) {
        NSDictionary *artifact = [library isKindOfClass:NSDictionary.class] ? library[@"downloads"][@"artifact"] : nil;
        NSString *url = artifact[@"url"], *path = artifact[@"path"];
        if (!downloader || ![url isKindOfClass:NSString.class] || url.length == 0 ||
            ![path isKindOfClass:NSString.class] || ![ModpackUtils isSafeRelativePath:path]) {
            continue; // bundled in maven/, or fetched by ModLoaderPostInstall at launch
        }
        NSString *sha = [artifact[@"sha1"] isKindOfClass:NSString.class] ? artifact[@"sha1"] : nil;
        // A size of 0 would only be counted once the server answers; 1 keeps the progress honest meanwhile
        NSUInteger size = MAX([artifact[@"size"] unsignedLongLongValue], 1);
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url size:size sha:sha altName:nil
            toPath:[LibrariesDirectory() stringByAppendingPathComponent:path]];
        [task resume];
    }

    if (![self writeVersion:version error:error]) {
        return nil;
    }
    NSString *versionId = version[@"id"];

    BOOL hasClientProcessors = NO;
    for (NSDictionary *processor in profile[@"processors"]) {
        NSArray *sides = [processor isKindOfClass:NSDictionary.class] ? processor[@"sides"] : nil;
        if (![sides isKindOfClass:NSArray.class] || [sides containsObject:@"client"]) {
            hasClientProcessors = YES;
            break;
        }
    }
    NSString *markerPath = [VersionJSONPath(versionId).stringByDeletingLastPathComponent stringByAppendingPathComponent:kPostInstallMarker];
    if (hasClientProcessors) {
        NSString *minecraft = [profile[@"minecraft"] isKindOfClass:NSString.class] ? profile[@"minecraft"] : version[@"inheritsFrom"];
        NSError *saveError = saveJSONToFile(@{
            @"installer": installerPath,
            @"minecraft": minecraft ?: @""
        }, markerPath);
        if (saveError) {
            if (error) *error = saveError;
            return nil;
        }
    } else {
        [NSFileManager.defaultManager removeItemAtPath:markerPath error:nil];
    }
    return versionId;
}

+ (NSString *)installLoaderForVersionId:(NSString *)versionId
                             downloader:(MinecraftResourceDownloadTask *)downloader
                                  error:(NSError **)error {
    NSString *installerPath = [self fetchInstallerForVersionId:versionId error:error];
    if (!installerPath) {
        return nil;
    }
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:[LibrariesDirectory() stringByAppendingPathComponent:installerPath] error:error];
    NSDictionary *profile = archive ? [self JSONInArchive:archive file:@"install_profile.json" error:error] : nil;
    if (!profile) {
        return nil;
    }

    NSString *installed;
    if ([profile[@"versionInfo"] isKindOfClass:NSDictionary.class]) {
        installed = [self installLegacyProfile:profile archive:archive error:error];
    } else {
        installed = [self installModernProfile:profile archive:archive installerPath:installerPath downloader:downloader error:error];
    }
    if (installed) {
        NSLog(@"[ModLoaderInstaller] Installed %@ as version %@", versionId, installed);
    }
    return installed;
}

@end
