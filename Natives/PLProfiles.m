#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "utils.h"

NSNotificationName const PLProfilesDidChangeNotification = @"PLProfilesDidChange";

static NSString * const kInstancesGameDirPrefix = @"./instances/";

static PLProfiles* current;

@interface PLProfiles()
@end

@implementation PLProfiles

+ (id)defaultProfiles {
    // Every level must be mutable: a plain literal's nested dictionaries are immutable constants
    // and crash as soon as a profile is renamed or deleted.
    NSMutableDictionary *defaultProfile = @{
        @"name": @"(Default)",
        @"lastVersionId": @"latest-release",
        @"gameDir": [self isolatedGameDirForName:@"(Default)"]
    }.mutableCopy;
    NSMutableDictionary *profiles = [NSMutableDictionary dictionaryWithObject:defaultProfile forKey:@"(Default)"];
    return @{
        @"profiles": profiles,
        @"selectedProfile": @"(Default)"
    }.mutableCopy;
}

+ (NSString *)isolatedGameDirForName:(NSString *)name {
    NSMutableCharacterSet *bad = [NSMutableCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|"];
    [bad formUnionWithCharacterSet:NSCharacterSet.controlCharacterSet];
    NSString *safe = [[name componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"-"];
    safe = [safe stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while ([safe hasPrefix:@"."]) {
        safe = [safe substringFromIndex:1];
    }
    if (safe.length == 0) {
        safe = @"instance";
    }
    return [kInstancesGameDirPrefix stringByAppendingString:safe];
}

+ (NSString *)instancesDirectory {
    return [@(getenv("AME_HOME")) stringByAppendingPathComponent:@"instances"];
}

+ (NSString *)absolutePathForGameDir:(NSString *)gameDir {
    if (gameDir.length == 0 || [gameDir isEqualToString:@"."]) {
        return @(getenv("GAME_DIR"));
    }
    return [[@(getenv("AME_HOME")) stringByAppendingPathComponent:gameDir] stringByStandardizingPath];
}

+ (NSString *)instanceFolderNameForGameDir:(NSString *)gameDir {
    if (![gameDir hasPrefix:kInstancesGameDirPrefix]) return nil;
    NSString *name = [gameDir substringFromIndex:kInstancesGameDirPrefix.length];
    if (name.length == 0 || [name isEqualToString:@"."] || [name isEqualToString:@".."] || [name containsString:@"/"]) {
        return nil;
    }
    return name;
}

+ (PLProfiles *)current {
    if (!current) {
        [self updateCurrent];
    }
    return current;
}

+ (void)updateCurrent {
    current = [[PLProfiles alloc] initWithCurrentInstance];
}

+ (id)profile:(NSMutableDictionary *)profile resolveKey:(id)key {
    NSString *value = profile[key];
    if (value.length > 0) {
        //NSDebugLog(@"[PLProfiles] Applying %@: \"%@\"", key, value);
        return value;
    }

    NSDictionary *valueDefaults = @{
        @"javaVersion": @"0",
        @"gameDir": @"."
    };
    if (valueDefaults[key]) {
        return valueDefaults[key];
    }

    NSDictionary *prefDefaults = @{
        @"defaultTouchCtrl": @"control.default_ctrl",
        @"defaultGamepadCtrl": @"control.default_gamepad_ctrl",
        @"gamepadPassthrough": @"control.gamepad_passthrough",
        @"javaArgs": @"java.java_args",
        @"allocatedMemory": @"java.allocated_memory",
        @"renderer": @"video.renderer"
    };
    return getPrefObject(prefDefaults[key]);
}

+ (id)resolveKeyForCurrentProfile:(id)key {
    return [self profile:self.current.selectedProfile resolveKey:key];
}

- (id)initWithCurrentInstance {
    self = [super init];
    self.profilePath = [@(getenv("GAME_DIR")) stringByAppendingPathComponent:@"launcher_profiles.json"];
    self.profileDict = parseJSONFromFile(self.profilePath);
    if (self.profileDict[@"NSErrorObject"]) {
        self.profileDict = PLProfiles.defaultProfiles;
        [self save];
    }

    return self;
}

- (id)profiles {
    return self.profileDict[@"profiles"];
}

- (id)selectedProfile {
    return self.profiles[self.selectedProfileName];
}

- (NSString *)selectedProfileName {
    return (id)self.profileDict[@"selectedProfile"];
}

- (void)setSelectedProfileName:(NSString *)name {
    self.profileDict[@"selectedProfile"] = (id)name;
    [self save];
}

- (void)save {
    saveJSONToFile(self.profileDict, self.profilePath);
}

@end
