#include <CommonCrypto/CommonDigest.h>

#import "installer/FabricUtils.h"
#import "ModpackUtils.h"
#import "PLProfiles.h"

NSString * const ModpackFormatModrinth = @"modrinth";
NSString * const ModpackFormatCurseForge = @"curseforge";
NSString * const ModpackFormatMultiMC = @"multimc";

static NSString * const kModrinthManifest = @"modrinth.index.json";
static NSString * const kCurseForgeManifest = @"manifest.json";
static NSString * const kMultiMCManifest = @"mmc-pack.json";
static NSString * const kMultiMCConfig = @"instance.cfg";

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

/// The folder ("" or "<name>/") holding mmc-pack.json: the archive root, or a single top-level
/// folder (MultiMC exports and many downloadable instances wrap everything in one). nil if absent.
+ (NSString *)multiMCRootInFilenames:(NSArray<NSString *> *)names {
    NSString *best;
    for (NSString *name in names) {
        if (![name.lastPathComponent isEqualToString:kMultiMCManifest]) continue;
        NSArray<NSString *> *components = [name componentsSeparatedByString:@"/"];
        if (components.count > 2 || [components.firstObject isEqualToString:@"__MACOSX"]) continue;
        NSString *root = components.count == 2 ? [components.firstObject stringByAppendingString:@"/"] : @"";
        if (!best || root.length < best.length) best = root;
    }
    return best;
}

/// Parses instance.cfg (INI-style "key=value" lines, optionally under a [General] section).
+ (NSDictionary<NSString *, NSString *> *)parseInstanceConfig:(NSData *)data {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    NSMutableDictionary<NSString *, NSString *> *config = [NSMutableDictionary new];
    for (NSString *rawLine in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSRange equals = [line rangeOfString:@"="];
        if (line.length == 0 || [line hasPrefix:@"["] || [line hasPrefix:@"#"] || [line hasPrefix:@";"] || equals.location == NSNotFound) {
            continue;
        }
        NSString *key = [[line substringToIndex:equals.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *value = [[line substringFromIndex:equals.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        // Qt writes strings containing special characters in quotes
        if (value.length >= 2 && [value hasPrefix:@"\""] && [value hasSuffix:@"\""]) {
            value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
        }
        config[key] = value;
    }
    return config;
}

/// Version of the component with `uid` in an mmc-pack.json, or nil.
+ (NSString *)versionOfComponent:(NSString *)uid inMultiMCPack:(NSDictionary *)pack {
    id components = pack[@"components"];
    if (![components isKindOfClass:NSArray.class]) return nil;
    for (NSDictionary *component in components) {
        if (![component isKindOfClass:NSDictionary.class] || ![component[@"uid"] isEqual:uid]) continue;
        id version = component[@"version"] ?: component[@"cachedVersion"];
        return [version isKindOfClass:NSString.class] ? version : nil;
    }
    return nil;
}

+ (NSDictionary *)multiMCInfoForArchive:(UZKArchive *)archive error:(NSError *__autoreleasing *)error {
    NSArray<NSString *> *names = [archive listFilenames:error];
    NSString *root = names ? [self multiMCRootInFilenames:names] : nil;
    if (!root) {
        if (error && !*error) *error = ModpackError(@"The selected file is not a Prism Launcher/MultiMC instance.");
        return nil;
    }
    NSData *data = [archive extractDataFromFile:[root stringByAppendingString:kMultiMCManifest] error:error];
    NSDictionary *pack = data ? [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:error] : nil;
    NSString *mcVersion = [pack isKindOfClass:NSDictionary.class] ? [self versionOfComponent:@"net.minecraft" inMultiMCPack:pack] : nil;
    if (mcVersion.length == 0) {
        if (error && !*error) *error = ModpackError(@"Corrupt mmc-pack.json: no Minecraft version.");
        return nil;
    }

    NSDictionary *config = @{};
    NSString *configPath = [root stringByAppendingString:kMultiMCConfig];
    if ([names containsObject:configPath]) {
        NSData *configData = [archive extractDataFromFile:configPath error:nil];
        if (configData) config = [self parseInstanceConfig:configData];
    }
    // Instances made from a Modrinth/CurseForge pack remember its name and version
    NSString *name = config[@"ManagedPackName"].length > 0 ? config[@"ManagedPackName"] : config[@"name"];
    if (name.length == 0) {
        name = root.length > 0 ? [root substringToIndex:root.length - 1] : @"Imported instance";
    }
    NSString *version = config[@"ManagedPackVersionName"].length > 0 ? config[@"ManagedPackVersionName"] : mcVersion;
    return @{
        @"manifest": pack,
        @"name": name,
        @"version": version,
        @"mcVersion": mcVersion,
        @"root": root,
        @"instanceConfig": config
    };
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

@end
