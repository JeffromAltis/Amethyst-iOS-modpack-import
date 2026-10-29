#include <CommonCrypto/CommonDigest.h>
#include <limits.h>
#include <errno.h>
#include <stdio.h>

#import "installer/FabricUtils.h"
#import "MinecraftResourceDownloadTask.h"
#import "ModpackUtils.h"
#import "PLProfiles.h"
#import "ModpackPath.h"

NSString * const ModpackFormatModrinth = @"modrinth";
NSString * const ModpackFormatCurseForge = @"curseforge";
NSString * const ModpackFormatMultiMC = @"multimc";

static NSString * const kModrinthManifest = @"modrinth.index.json";
static NSString * const kCurseForgeManifest = @"manifest.json";
static NSString * const kMultiMCManifest = @"mmc-pack.json";
static NSString * const kMultiMCConfig = @"instance.cfg";

static NSError *ModpackError(NSString *message) {
    return [NSError errorWithDomain:@"ModpackImport" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL NonblankString(id value) {
    return [value isKindOfClass:NSString.class] && [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
}

static BOOL VersionComponent(id value) {
    return NonblankString(value) && ModpackRelativePathIsSafe([value UTF8String], [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) &&
        [value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\"]].location == NSNotFound;
}

static BOOL InvalidManifest(NSError **error, NSString *message) {
    if (error) *error = ModpackError(message);
    return NO;
}

static BOOL HexDigest(id value, NSUInteger length) {
    return [value isKindOfClass:NSString.class] && [value length] == length &&
        [value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"].invertedSet].location == NSNotFound;
}

@implementation ModpackUtils

+ (void)downloadVersionJsonForDependencyInfo:(NSDictionary<NSString *, NSString *> *)depInfo downloader:(MinecraftResourceDownloadTask *)downloader {
    if (!depInfo[@"json"]) {
        return;
    }
    NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("GAME_DIR"), depInfo[@"id"]];
    // size 1 is a placeholder so it is counted immediately; the real size is picked up when it completes
    [[downloader createDownloadTask:depInfo[@"json"] size:1 sha:nil altName:nil toPath:jsonPath] resume];
}


static void (^sStatusHandler)(NSString *, double);

+ (void (^)(NSString *, double))statusHandler {
    @synchronized (self) { return sStatusHandler; }
}

+ (void)setStatusHandler:(void (^)(NSString *, double))handler {
    @synchronized (self) { sStatusHandler = [handler copy]; }
}

+ (void)reportStatus:(NSString *)status fraction:(double)fraction {
    static CFAbsoluteTime lastReport;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    @synchronized (self) {
        BOOL edge = fraction <= 0 || fraction >= 1;
        if (!edge && now - lastReport < 0.1) return;
        lastReport = now;
    }
    void (^handler)(NSString *, double) = self.statusHandler;
    if (!handler) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(status, fraction);
    });
}

+ (BOOL)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path error:(NSError *__autoreleasing*)error {
    return [self archive:archive extractDirectory:dir toPath:path progress:nil error:error];
}

+ (BOOL)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path progress:(NSProgress *)progress error:(NSError **)error {
    if (progress.cancelled) return NO;
    // Match "<dir>/..." exactly, so that "overrides" does not also pick up "overrides2/..."
    NSString *prefix = [dir hasSuffix:@"/"] ? dir : [dir stringByAppendingString:@"/"];

    // Count what will be extracted first so the UI can show real progress
    __block NSUInteger total = 0;
    NSArray<UZKFileInfo *> *infos = [archive listFileInfo:error];
    if (!infos) {
        if (error && !*error) *error = ModpackError(@"Could not list the archive entries.");
        return NO;
    }
    for (UZKFileInfo *info in infos) {
        if (info.isDirectory && [info.filename hasPrefix:prefix] &&
            [[[info.filename substringFromIndex:prefix.length] stringByStandardizingPath] isEqualToString:@"."]) continue;
        if ([info.filename hasPrefix:prefix] && info.filename.length > prefix.length &&
            ![self destinationForRelativePath:[info.filename substringFromIndex:prefix.length] underDirectory:path error:error]) return NO;
        if ([info.filename hasPrefix:prefix] && info.filename.length > prefix.length && !info.isDirectory) total++;
    }
    __block NSUInteger done = 0;
    if (total > 0) {
        [self reportStatus:[NSString stringWithFormat:@"Extracting %lu files...", (unsigned long)total] fraction:0];
    }

    __block NSError *operationError;
    NSError *iterationError;
    BOOL enumerated = [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        if (progress.cancelled) { *stop = YES; return; }
        if (![fileInfo.filename hasPrefix:prefix] ||
            fileInfo.filename.length <= prefix.length) {
            return;
        }
        NSString *fileName = [fileInfo.filename substringFromIndex:prefix.length];
        if (fileInfo.isDirectory && [fileName.stringByStandardizingPath isEqualToString:@"."]) return;
        NSString *destItemPath = [self destinationForRelativePath:fileName underDirectory:path error:&operationError];
        if (!destItemPath) {
            *stop = YES;
            return;
        }
        NSString *destDirPath = fileInfo.isDirectory ? destItemPath : destItemPath.stringByDeletingLastPathComponent;
        BOOL createdDir = [NSFileManager.defaultManager createDirectoryAtPath:destDirPath
            withIntermediateDirectories:YES
            attributes:nil error:&operationError];
        if (!createdDir) {
            *stop = YES;
            return;
        } else if (fileInfo.isDirectory) {
            return;
        }

        // Large instances can contain files bigger than the app's memory budget.
        // Stream to a sibling file and publish it only after extraction succeeds.
        NSString *staged = [destDirPath stringByAppendingPathComponent:[@".import-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSOutputStream *output = [NSOutputStream outputStreamToFileAtPath:staged append:NO];
        [output open];
        NSError *readError;
        BOOL extracted = [archive extractBufferedDataFromFile:fileInfo.filename error:&readError action:^(NSData *chunk, CGFloat percent) {
            if (operationError || progress.cancelled) return;
            NSUInteger offset = 0;
            while (offset < chunk.length) {
                NSInteger written = [output write:(const uint8_t *)chunk.bytes + offset maxLength:chunk.length - offset];
                if (written <= 0) {
                    operationError = output.streamError ?: ModpackError(@"Could not write an extracted file.");
                    break;
                }
                offset += (NSUInteger)written;
            }
        }];
        if (readError && !operationError) operationError = readError;
        if (output.streamError && !operationError) operationError = output.streamError;
        [output close];
        if (!extracted && !operationError) operationError = ModpackError(@"An archive entry could not be read.");
        if (extracted && !operationError && !progress.cancelled &&
            rename(staged.fileSystemRepresentation, destItemPath.fileSystemRepresentation) != 0) {
            operationError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        }
        *stop = !extracted || operationError || progress.cancelled;
        if (*stop) [NSFileManager.defaultManager removeItemAtPath:staged error:nil];
        if (!*stop) {
            NSLog(@"[ModpackDL] Extracted %@", fileInfo.filename);
            done++;
            if (total > 0) {
                [self reportStatus:[NSString stringWithFormat:@"Extracting files... %lu / %lu", (unsigned long)done, (unsigned long)total]
                    fraction:(double)done / total];
            }
        }
    } error:&iterationError];
    if (operationError || iterationError || !enumerated) {
        if (error) *error = operationError ?: iterationError ?: ModpackError(@"Archive extraction failed.");
        return NO;
    }
    return !progress.cancelled;
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
    if ([names containsObject:kMultiMCManifest]) return @"";
    NSString *best;
    for (NSString *name in names) {
        if (![name.lastPathComponent isEqualToString:kMultiMCManifest]) continue;
        NSArray<NSString *> *components = [name componentsSeparatedByString:@"/"];
        if (components.count > 2 || [components.firstObject isEqualToString:@"__MACOSX"]) continue;
        NSString *root = components.count == 2 ? [components.firstObject stringByAppendingString:@"/"] : @"";
        if (![self isSafeRelativePath:root]) continue;
        if (best && ![best isEqualToString:root]) return nil;
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
        id version = [component[@"version"] isKindOfClass:NSString.class] ? component[@"version"] : component[@"cachedVersion"];
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
    if (![pack isKindOfClass:NSDictionary.class] || !mcVersion || !VersionComponent(mcVersion)) {
        if (error && !*error) *error = ModpackError(@"Corrupt mmc-pack.json: no Minecraft version.");
        return nil;
    }
    NSUInteger loaderCount = 0;
    for (NSString *uid in @[@"net.minecraftforge", @"net.neoforged", @"net.fabricmc.fabric-loader", @"org.quiltmc.quilt-loader"]) {
        NSString *version = [self versionOfComponent:uid inMultiMCPack:pack];
        BOOL declared = NO;
        for (id component in pack[@"components"]) {
            if ([component isKindOfClass:NSDictionary.class] && [component[@"uid"] isEqual:uid]) declared = YES;
        }
        if (declared && !VersionComponent(version)) {
            if (error) *error = ModpackError(@"The instance has an invalid mod loader version.");
            return nil;
        }
        if (version) loaderCount++;
    }
    if (loaderCount > 1) {
        if (error) *error = ModpackError(@"The instance declares multiple conflicting mod loaders.");
        return nil;
    }

    NSDictionary<NSString *, NSString *> *config = @{};
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
    if (![self validateManifest:manifest modrinth:isModrinth error:error]) return nil;

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
    if (!name || !version || !mcVersion || !NonblankString(name) || !NonblankString(version) || !NonblankString(mcVersion)) {
        if (error) *error = ModpackError(@"Corrupt modpack manifest file.");
        return nil;
    }
    return @{
        @"manifest": manifest,
        @"name": name,
        @"version": version,
        @"mcVersion": mcVersion
    };
}

+ (BOOL)validateManifest:(NSDictionary *)manifest modrinth:(BOOL)modrinth error:(NSError **)error {
    id game = manifest[modrinth ? @"dependencies" : @"minecraft"];
    if (![game isKindOfClass:NSDictionary.class] || !VersionComponent(game[modrinth ? @"minecraft" : @"version"])) {
        return InvalidManifest(error, @"The manifest has no valid Minecraft version or dependency object.");
    }
    if (![manifest[@"files"] isKindOfClass:NSArray.class]) return InvalidManifest(error, @"The manifest's files field must be an array.");
    if (modrinth) {
        if (![manifest[@"formatVersion"] isKindOfClass:NSNumber.class] || [manifest[@"formatVersion"] doubleValue] != 1 ||
            ![manifest[@"game"] isEqual:@"minecraft"]) return InvalidManifest(error, @"Unsupported Modrinth pack format or game.");
        NSSet *supported = [NSSet setWithArray:@[@"minecraft", @"forge", @"neoforge", @"fabric-loader", @"quilt-loader"]];
        NSUInteger loaders = 0;
        for (NSString *key in game) {
            if (![supported containsObject:key] || !VersionComponent(game[key])) return InvalidManifest(error, @"The pack declares an unsupported or invalid dependency.");
            if (![key isEqualToString:@"minecraft"]) loaders++;
        }
        if (loaders > 1) return InvalidManifest(error, @"The pack declares multiple conflicting mod loaders.");
    } else {
        if (![manifest[@"manifestType"] isEqual:@"minecraftModpack"] || ![manifest[@"manifestVersion"] isKindOfClass:NSNumber.class] ||
            [manifest[@"manifestVersion"] doubleValue] != 1) return InvalidManifest(error, @"Unsupported CurseForge manifest format.");
        id loaders = game[@"modLoaders"] ?: @[];
        if (![loaders isKindOfClass:NSArray.class]) return InvalidManifest(error, @"The manifest's modLoaders field must be an array.");
        NSUInteger primary = 0;
        for (id loader in loaders) {
            if (![loader isKindOfClass:NSDictionary.class] || !VersionComponent(loader[@"id"]) ||
                (loader[@"primary"] && ![loader[@"primary"] isKindOfClass:NSNumber.class])) return InvalidManifest(error, @"Invalid mod loader entry.");
            NSString *identifier = loader[@"id"];
            BOOL supported = NO;
            for (NSString *prefix in @[@"forge-", @"neoforge-", @"fabric-", @"quilt-"]) {
                if ([identifier hasPrefix:prefix] && identifier.length > prefix.length) supported = YES;
            }
            if (!supported) return InvalidManifest(error, @"The CurseForge pack requires an unsupported mod loader.");
            if ([loader[@"primary"] boolValue]) primary++;
        }
        if (primary > 1 || ([loaders count] > 1 && primary == 0)) return InvalidManifest(error, @"The pack has no unambiguous primary mod loader.");
        if (manifest[@"overrides"] && ![self isSafeRelativePath:manifest[@"overrides"]]) return InvalidManifest(error, @"Invalid overrides folder.");
    }
    NSMutableSet *paths = [NSMutableSet new];
    for (id file in manifest[@"files"]) {
        if (![file isKindOfClass:NSDictionary.class]) return InvalidManifest(error, @"A manifest file entry is not an object.");
        if (!modrinth) {
            for (NSString *key in @[@"projectID", @"fileID"]) {
                id value = file[key];
                if (![value isKindOfClass:NSNumber.class] || [value doubleValue] <= 0 || [value doubleValue] != floor([value doubleValue])) return InvalidManifest(error, @"A CurseForge file entry has an invalid project or file ID.");
            }
            if (file[@"required"] && ![file[@"required"] isKindOfClass:NSNumber.class]) return InvalidManifest(error, @"Invalid required flag in a CurseForge file entry.");
            if ([paths containsObject:file[@"fileID"]]) return InvalidManifest(error, @"The CurseForge manifest repeats a file ID.");
            [paths addObject:file[@"fileID"]];
            continue;
        }
        if (![self isSafeRelativePath:file[@"path"]]) return InvalidManifest(error, @"A Modrinth file has an invalid destination path.");
        id env = file[@"env"];
        if (env && ![env isKindOfClass:NSDictionary.class]) return InvalidManifest(error, @"A file's env field must be an object.");
        for (NSString *side in @[@"client", @"server"]) {
            if (env[side] && ![@[@"required", @"optional", @"unsupported"] containsObject:env[side]]) return InvalidManifest(error, @"Unknown client/server requirement in a Modrinth file.");
        }
        if (![env[@"client"] isEqual:@"unsupported"]) {
            NSString *identity = [file[@"path"] stringByStandardizingPath].precomposedStringWithCanonicalMapping.lowercaseString;
            if ([paths containsObject:identity]) return InvalidManifest(error, @"Multiple client files have the same destination path.");
            [paths addObject:identity];
        }
        id hashes = file[@"hashes"];
        if (![hashes isKindOfClass:NSDictionary.class] || !HexDigest(hashes[@"sha1"], 40) || !HexDigest(hashes[@"sha512"], 128)) return InvalidManifest(error, @"A Modrinth file is missing valid SHA-1/SHA-512 checksums.");
        id downloads = file[@"downloads"];
        if (![downloads isKindOfClass:NSArray.class] || [downloads count] == 0) return InvalidManifest(error, @"A Modrinth file has no download URLs.");
        for (id link in downloads) {
            NSURL *url = [link isKindOfClass:NSString.class] ? [NSURL URLWithString:link] : nil;
            if (![url.scheme.lowercaseString isEqualToString:@"https"] || url.host.length == 0) return InvalidManifest(error, @"A Modrinth download URL is not a valid HTTPS address.");
        }
        id size = file[@"fileSize"];
        if (![size isKindOfClass:NSNumber.class] || [size doubleValue] < 0 || [size doubleValue] >= (double)LLONG_MAX || [size doubleValue] != floor([size doubleValue])) return InvalidManifest(error, @"Invalid Modrinth file size.");
    }
    return YES;
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
            NSError *readError;
            NSData *chunk = [handle readDataUpToLength:262144 error:&readError];
            if (readError) { [handle closeFile]; return nil; }
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
    return [path isKindOfClass:NSString.class] && ModpackRelativePathIsSafe(path.UTF8String, [path lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
}

+ (NSString *)destinationForRelativePath:(NSString *)relative underDirectory:(NSString *)directory error:(NSError **)error {
    if (![self isSafeRelativePath:relative]) {
        if (error) *error = ModpackError(@"The modpack contains an invalid relative path.");
        return nil;
    }
    NSString *base = directory.stringByStandardizingPath;
    NSString *root = base.stringByResolvingSymlinksInPath.precomposedStringWithCanonicalMapping.lowercaseString;
    NSString *destination = [base stringByAppendingPathComponent:relative];
    // Resolving an entire not-yet-created path can spell its existing sandbox
    // prefix differently from the root on iOS. Only existing symlink components
    // need filesystem containment checks; lexical traversal was rejected above.
    NSString *current = base;
    for (NSString *component in relative.stringByStandardizingPath.pathComponents) {
        current = [current stringByAppendingPathComponent:component];
        if (![NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:current error:nil]) continue;
        NSString *resolved = current.stringByResolvingSymlinksInPath.precomposedStringWithCanonicalMapping.lowercaseString;
        if (![NSFileManager.defaultManager fileExistsAtPath:current] ||
            (![resolved isEqualToString:root] && ![resolved hasPrefix:[root stringByAppendingString:@"/"]])) {
            if (error) *error = ModpackError([NSString stringWithFormat:@"The existing symlink at %@ escapes the instance folder or has a missing target.", relative]);
            return nil;
        }
    }
    return destination;
}

+ (BOOL)validateFilePaths:(NSSet<NSString *> *)paths underDirectory:(NSString *)directory error:(NSError **)error {
    NSMutableSet *identities = [NSMutableSet new];
    for (NSString *relative in paths) {
        NSString *destination = [self destinationForRelativePath:relative underDirectory:directory error:error];
        if (!destination) return NO;
        BOOL isDirectory = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:destination isDirectory:&isDirectory] && isDirectory) {
            return InvalidManifest(error, @"A modpack file would replace an existing directory.");
        }
        [identities addObject:relative.stringByStandardizingPath.precomposedStringWithCanonicalMapping.lowercaseString];
    }
    for (NSString *identity in identities) {
        NSString *parent = identity.stringByDeletingLastPathComponent;
        while (parent.length > 0) {
            if ([identities containsObject:parent]) return InvalidManifest(error, @"A modpack path is used as both a file and a parent directory.");
            parent = parent.stringByDeletingLastPathComponent;
        }
    }
    return YES;
}

+ (NSString *)createProfileNamed:(NSString *)name
                         version:(NSString *)packVersion
                         gameDir:(NSString *)gameDir
                       versionId:(NSString *)versionId
                      iconBase64:(NSString *)iconBase64 error:(NSError **)error {
    // The profile key is what the launcher shows as its name. Don't clobber a different
    // instance that already uses the name (e.g. another version of the same pack).
    NSString *key = name;
    // A reimport should reconnect a renamed instance instead of creating another
    // profile for the same folder. Keep user settings when refreshing its metadata.
    for (NSString *candidate in PLProfiles.current.profiles) {
        if ([PLProfiles.current.profiles[candidate][@"gameDir"] isEqualToString:gameDir]) {
            key = candidate;
            break;
        }
    }
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

    // Directory suffixes can also collide (or match a user-created profile name).
    // Keep searching until the key is unused or already belongs to this instance.
    NSString *baseKey = key;
    NSUInteger suffix = 2;
    while (PLProfiles.current.profiles[key] &&
           ![PLProfiles.current.profiles[key][@"gameDir"] isEqualToString:gameDir]) {
        key = [NSString stringWithFormat:@"%@ (%lu)", baseKey, (unsigned long)suffix++];
    }

    NSMutableDictionary *profile = [PLProfiles.current.profiles[key] mutableCopy] ?: [NSMutableDictionary new];
    profile[@"gameDir"] = gameDir;
    profile[@"name"] = key;
    profile[@"lastVersionId"] = versionId;
    if (iconBase64.length > 0) {
        profile[@"icon"] = [@"data:image/png;base64," stringByAppendingString:iconBase64];
    }
    PLProfiles *profiles = PLProfiles.current;
    NSMutableDictionary *previous = profiles.profiles[key];
    NSString *selected = profiles.selectedProfileName;
    profiles.profiles[key] = profile;
    profiles.profileDict[@"selectedProfile"] = key;
    if (![profiles saveWithError:error]) {
        if (previous) profiles.profiles[key] = previous;
        else [profiles.profiles removeObjectForKey:key];
        profiles.profileDict[@"selectedProfile"] = selected;
        return nil;
    }
    return key;
}

@end
