#import "LWJGL3ifyUtils.h"
#import "UnzipKit.h"

static NSString * const kEmbeddedVersionJson = @"me/eigenraven/lwjgl3ify/relauncher/version.json";
static NSString * const kVersionIdPrefix = @"1.7.10-LWJGL3ify-";

static NSError *LWJGL3ifyError(NSString *message) {
    return [NSError errorWithDomain:@"LWJGL3ify" code:1
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation LWJGL3ifyUtils

+ (NSString *)findJarInModsDirectory:(NSString *)modsDir error:(NSError **)error {
    NSArray<NSString *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:modsDir error:nil];
    NSMutableArray<NSString *> *found = [NSMutableArray new];
    for (NSString *file in files) {
        NSString *lower = file.lowercaseString;
        if (![lower hasSuffix:@".jar"] || ![lower containsString:@"lwjgl3ify"]) {
            continue;
        }
        // Only versions that carry a launch profile count (lwjgl3ify 3.x and newer)
        NSString *path = [modsDir stringByAppendingPathComponent:file];
        UZKArchive *archive = [[UZKArchive alloc] initWithPath:path error:nil];
        NSData *data = [archive extractDataFromFile:kEmbeddedVersionJson error:nil];
        if (data.length > 0) {
            [found addObject:path];
        }
    }
    if (found.count > 1) {
        if (error) {
            NSArray *names = [found valueForKey:@"lastPathComponent"];
            *error = LWJGL3ifyError([NSString stringWithFormat:
                @"More than one lwjgl3ify jar is in the mods folder (%@). Remove all but one and try again.",
                [names componentsJoinedByString:@", "]]);
        }
        return nil;
    }
    return found.firstObject;
}

+ (NSString *)versionIdForJar:(NSString *)jarPath error:(NSError **)error {
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:jarPath error:error];
    NSData *data = [archive extractDataFromFile:@"mcmod.info" error:error];
    if (!data) {
        return nil;
    }
    id info = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:error];
    // mcmod.info is either {"modList": [...]} (version 2) or a bare array
    NSArray *modList = [info isKindOfClass:NSDictionary.class] ? info[@"modList"] : info;
    NSString *version = nil;
    if ([modList isKindOfClass:NSArray.class]) {
        for (NSDictionary *mod in modList) {
            if ([mod isKindOfClass:NSDictionary.class] && [mod[@"modid"] isEqual:@"lwjgl3ify"]) {
                version = mod[@"version"];
                break;
            }
        }
        if (!version && [modList.firstObject isKindOfClass:NSDictionary.class]) {
            version = modList.firstObject[@"version"];
        }
    }
    if (![version isKindOfClass:NSString.class] || version.length == 0) {
        if (error && !*error) *error = LWJGL3ifyError(@"Could not read the lwjgl3ify version from its mcmod.info.");
        return nil;
    }
    return [kVersionIdPrefix stringByAppendingString:version];
}

+ (NSString *)installVersionFromJar:(NSString *)jarPath error:(NSError **)error {
    NSString *versionId = [self versionIdForJar:jarPath error:error];
    if (!versionId) {
        return nil;
    }
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:jarPath error:error];
    NSData *data = [archive extractDataFromFile:kEmbeddedVersionJson error:error];
    NSMutableDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:error] : nil;
    if (![json isKindOfClass:NSDictionary.class]) {
        if (error && !*error) *error = LWJGL3ifyError(@"The lwjgl3ify jar does not contain a valid launch profile.");
        return nil;
    }
    // Use our own id: it must not collide with the id baked into the jar
    json[@"id"] = versionId;

    NSData *output = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:error];
    if (!output) {
        return nil;
    }
    NSString *dir = [NSString stringWithFormat:@"%s/versions/%@", getenv("GAME_DIR"), versionId];
    NSString *path = [dir stringByAppendingPathComponent:[versionId stringByAppendingPathExtension:@"json"]];
    if ([[NSData dataWithContentsOfFile:path] isEqualToData:output]) {
        return versionId;
    }
    if (![NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:error] ||
        ![output writeToFile:path options:NSDataWritingAtomic error:error]) {
        return nil;
    }
    NSLog(@"[LWJGL3ify] Installed launch profile %@", versionId);
    return versionId;
}

// lwjgl3ify settings that can't work on iOS, as "key": "value" in its Forge config (category "mixin").
// stbiTextureLoading decodes textures with libspng, which Amethyst iOS doesn't ship: left on, the game
// crashes on the first texture. Off, Minecraft's own texture loader is used.
static NSDictionary<NSString *, NSString *> *RequiredMixinSettings(void) {
    return @{@"B:stbiTextureLoading": @"false"};
}

+ (void)applyRequiredConfigToGameDirectory:(NSString *)gameDir {
    NSString *path = [gameDir stringByAppendingPathComponent:@"config/lwjgl3ify.cfg"];
    NSString *config = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSMutableString *updated = config ? config.mutableCopy : [NSMutableString stringWithString:@"# Configuration file\n\nmixin {\n}\n"];
    [RequiredMixinSettings() enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        NSString *escapedKey = [NSRegularExpression escapedPatternForString:key];
        NSRegularExpression *entry = [NSRegularExpression regularExpressionWithPattern:
            [NSString stringWithFormat:@"^(\\s*%@=).*$", escapedKey] options:NSRegularExpressionAnchorsMatchLines error:nil];
        NSRange whole = NSMakeRange(0, updated.length);
        if ([entry firstMatchInString:updated options:0 range:whole]) {
            [entry replaceMatchesInString:updated options:0 range:whole
                withTemplate:[NSString stringWithFormat:@"$1%@", [NSRegularExpression escapedTemplateForString:value]]];
            return;
        }
        // Not written yet (first launch): add it to the category; Forge fills in the rest
        NSString *line = [NSString stringWithFormat:@"    %@=%@\n", key, value];
        NSRegularExpression *mixinCategory = [NSRegularExpression regularExpressionWithPattern:@"^mixin \\{\\r?\\n"
            options:NSRegularExpressionAnchorsMatchLines error:nil];
        NSTextCheckingResult *category = [mixinCategory firstMatchInString:updated options:0 range:whole];
        if (category) {
            [updated insertString:line atIndex:NSMaxRange(category.range)];
        } else {
            [updated appendFormat:@"\nmixin {\n%@}\n", line];
        }
    }];
    if ([updated isEqualToString:config ?: @""]) {
        return;
    }
    NSError *error;
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    if ([updated writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        NSLog(@"[LWJGL3ify] Applied iOS settings to %@", path);
    } else {
        NSLog(@"[LWJGL3ify] Could not update %@: %@", path, error.localizedDescription);
    }
}

+ (NSString *)versionIdForGameDirectory:(NSString *)gameDir
                       currentVersionId:(NSString *)currentVersionId
                                  error:(NSError **)error {
    // A version someone picked by hand that already mentions lwjgl3ify is left alone,
    // but one we generated earlier is kept in sync with the jar (the pack may have updated it)
    BOOL isOurs = [currentVersionId hasPrefix:kVersionIdPrefix];
    if (!isOurs && [currentVersionId.lowercaseString containsString:@"lwjgl3ify"]) {
        return currentVersionId;
    }
    NSError *findError;
    NSString *jar = [self findJarInModsDirectory:[gameDir stringByAppendingPathComponent:@"mods"] error:&findError];
    if (findError) {
        if (error) *error = findError;
        return nil;
    }
    if (!jar) {
        return currentVersionId;
    }
    [self applyRequiredConfigToGameDirectory:gameDir];
    return [self installVersionFromJar:jar error:error];
}

@end
