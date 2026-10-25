#include <CommonCrypto/CommonDigest.h>

#import "installer/FabricUtils.h"
#import "ModpackUtils.h"
#import "PLProfiles.h"

NSString * const ModpackFormatModrinth = @"modrinth";
NSString * const ModpackFormatCurseForge = @"curseforge";
NSString * const ModpackFormatMultiMC = @"multimc";

static NSString * const kModrinthManifest = @"modrinth.index.json";
static NSString * const kCurseForgeManifest = @"manifest.json";
static NSString * const kMultiMCPack = @"mmc-pack.json";

@implementation ModpackUtils

+ (void)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path error:(NSError *__autoreleasing*)error {
    // Match "<dir>/..." exactly, so that "overrides" does not also pick up "overrides2/..."
    NSString *prefix = [dir hasSuffix:@"/"] ? dir : [dir stringByAppendingString:@"/"];
    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        if (![fileInfo.filename hasPrefix:prefix] ||
            fileInfo.filename.length <= prefix.length) {
            return;
        }
        NSString *fileName = [fileInfo.filename substringFromIndex:prefix.length];
        if (![self isSafeRelativePath:fileName]) {
            NSLog(@"[ModpackDL] Skipping unsafe path %@", fileInfo.filename);
            return;
        }
        NSString *destItemPath = [path stringByAppendingPathComponent:fileName];
        NSString *destDirPath = fileInfo.isDirectory ? destItemPath : destItemPath.stringByDeletingLastPathComponent;
        BOOL createdDir = [NSFileManager.defaultManager createDirectoryAtPath:destDirPath
            withIntermediateDirectories:YES
            attributes:nil error:error];
        if (!createdDir) {
            *stop = YES;
            return;
        } else if (fileInfo.isDirectory) {
            return;
        }

        NSData *data = [archive extractData:fileInfo error:error];
        BOOL written = [data writeToFile:destItemPath options:NSDataWritingAtomic error:error];
        *stop = !data || !written;
        if (!*stop) {
            NSLog(@"[ModpackDL] Extracted %@", fileInfo.filename);
        }
    } error:error];
}

+ (NSDictionary *)infoForDependencies:(NSDictionary *)dependency {
    NSMutableDictionary *info = [NSMutableDictionary new];
    NSString *minecraftVersion = dependency[@"minecraft"];
    if (dependency[@"forge"]) {
        info[@"id"] = [NSString stringWithFormat:@"%@-forge-%@", minecraftVersion, dependency[@"forge"]];
    } else if (dependency[@"neoforge"]) {
        info[@"id"] = [NSString stringWithFormat:@"neoforge-%@", dependency[@"neoforge"]];
    } else if (dependency[@"fabric-loader"]) {
        info[@"id"] = [NSString stringWithFormat:@"fabric-loader-%@-%@", dependency[@"fabric-loader"], minecraftVersion];
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Fabric"][@"json"], minecraftVersion, dependency[@"fabric-loader"]];
    } else if (dependency[@"quilt-loader"]) {
        info[@"id"] = [NSString stringWithFormat:@"quilt-loader-%@-%@", dependency[@"quilt-loader"], minecraftVersion];
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Quilt"][@"json"], minecraftVersion, dependency[@"quilt-loader"]];
    } else if (minecraftVersion) {
        // Vanilla pack (no mod loader)
        info[@"id"] = minecraftVersion;
    }
    return info;
}

#pragma mark - Import helpers

