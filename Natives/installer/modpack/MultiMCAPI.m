#import "MinecraftResourceDownloadTask.h"
#import "MultiMCAPI.h"

@implementation MultiMCAPI

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    NSDictionary *info = archive ? [ModpackUtils manifestInfoForArchive:archive format:ModpackFormatMultiMC error:&error] : nil;
    if (!info) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to read instance export: %@", error.localizedDescription ?: @"unknown error"]];
        return;
    }
    NSString *root = info[@"root"];
    NSArray<NSString *> *names = [archive listFilenames:nil];

    // Game files live in "<instance>/.minecraft" (older MultiMC exports use "minecraft")
    NSString *gameFilesDir = nil;
    for (NSString *candidate in @[@".minecraft", @"minecraft"]) {
        NSString *prefix = [NSString stringWithFormat:@"%@%@/", root, candidate];
        for (NSString *name in names) {
            if ([name hasPrefix:prefix] && name.length > prefix.length) {
                gameFilesDir = [root stringByAppendingString:candidate];
                break;
            }
        }
        if (gameFilesDir) break;
    }
    if (gameFilesDir) {
        error = nil;
        [ModpackUtils archive:archive extractDirectory:gameFilesDir toPath:destPath error:&error];
        if (error) {
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract %@ from instance export: %@", gameFilesDir, error.localizedDescription]];
            return;
        }
    } else {
        NSLog(@"[ModpackDL] Instance export has no .minecraft folder; creating an empty instance");
        [NSFileManager.defaultManager createDirectoryAtPath:destPath withIntermediateDirectories:YES attributes:nil error:nil];
    }

    // Instance icon: instance.cfg's iconKey names a png next to it
    NSData *iconData = nil;
    NSString *iconKey = info[@"instanceConfig"][@"iconKey"];
    if (iconKey.length > 0 && [ModpackUtils isSafeRelativePath:iconKey]) {
        iconData = [archive extractDataFromFile:[NSString stringWithFormat:@"%@%@.png", root, iconKey] error:nil];
    }
    if (!iconData) {
        for (NSString *name in names) {
            NSString *rel = [name substringFromIndex:MIN(root.length, name.length)];
            if ([name hasPrefix:root] && [rel.pathExtension.lowercaseString isEqualToString:@"png"] && ![rel containsString:@"/"]) {
                iconData = [archive extractDataFromFile:name error:nil];
                break;
            }
        }
    }

    // Delete package cache
    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];

    NSDictionary *deps = info[@"dependencies"];
    NSDictionary *depInfo = [ModpackUtils infoForDependencies:deps];
    NSDictionary *loader = [ModpackUtils pendingLoaderForDependencies:deps];
    NSString *profileVersionId = depInfo[@"id"] ?: info[@"mcVersion"];
    BOOL queuedAny = NO;

    // GTNH's Java 17+ exports list Forge, but actually launch through lwjgl3ify's own profile
    NSString *lwjgl3ifyId = [ModpackUtils installLWJGL3ifyVersionFromGameDir:destPath];
    if (lwjgl3ifyId) {
        profileVersionId = lwjgl3ifyId;
        loader = nil;
    } else if (depInfo[@"json"]) {
        // Fabric / Quilt: only the version JSON is needed
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("GAME_DIR"), depInfo[@"id"]];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] size:0 sha:nil altName:nil toPath:jsonPath];
        if (task) {
            queuedAny = YES;
            [task resume];
        }
    }

    NSString *profileKey = [ModpackUtils createProfileNamed:info[@"name"]
        version:info[@"version"]
        gameDir:[NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent]
        versionId:profileVersionId
        iconBase64:[iconData base64EncodedStringWithOptions:0]];
    if (loader) {
        [ModpackUtils markProfile:profileKey pendingLoader:loader];
        downloader.pendingLoader = loader;
    }

    if (!queuedAny) {
        [downloader completeIfNothingQueued];
    }
}

@end
