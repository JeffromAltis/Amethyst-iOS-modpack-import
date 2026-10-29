#import "MinecraftResourceDownloadTask.h"
#import "LWJGL3ifyUtils.h"
#import "ModLoaderInstaller.h"
#import "MultiMCAPI.h"
#import "PLProfiles.h"

@implementation MultiMCAPI

- (instancetype)init {
    return [super initWithURL:nil];
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary *)filters previousPageResult:(NSMutableArray *)prevResult {
    return nil; // import only
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
}

/// The "dependencies" dictionary ModpackUtils understands, from the instance's components.
- (NSDictionary *)dependenciesForPack:(NSDictionary *)pack minecraftVersion:(NSString *)mcVersion {
    NSMutableDictionary *deps = [@{@"minecraft": mcVersion} mutableCopy];
    NSDictionary<NSString *, NSString *> *loaders = @{
        @"net.minecraftforge": @"forge",
        @"net.neoforged": @"neoforge",
        @"net.fabricmc.fabric-loader": @"fabric-loader",
        @"org.quiltmc.quilt-loader": @"quilt-loader"
    };
    for (NSString *uid in loaders) {
        NSString *version = [ModpackUtils versionOfComponent:uid inMultiMCPack:pack];
        if (version.length > 0) deps[loaders[uid]] = version;
    }
    return deps;
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    NSDictionary *info = archive ? [ModpackUtils manifestInfoForArchive:archive format:ModpackFormatMultiMC error:&error] : nil;
    if (!info) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to read the instance: %@", error.localizedDescription]];
        return;
    }
    NSString *root = info[@"root"];

    // The game folder is ".minecraft" (Prism, newer MultiMC) or "minecraft" (older MultiMC)
    NSArray<NSString *> *names = [archive listFilenames:&error];
    if (!names) {
        [downloader finishDownloadWithErrorString:error.localizedDescription ?: @"Could not list the instance archive."];
        return;
    }
    NSMutableArray<NSString *> *gameFolders = [NSMutableArray new];
    for (NSString *folder in @[@".minecraft", @"minecraft"]) {
        NSString *prefix = [NSString stringWithFormat:@"%@%@/", root, folder];
        for (NSString *name in names) {
            if ([name hasPrefix:prefix]) {
                [gameFolders addObject:[prefix substringToIndex:prefix.length - 1]];
                break;
            }
        }
    }
    if (gameFolders.count > 1) {
        [downloader finishDownloadWithErrorString:@"This instance contains both .minecraft and minecraft folders. Choose an export with one game folder to avoid mixing their files."];
        return;
    }
    // A metadata-only vanilla/loader instance is valid; its game folder is created at launch.

    for (NSString *folder in gameFolders) {
        [ModpackUtils archive:archive extractDirectory:folder toPath:destPath progress:downloader.progress error:&error];
        if (downloader.progress.cancelled) return;
        if (error) {
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract %@ from the instance: %@", folder, error.localizedDescription]];
            return;
        }
    }
    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];

    NSDictionary *deps = [self dependenciesForPack:info[@"manifest"] minecraftVersion:info[@"mcVersion"]];
    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:deps];

    // Same as Modrinth packs: loader-less 1.7.10 instances that carry lwjgl3ify (GT New Horizons)
    // run through the launch profile inside the lwjgl3ify jar
    NSString *versionId = depInfo[@"id"] ?: info[@"mcVersion"];
    if (!depInfo[@"json"]) {
        versionId = [LWJGL3ifyUtils versionIdForModpackGameDirectory:destPath versionId:versionId downloader:downloader];
        if (!versionId) {
            return;
        }
    }

    [ModpackUtils downloadVersionJsonForDependencyInfo:depInfo downloader:downloader];
    // Forge/NeoForge get installed right away, like Amethyst Android and Prism do
    versionId = [ModLoaderInstaller installIfNeededForVersionId:versionId downloader:downloader];

    // Prism keeps the icon as a bundled image we have no use for; the profile gets the default one
    if (downloader.progress.cancelled) return;
    NSString *profileName = [ModpackUtils createProfileNamed:info[@"name"]
        version:info[@"version"]
        gameDir:[NSString stringWithFormat:@"./instances/%@", destPath.lastPathComponent]
        versionId:versionId
        iconBase64:nil error:&error];

    if (!profileName) {
        [downloader finishDownloadWithErrorString:error.localizedDescription ?: @"Could not save the imported instance profile."];
        return;
    }
    [downloader finishQueueingPackFiles];
}

@end