static NSError *ModpackError(NSString *message) {
    return [NSError errorWithDomain:@"ModpackImport" code:1
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

+ (NSString *)formatOfArchive:(UZKArchive *)archive extension:(NSString *)extension error:(NSError *__autoreleasing *)error {
    NSArray<NSString *> *names = [archive listFilenames:error];
    if (!names) {
        return nil;
    }
    BOOL isModrinth = [names containsObject:kModrinthManifest];
    BOOL isCurseForge = [names containsObject:kCurseForgeManifest];

    if (isModrinth && isCurseForge) {
        if ([extension.lowercaseString isEqualToString:@"mrpack"]) {
            return ModpackFormatModrinth;
        }
        if (error) *error = ModpackError(@"Ambiguous file contains both modrinth.index.json and manifest.json. Cannot determine modpack format.");
        return nil;
    }
    if (isModrinth) return ModpackFormatModrinth;
    if (isCurseForge) return ModpackFormatCurseForge;
    if ([self multiMCRootInFilenames:names]) return ModpackFormatMultiMC;

    if (error) *error = ModpackError(@"The selected file is not a modpack: it does not contain a manifest file.");
    return nil;
}

+ (NSDictionary *)manifestInfoForArchive:(UZKArchive *)archive format:(NSString *)format error:(NSError *__autoreleasing *)error {
    if ([format isEqualToString:ModpackFormatMultiMC]) {
        return [self multiMCInfoForArchive:archive error:error];
    }
    BOOL isModrinth = [format isEqualToString:ModpackFormatModrinth];
    NSData *data = [archive extractDataFromFile:(isModrinth ? kModrinthManifest : kCurseForgeManifest) error:error];
    if (!data) {
        return nil;
    }
    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:error];
    if (![manifest isKindOfClass:NSDictionary.class]) {
        if (error && !*error) *error = ModpackError(@"Corrupt modpack manifest file.");
        return nil;
    }

    NSString *name, *version, *mcVersion;
    if (isModrinth) {
        name = manifest[@"name"];
        version = manifest[@"versionId"];
        mcVersion = manifest[@"dependencies"][@"minecraft"];
    } else {
        name = manifest[@"name"];
        version = manifest[@"version"];
        mcVersion = manifest[@"minecraft"][@"version"];
    }
    // Same requirement as Android: all three must be present and non-blank.
    for (id value in @[name ?: NSNull.null, version ?: NSNull.null, mcVersion ?: NSNull.null]) {
        if (![value isKindOfClass:NSString.class] ||
            [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length == 0) {
            if (error) *error = ModpackError(@"Corrupt modpack manifest file.");
            return nil;
        }
    }
    return @{
        @"manifest": manifest,
        @"name": name,
        @"version": version,
        @"mcVersion": mcVersion
    };
}

+ (NSString *)sha1ForFileAtPath:(NSString *)path {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) {
        return nil;
    }
    CC_SHA1_CTX ctx;
    CC_SHA1_Init(&ctx);
    while (YES) {
        @autoreleasepool {
            NSData *chunk = [handle readDataOfLength:262144];
            if (chunk.length == 0) break;
            CC_SHA1_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
        }
    }
    [handle closeFile];

    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

+ (NSString *)sanitizedFileName:(NSString *)name {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"[\\\\/:*?\"<>| \\t\\n]" options:0 error:nil];
    NSString *result = [regex stringByReplacingMatchesInString:trimmed options:0 range:NSMakeRange(0, trimmed.length) withTemplate:@"_"];
    if (result.length > 255) {
        result = [result substringToIndex:255];
    }
    return result;
}

+ (BOOL)isSafeRelativePath:(NSString *)path {
    if (path.length == 0 || [path hasPrefix:@"/"] || [path hasPrefix:@"\\"]) {
        return NO;
    }
    for (NSString *component in [path componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\"]]) {
        if ([component isEqualToString:@".."]) {
            return NO;
        }
    }
    return YES;
}

+ (NSString *)createProfileNamed:(NSString *)name
                         version:(NSString *)packVersion
                         gameDir:(NSString *)gameDir
                       versionId:(NSString *)versionId
                      iconBase64:(NSString *)iconBase64 {
    // The profile key is what the launcher shows as its name. Don't clobber a different
    // instance that already uses the name (e.g. another version of the same pack).
    NSString *key = name;
    NSDictionary *existing = PLProfiles.current.profiles[key];
    if (existing && ![existing[@"gameDir"] isEqualToString:gameDir]) {
        key = [NSString stringWithFormat:@"%@ %@", name, packVersion ?: @""];
        key = [key stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSDictionary *existing2 = PLProfiles.current.profiles[key];
        if (existing2 && ![existing2[@"gameDir"] isEqualToString:gameDir]) {
            key = [NSString stringWithFormat:@"%@ (%@)", key, gameDir.lastPathComponent.length > 8 ?
                [gameDir.lastPathComponent substringFromIndex:gameDir.lastPathComponent.length - 8] : gameDir.lastPathComponent];
        }
    }

    NSMutableDictionary *profile = @{
        @"gameDir": gameDir,
        @"name": key,
        @"lastVersionId": versionId
    }.mutableCopy;
    if (iconBase64.length > 0) {
        profile[@"icon"] = [@"data:image/png;base64," stringByAppendingString:iconBase64];
    }
    PLProfiles.current.profiles[key] = profile;
    PLProfiles.current.selectedProfileName = key;
    return key;
}

#pragma mark - LWJGL3ify

+ (NSString *)installLWJGL3ifyVersionFromGameDir:(NSString *)gameDir {
    NSString *modsDir = [gameDir stringByAppendingPathComponent:@"mods"];
    NSString *jarName = nil;
    for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:modsDir error:nil]) {
        NSString *lower = file.lowercaseString;
        if ([lower hasPrefix:@"lwjgl3ify"] && [lower hasSuffix:@".jar"] && ![lower containsString:@"forgepatches"]) {
            jarName = file;
            break;
        }
    }
    if (!jarName) return nil;

    NSError *error;
    UZKArchive *jar = [[UZKArchive alloc] initWithPath:[modsDir stringByAppendingPathComponent:jarName] error:&error];
    NSData *versionData = [jar extractDataFromFile:@"me/eigenraven/lwjgl3ify/relauncher/version.json" error:&error];
    NSData *infoData = [jar extractDataFromFile:@"mcmod.info" error:&error];
    if (!versionData || !infoData) return nil;

    // mcmod.info is either {"modList":[{...}]} or [{...}]
    id info = [NSJSONSerialization JSONObjectWithData:infoData options:kNilOptions error:nil];
    NSDictionary *mod = [info isKindOfClass:NSDictionary.class] ? [info[@"modList"] firstObject] : [info firstObject];
    NSString *modVersion = [mod isKindOfClass:NSDictionary.class] ? mod[@"version"] : nil;
    NSMutableDictionary *versionJson = [NSJSONSerialization JSONObjectWithData:versionData options:NSJSONReadingMutableContainers error:nil];
    if (modVersion.length == 0 || ![versionJson isKindOfClass:NSMutableDictionary.class]) return nil;

    NSString *versionId = [@"1.7.10-LWJGL3ify-" stringByAppendingString:modVersion];
    NSString *dir = [NSString stringWithFormat:@"%s/versions/%@", getenv("GAME_DIR"), versionId];
    NSString *path = [dir stringByAppendingFormat:@"/%@.json", versionId];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        versionJson[@"id"] = versionId;
        NSData *out = [NSJSONSerialization dataWithJSONObject:versionJson options:0 error:nil];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        if (![out writeToFile:path atomically:YES]) return nil;
    }
    return versionId;
}

