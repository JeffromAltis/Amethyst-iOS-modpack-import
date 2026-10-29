#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "utils.h"
#import "ios_uikit_bridge.h"

NSNotificationName const PLProfilesDidChangeNotification = @"PLProfilesDidChange";

static NSString * const kInstancesGameDirPrefix = @"./instances/";

static PLProfiles* current;

@interface PLProfiles()
@property(nonatomic) BOOL savingBlocked;
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
    // Filesystem limits are in UTF-8 bytes, not NSString's UTF-16 length.
    // Reserve room for collision suffixes and imported-pack content hashes.
    while ([safe lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 180) {
        NSRange last = [safe rangeOfComposedCharacterSequenceAtIndex:safe.length - 1];
        safe = [safe substringToIndex:last.location];
    }
    if (safe.length == 0) {
        safe = @"instance";
    }
    return [kInstancesGameDirPrefix stringByAppendingString:safe];
}

+ (NSString *)instancesDirectory {
    return [@(getenv("AME_HOME")) stringByAppendingPathComponent:@"instances"];
}

+ (NSString *)availableGameDirForName:(NSString *)name {
    NSString *base = [self isolatedGameDirForName:name];
    NSMutableSet *used = [NSMutableSet new];
    for (NSDictionary *profile in self.current.profiles.allValues) {
        NSString *path = [[self absolutePathForGameDir:profile[@"gameDir"]] stringByResolvingSymlinksInPath];
        [used addObject:path.precomposedStringWithCanonicalMapping.lowercaseString];
    }
    NSString *candidate = base;
    for (NSUInteger suffix = 2; ; suffix++) {
        NSString *path = [self absolutePathForGameDir:candidate];
        NSString *identity = path.stringByResolvingSymlinksInPath.precomposedStringWithCanonicalMapping.lowercaseString;
        if (![used containsObject:identity] && ![NSFileManager.defaultManager fileExistsAtPath:path]) return candidate;
        candidate = [NSString stringWithFormat:@"%@ (%lu)", base, (unsigned long)suffix];
    }
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
    NSData *data = [NSData dataWithContentsOfFile:self.profilePath];
    id loaded = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
    BOOL valid = [loaded isKindOfClass:NSDictionary.class] && [loaded[@"profiles"] isKindOfClass:NSDictionary.class] && [loaded[@"profiles"] count] > 0;
    if (valid) {
        for (id key in loaded[@"profiles"]) {
            id profile = loaded[@"profiles"][key];
            if (![key isKindOfClass:NSString.class] || [key length] == 0 || ![profile isKindOfClass:NSDictionary.class]) {
                valid = NO;
                break;
            }
            for (NSString *field in @[@"name", @"gameDir", @"lastVersionId"]) {
                if (profile[field] && ![profile[field] isKindOfClass:NSString.class]) valid = NO;
            }
        }
    }
    if (!valid) {
        // Preserve unreadable or structurally invalid JSON before any defaults are saved.
        if ([NSFileManager.defaultManager fileExistsAtPath:self.profilePath]) {
            NSString *backup = [self.profilePath stringByAppendingFormat:@".recovery-%@", NSUUID.UUID.UUIDString];
            NSError *error;
            if (![NSFileManager.defaultManager copyItemAtPath:self.profilePath toPath:backup error:&error]) {
                self.savingBlocked = YES;
                NSLog(@"[Profiles] Could not preserve invalid profile file: %@", error);
            } else {
                NSLog(@"[Profiles] Preserved invalid profile file at %@", backup);
            }
        }
        self.profileDict = PLProfiles.defaultProfiles;
        [self save];
    } else {
        self.profileDict = loaded;
        for (NSString *key in self.profiles) {
            NSMutableDictionary *profile = self.profiles[key];
            profile[@"name"] = key;
            if ([profile[@"lastVersionId"] length] == 0) profile[@"lastVersionId"] = @"latest-release";
        }
        id selected = self.profileDict[@"selectedProfile"];
        if (![selected isKindOfClass:NSString.class] || !self.profiles[selected]) {
            self.profileDict[@"selectedProfile"] = [[self.profiles.allKeys sortedArrayUsingSelector:@selector(compare:)] firstObject];
            [self save];
        }
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
    if (!name || !self.profiles[name]) return;
    NSString *previous = self.selectedProfileName;
    self.profileDict[@"selectedProfile"] = (id)name;
    if (![self save]) {
        if (previous) self.profileDict[@"selectedProfile"] = previous;
        else [self.profileDict removeObjectForKey:@"selectedProfile"];
    }
}

- (BOOL)save {
    NSError *error;
    if ([self saveWithError:&error]) return YES;
    NSLog(@"[Profiles] Saving failed: %@", error);
    dispatch_async(dispatch_get_main_queue(), ^{ showDialog(localize(@"Error", nil), error.localizedDescription); });
    return NO;
}

- (BOOL)saveWithError:(NSError **)error {
    NSError *failure = self.savingBlocked ? [NSError errorWithDomain:@"PLProfiles" code:1 userInfo:@{
        NSLocalizedDescriptionKey: @"The existing profile file could not be backed up. Saving is blocked to preserve it."
    }] : saveJSONToFile(self.profileDict, self.profilePath);
    if (failure && error) *error = failure;
    return failure == nil;
}

@end
