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

// Forge config settings that can't work on iOS, as config file -> category -> "type:key" -> value.
// Each file is only touched when the instance has the mod it belongs to (see kSettingsMods).
// - lwjgl3ify stbiTextureLoading decodes textures with libspng, which Amethyst iOS doesn't ship:
//   left on, the game crashes on the first texture. Off, Minecraft's own texture loader is used.
// - BetterLoadingScreen threadedRendering draws the loading screen from a second, shared GL
//   context. The bridge has one on-screen context, and GTNH Mobile ships lwjgl3ify with shared
//   contexts off, so it crashed starting the loading screen. Off, it draws on the game thread
//   (GTNH's own mobile build sets this; BetterLoadingScreen recommends it on Android). This applies
//   to every pack with BetterLoadingScreen, not only lwjgl3ify ones (e.g. GT New Horizons on Java 8).
static NSDictionary<NSString *, NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *> *RequiredSettings(void) {
    return @{
        @"config/lwjgl3ify.cfg": @{@"mixin": @{@"B:stbiTextureLoading": @"false"}},
        @"config/Betterloadingscreen/betterloadingscreen.cfg": @{@"general": @{@"B:threadedRendering": @"false"}},
    };
}

// Which mod jar (file name contains it, case-insensitive) each config file belongs to
static NSDictionary<NSString *, NSString *> *SettingsMods(void) {
    return @{
        @"config/lwjgl3ify.cfg": @"lwjgl3ify",
        @"config/Betterloadingscreen/betterloadingscreen.cfg": @"betterloadingscreen",
    };
}

static BOOL ModsDirectoryHasJarNamed(NSArray<NSString *> *mods, NSString *name) {
    for (NSString *mod in mods) {
        if ([mod.pathExtension.lowercaseString isEqualToString:@"jar"] &&
            [mod rangeOfString:name options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

// Sets `key` to `value` inside `category` of a Forge config, adding the line (and the category)
// if missing. Returns whether anything changed.
static BOOL SetForgeConfigEntry(NSMutableString *config, NSString *category, NSString *key, NSString *value) {
    NSRegularExpression *entry = [NSRegularExpression regularExpressionWithPattern:
        [NSString stringWithFormat:@"^([ \\t]*%@=)(.*)$", [NSRegularExpression escapedPatternForString:key]]
        options:NSRegularExpressionAnchorsMatchLines error:nil];
    NSTextCheckingResult *match = [entry firstMatchInString:config options:0 range:NSMakeRange(0, config.length)];
    if (match) {
        NSRange valueRange = [match rangeAtIndex:2];
        NSString *current = [[config substringWithRange:valueRange] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([current isEqualToString:value]) {
            return NO;
        }
        [config replaceCharactersInRange:valueRange withString:value];
        return YES;
    }
    // Not written yet (first launch): add it to the category; Forge fills in the rest
    NSString *line = [NSString stringWithFormat:@"    %@=%@\n", key, value];
    NSRegularExpression *categoryStart = [NSRegularExpression regularExpressionWithPattern:
        [NSString stringWithFormat:@"^%@ \\{\\r?\\n", [NSRegularExpression escapedPatternForString:category]]
        options:NSRegularExpressionAnchorsMatchLines error:nil];
    NSTextCheckingResult *found = [categoryStart firstMatchInString:config options:0 range:NSMakeRange(0, config.length)];
    if (found) {
        [config insertString:line atIndex:NSMaxRange(found.range)];
    } else {
        [config appendFormat:@"\n%@ {\n%@}\n", category, line];
    }
    return YES;
}

+ (void)applyRequiredConfigToGameDirectory:(NSString *)gameDir {
    NSArray<NSString *> *mods = [NSFileManager.defaultManager contentsOfDirectoryAtPath:[gameDir stringByAppendingPathComponent:@"mods"] error:nil];
    [RequiredSettings() enumerateKeysAndObjectsUsingBlock:^(NSString *file, NSDictionary *categories, BOOL *stop) {
        if (!ModsDirectoryHasJarNamed(mods, SettingsMods()[file])) {
            return;
        }
        NSString *path = [gameDir stringByAppendingPathComponent:file];
        NSString *existing = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        NSMutableString *config = existing ? existing.mutableCopy : [NSMutableString stringWithString:@"# Configuration file\n"];
        __block BOOL changed = NO;
        [categories enumerateKeysAndObjectsUsingBlock:^(NSString *category, NSDictionary *entries, BOOL *stop2) {
            [entries enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop3) {
                changed |= SetForgeConfigEntry(config, category, key, value);
            }];
        }];
        if (!changed) {
            NSLog(@"[ModSettings] %@ already has the iOS settings", file);
            return;
        }
        NSError *error;
        [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        if ([config writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
            NSLog(@"[ModSettings] Applied iOS settings to %@", file);
        } else {
            NSLog(@"[LWJGL3ify] Could not update %@: %@", path, error.localizedDescription);
        }
    }];
}

+ (NSString *)versionIdForGameDirectory:(NSString *)gameDir
                       currentVersionId:(NSString *)currentVersionId
                                  error:(NSError **)error {
    // A version someone picked by hand that already mentions lwjgl3ify is left alone,
    // but one we generated earlier is kept in sync with the jar (the pack may have updated it)
    // Settings that can't work on iOS are fixed for any instance that has the mods they belong to
    [self applyRequiredConfigToGameDirectory:gameDir];
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
    return [self installVersionFromJar:jar error:error];
}

@end