#pragma mark - Mod loader (Forge / NeoForge) installation

static NSString * const kPendingLoaderKey = @"pendingLoader";

+ (NSDictionary *)pendingLoaderForDependencies:(NSDictionary *)dependency {
    NSString *mc = dependency[@"minecraft"];
    if (dependency[@"forge"]) {
        return @{@"vendor": @"Forge", @"mc": mc ?: @"", @"version": dependency[@"forge"]};
    } else if (dependency[@"neoforge"]) {
        return @{@"vendor": @"NeoForge", @"mc": mc ?: @"", @"version": dependency[@"neoforge"]};
    }
    return nil;
}

static BOOL URLExists(NSString *url) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    request.HTTPMethod = @"HEAD";
    request.timeoutInterval = 20;
    __block BOOL exists = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        exists = [(NSHTTPURLResponse *)response statusCode] == 200;
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return exists;
}

+ (NSString *)installerURLForLoader:(NSDictionary *)loader {
    NSString *mc = loader[@"mc"], *version = loader[@"version"];
    if ([loader[@"vendor"] isEqualToString:@"NeoForge"]) {
        NSString *url = [NSString stringWithFormat:@"https://maven.neoforged.net/releases/net/neoforged/neoforge/%1$@/neoforge-%1$@-installer.jar", version];
        return URLExists(url) ? url : nil;
    }
    // Forge's maven version is "<mc>-<forge>", but old releases (1.7.10, 1.8.x, ...) carry a
    // "-<mc>" suffix as well, which is how Android's version search finds them.
    for (NSString *full in @[[NSString stringWithFormat:@"%@-%@", mc, version],
                             [NSString stringWithFormat:@"%@-%@-%@", mc, version, mc]]) {
        NSString *url = [NSString stringWithFormat:@"https://maven.minecraftforge.net/net/minecraftforge/forge/%1$@/forge-%1$@-installer.jar", full];
        if (URLExists(url)) return url;
    }
    return nil;
}

+ (void)markProfile:(NSString *)profileKey pendingLoader:(NSDictionary *)loader {
    NSMutableDictionary *profile = PLProfiles.current.profiles[profileKey];
    if (!profile) return;
    profile[kPendingLoaderKey] = [NSString stringWithFormat:@"%@|%@|%@", loader[@"vendor"], loader[@"mc"], loader[@"version"]];
    [PLProfiles.current save];
}

