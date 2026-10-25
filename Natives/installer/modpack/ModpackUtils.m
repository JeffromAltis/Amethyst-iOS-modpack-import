#include <CommonCrypto/CommonDigest.h>

#import "installer/FabricUtils.h"
#import "ModpackUtils.h"
#import "PLProfiles.h"

NSString * const ModpackFormatModrinth = @"modrinth";
NSString * const ModpackFormatCurseForge = @"curseforge";

static NSString * const kModrinthManifest = @"modrinth.index.json";
static NSString * const kCurseForgeManifest = @"manifest.json";

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

    if (error) *error = ModpackError(@"The selected file is not a modpack: it does not contain a manifest file.");
    return nil;
}

+ (NSDictionary *)manifestInfoForArchive:(UZKArchive *)archive format:(NSString *)format error:(NSError *__autoreleasing *)error {
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