+ (void)fixupPendingLoaderProfiles {
    NSString *versionsDir = [@(getenv("GAME_DIR")) stringByAppendingPathComponent:@"versions"];
    NSArray<NSString *> *folders = [NSFileManager.defaultManager contentsOfDirectoryAtPath:versionsDir error:nil];
    BOOL changed = NO;
    for (NSString *key in PLProfiles.current.profiles.allKeys) {
        NSMutableDictionary *profile = PLProfiles.current.profiles[key];
        NSArray<NSString *> *parts = [profile[kPendingLoaderKey] componentsSeparatedByString:@"|"];
        if (parts.count != 3) continue;
        BOOL neo = [parts[0] isEqualToString:@"NeoForge"];
        for (NSString *folder in folders) {
            NSString *lower = folder.lowercaseString;
            BOOL isNeoFolder = [lower hasPrefix:@"neoforge"];
            if (neo != isNeoFolder || ![lower containsString:parts[2].lowercaseString]) continue;
            if (!neo && (![lower containsString:@"forge"] || ![folder containsString:parts[1]])) continue;
            // Only adopt folders that actually contain a version json
            NSString *json = [NSString stringWithFormat:@"%@/%@/%@.json", versionsDir, folder, folder];
            if (![NSFileManager.defaultManager fileExistsAtPath:json]) continue;
            profile[@"lastVersionId"] = folder;
            [profile removeObjectForKey:kPendingLoaderKey];
            changed = YES;
            break;
        }
    }
    if (changed) [PLProfiles.current save];
}


#pragma mark - MultiMC / Prism instance exports

+ (NSString *)multiMCRootInFilenames:(NSArray<NSString *> *)names {
    // mmc-pack.json sits either at the top of the zip or inside a single instance folder
    NSString *best = nil;
    for (NSString *name in names) {
        if (![name isKindOfClass:NSString.class] || ![name.lastPathComponent isEqualToString:kMultiMCPack]) continue;
        NSString *root = [name substringToIndex:name.length - kMultiMCPack.length];
        if (root.length > 0 && ([root componentsSeparatedByString:@"/"].count != 2 || ![self isSafeRelativePath:root])) continue;
        if (!best || root.length < best.length) best = root;
    }
    return best;
}

+ (NSDictionary *)parseInstanceConfig:(NSData *)data {
    NSMutableDictionary *config = [NSMutableDictionary new];
    NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    for (NSString *rawLine in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSRange eq = [line rangeOfString:@"="];
        if (line.length == 0 || [line hasPrefix:@"["] || [line hasPrefix:@"#"] || eq.location == NSNotFound) continue;
        config[[line substringToIndex:eq.location]] = [line substringFromIndex:eq.location + 1];
    }
    return config;
}

+ (NSDictionary *)multiMCInfoForArchive:(UZKArchive *)archive error:(NSError *__autoreleasing *)error {
    NSArray<NSString *> *names = [archive listFilenames:error];
    NSString *root = names ? [self multiMCRootInFilenames:names] : nil;
    if (!root) {
        if (error && !*error) *error = ModpackError(@"The selected file is not a modpack: it does not contain a manifest file.");
        return nil;
    }
    NSData *data = [archive extractDataFromFile:[root stringByAppendingString:kMultiMCPack] error:error];
    NSDictionary *pack = data ? [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:error] : nil;
    if (![pack isKindOfClass:NSDictionary.class] || ![pack[@"components"] isKindOfClass:NSArray.class]) {
        if (error) *error = ModpackError(@"Corrupt mmc-pack.json in this instance export.");
        return nil;
    }
    NSDictionary *deps = [self dependenciesForMultiMCPack:pack];
    NSString *mcVersion = deps[@"minecraft"];
    if (mcVersion.length == 0) {
        if (error) *error = ModpackError(@"mmc-pack.json does not say which Minecraft version this instance uses.");
        return nil;
    }
    NSDictionary *config = [self parseInstanceConfig:
        [archive extractDataFromFile:[root stringByAppendingString:@"instance.cfg"] error:nil]];
    NSString *name = [config[@"name"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (name.length == 0) {
        name = root.length > 0 ? [root substringToIndex:root.length - 1] : @"Imported instance";
    }
    if (error) *error = nil;
    return @{
        @"manifest": pack,
        @"name": name,
        @"version": @"",
        @"mcVersion": mcVersion,
        @"root": root,
        @"instanceConfig": config,
        @"dependencies": deps
    };
}

+ (NSDictionary *)dependenciesForMultiMCPack:(NSDictionary *)pack {
    // Map MultiMC component uids onto the modrinth.index.json dependency keys used elsewhere
    NSDictionary *keys = @{
        @"net.minecraft": @"minecraft",
        @"net.minecraftforge": @"forge",
        @"net.neoforged": @"neoforge",
        @"net.fabricmc.fabric-loader": @"fabric-loader",
        @"org.quiltmc.quilt-loader": @"quilt-loader"
    };
    NSMutableDictionary *deps = [NSMutableDictionary new];
    for (NSDictionary *component in pack[@"components"]) {
        if (![component isKindOfClass:NSDictionary.class]) continue;
        NSString *key = keys[component[@"uid"]];
        NSString *version = component[@"version"] ?: component[@"cachedVersion"];
        if (key && [version isKindOfClass:NSString.class] && version.length > 0) {
            deps[key] = version;
        }
    }
    return deps;
}

@end
