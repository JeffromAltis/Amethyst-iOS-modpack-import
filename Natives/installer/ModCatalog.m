#import "ModCatalog.h"
#import "AFImageDownloader.h"
#import "LauncherPreferences.h"
#import "UIKit+AFNetworking.h"
#import "modpack/CurseForgeAPI.h"
#import "modpack/ModpackAPI.h"
#import "modpack/ModpackUtils.h"
#import "modpack/ModrinthAPI.h"
#import "utils.h"
#include <errno.h>
#include <stdio.h>

#define kCurseForgeGameIDMinecraft 432
#define kCurseForgeClassIDMod 6
#define kCurseForgeRelationRequired 3
#define kMaxDependencyDepth 4

@implementation ModFile
@end
@implementation InstalledMod
- (id)copyWithZone:(NSZone *)zone {
    InstalledMod *copy = [InstalledMod new];
    copy.path = self.path; copy.fileName = self.fileName; copy.sha1 = self.sha1;
    copy.enabled = self.enabled; copy.known = self.known; copy.source = self.source;
    copy.title = self.title; copy.iconURL = self.iconURL; copy.projectId = self.projectId;
    copy.versionId = self.versionId; copy.versionLabel = self.versionLabel; copy.releaseType = self.releaseType;
    copy.update = self.update;
    return copy;
}
@end

static NSString *JSONString(id object) {
    return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:object options:0 error:nil] encoding:NSUTF8StringEncoding];
}

static NSString *StringValue(id value) {
    return [value isKindOfClass:NSString.class] ? value : [value respondsToSelector:@selector(stringValue)] ? [value stringValue] : nil;
}

/// CurseForge identifies files by a MurmurHash2 of the jar with whitespace bytes removed.
static uint32_t CurseForgeFingerprint(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    const uint8_t *bytes = data.bytes;
    NSMutableData *filtered = [NSMutableData dataWithLength:data.length];
    uint8_t *p = filtered.mutableBytes;
    NSUInteger len = 0;
    for (NSUInteger i = 0; i < data.length; i++) {
        uint8_t b = bytes[i];
        if (b != 9 && b != 10 && b != 13 && b != 32) p[len++] = b;
    }
    const uint32_t m = 0x5bd1e995;
    uint32_t h = 1 ^ (uint32_t)len;
    NSUInteger i = 0;
    for (; len - i >= 4; i += 4) {
        uint32_t k;
        memcpy(&k, p + i, 4);
        k *= m; k ^= k >> 24; k *= m;
        h *= m; h ^= k;
    }
    switch (len - i) {
        case 3: h ^= (uint32_t)p[i + 2] << 16; // fallthrough
        case 2: h ^= (uint32_t)p[i + 1] << 8;  // fallthrough
        case 1: h ^= p[i]; h *= m;
    }
    h ^= h >> 13; h *= m; h ^= h >> 15;
    return h;
}

static NSString *CurseForgeReleaseType(id value) {
    NSInteger type = [value integerValue];
    return type == 2 ? @"beta" : type == 3 ? @"alpha" : @"release";
}

/// The file to offer from a newest-first list. Releases are preferred: pre-releases only count when
/// `includePreReleases` (the user is on one already) and then the newest file of any kind wins.
static ModFile *NewestFile(NSArray<ModFile *> *files, BOOL includePreReleases) {
    if (includePreReleases) return files.firstObject;
    for (ModFile *file in files) {
        if ([file.releaseType isEqualToString:@"release"]) return file;
    }
    return nil;
}

static NSInteger CurseForgeLoaderType(NSString *loader) {
    NSDictionary *types = @{@"forge": @1, @"fabric": @4, @"quilt": @5, @"neoforge": @6};
    return [types[loader] integerValue];
}

@interface ModCatalog()
@property(nonatomic, copy) NSString *mcVersion, *loader, *modsDir;
@property(atomic) NSArray<InstalledMod *> *installed;
@property(nonatomic) NSError *lastError;
@property(nonatomic) ModrinthAPI *modrinth;
@property(nonatomic) CurseForgeAPI *curseForge;
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) NSMutableDictionary<NSString *, NSArray *> *categoryCache;
@property(nonatomic) NSMutableDictionary<NSString *, NSDictionary *> *hashCache; // path -> @{stamp, sha1, fp}
@end

@implementation ModCatalog

#pragma mark - Setup

/// The Minecraft version and loader aren't stored in the profile, only the version id
/// ("fabric-loader-0.15.7-1.20.1", "1.20.1-forge-47.2.0", "neoforge-21.1.5", "1.20.1").
- (void)detectFromVersionId:(NSString *)versionId {
    // The "latest" profiles have no version of their own on disk; the launcher keeps what they point to
    NSDictionary *latest = getPrefObject(@"internal.latest_version");
    if ([latest isKindOfClass:NSDictionary.class]) {
        if ([versionId isEqualToString:@"latest-release"] && [latest[@"release"] length] > 0) versionId = latest[@"release"];
        if ([versionId isEqualToString:@"latest-snapshot"] && [latest[@"snapshot"] length] > 0) versionId = latest[@"snapshot"];
    }
    NSString *gameVersion = nil;
    NSString *current = versionId;
    // Modded version json files name the vanilla version they build on
    for (int i = 0; i < 3 && current.length > 0; i++) {
        NSString *path = [NSString stringWithFormat:@"%s/versions/%@/%@.json", getenv("GAME_DIR"), current, current];
        NSData *data = [NSData dataWithContentsOfFile:path];
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *parent = [json isKindOfClass:NSDictionary.class] ? json[@"inheritsFrom"] : nil;
        if (![parent isKindOfClass:NSString.class]) break;
        gameVersion = parent;
        current = parent;
    }
    NSString *lower = versionId.lowercaseString;
    if ([lower containsString:@"neoforge"]) self.loader = @"neoforge";
    else if ([lower containsString:@"fabric"]) self.loader = @"fabric";
    else if ([lower containsString:@"quilt"]) self.loader = @"quilt";
    else if ([lower containsString:@"forge"]) self.loader = @"forge";

    if (!gameVersion) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(?<![\\d.])(?:1|\\d{2})\\.\\d+(\\.\\d+)?(?![\\d.])" options:0 error:nil];
        NSArray *matches = [regex matchesInString:versionId options:0 range:NSMakeRange(0, versionId.length)];
        // Fabric/Quilt ids end with the game version, after the loader's own version number
        NSTextCheckingResult *match = [self.loader isEqualToString:@"fabric"] || [self.loader isEqualToString:@"quilt"] ? matches.lastObject : matches.firstObject;
        if (match) gameVersion = [versionId substringWithRange:match.range];
    }
    // Plain vanilla ids (no loader, no parent) are the game version themselves
    if (!gameVersion && !self.loader && versionId.length > 0) gameVersion = versionId;
    self.mcVersion = gameVersion;
}

+ (void)allowWebPIcons {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        AFImageResponseSerializer *serializer = (AFImageResponseSerializer *)[UIImageView sharedImageDownloader].sessionManager.responseSerializer;
        NSMutableSet *types = serializer.acceptableContentTypes.mutableCopy;
        [types addObject:@"image/webp"];
        serializer.acceptableContentTypes = types;
    });
}

- (instancetype)initWithVersionId:(NSString *)versionId gameDirPath:(NSString *)gameDirPath {
    self = [super init];
    self.modsDir = [gameDirPath stringByAppendingPathComponent:@"mods"];
    [self detectFromVersionId:versionId ?: @""];
    self.modrinth = [ModrinthAPI new];
    self.curseForge = [CurseForgeAPI new];
    self.queue = dispatch_queue_create("mod-catalog", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    self.categoryCache = [NSMutableDictionary new];
    self.hashCache = [NSMutableDictionary new];
    self.installed = @[];
    [ModCatalog allowWebPIcons];
    return self;
}

- (void)perform:(void (^)(void))block {
    dispatch_async(self.queue, block);
}

- (ModpackAPI *)apiForSource:(ModSource)source {
    ModpackAPI *api = source == ModSourceModrinth ? (ModpackAPI *)self.modrinth : self.curseForge;
    api.lastError = nil;
    return api;
}

- (void)captureError:(ModpackAPI *)api {
    self.lastError = api.lastError ?: [NSError errorWithDomain:@"ModCatalog" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Unexpected response."}];
}

- (BOOL)curseForgeAvailable {
    return self.curseForge.apiKey.length > 0;
}

#pragma mark - Search

+ (NSString *)titleForSort:(ModSort)sort {
    return localize(@[@"mods.sort.relevance", @"mods.sort.downloads", @"mods.sort.updated", @"mods.sort.newest"][sort], nil);
}

- (NSArray<NSDictionary *> *)categoriesForSource:(ModSource)source {
    NSString *key = @(source).stringValue;
    if (self.categoryCache[key]) return self.categoryCache[key];
    NSMutableArray *categories = [NSMutableArray new];
    ModpackAPI *api = [self apiForSource:source];
    if (source == ModSourceModrinth) {
        NSArray *tags = [api getEndpoint:@"tag/category" params:nil];
        for (NSDictionary *tag in [tags isKindOfClass:NSArray.class] ? tags : @[]) {
            if (![tag[@"project_type"] isEqualToString:@"mod"]) continue;
            [categories addObject:@{@"id": tag[@"name"], @"title": [tag[@"name"] stringByReplacingOccurrencesOfString:@"-" withString:@" "].capitalizedString}];
        }
    } else if ([self curseForgeAvailable]) {
        NSDictionary *response = [api getEndpoint:@"categories" params:@{@"gameId": @(kCurseForgeGameIDMinecraft), @"classId": @(kCurseForgeClassIDMod)}];
        for (NSDictionary *category in [response isKindOfClass:NSDictionary.class] ? response[@"data"] : @[]) {
            if ([category[@"isClass"] boolValue]) continue;
            [categories addObject:@{@"id": category[@"id"], @"title": category[@"name"] ?: @""}];
        }
    }
    [categories sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"title"] localizedCaseInsensitiveCompare:b[@"title"]];
    }];
    if (categories.count) self.categoryCache[key] = categories; // don't cache a failure
    return categories;
}

- (NSArray<NSDictionary *> *)searchSource:(ModSource)source query:(NSString *)query offset:(NSUInteger)offset
    sort:(ModSort)sort category:(id)category last:(BOOL *)last {
    ModpackAPI *api = [self apiForSource:source];
    if (source == ModSourceModrinth) {
        NSMutableArray *facets = [NSMutableArray arrayWithObject:@[@"project_type:mod"]];
        if (self.mcVersion) [facets addObject:@[[@"versions:" stringByAppendingString:self.mcVersion]]];
        if (self.loader) [facets addObject:@[[@"categories:" stringByAppendingString:self.loader]]];
        if (category) [facets addObject:@[[@"categories:" stringByAppendingString:category]]];
        // Mods that only run on the server are of no use here
        [facets addObject:@[@"client_side:required", @"client_side:optional"]];
        NSDictionary *response = [api getEndpoint:@"search" params:@{
            @"facets": JSONString(facets), @"query": query, @"limit": @50, @"offset": @(offset),
            @"index": @[@"relevance", @"downloads", @"updated", @"newest"][sort]}];
        if (![response isKindOfClass:NSDictionary.class]) { [self captureError:api]; return nil; }
        NSMutableArray *page = [NSMutableArray new];
        for (NSDictionary *hit in response[@"hits"]) {
            [page addObject:@{
                @"id": hit[@"project_id"], @"title": hit[@"title"] ?: @"", @"description": hit[@"description"] ?: @"",
                @"imageUrl": [hit[@"icon_url"] isKindOfClass:NSString.class] ? hit[@"icon_url"] : @""}];
        }
        *last = page.count == 0 || offset + page.count >= [response[@"total_hits"] unsignedLongValue];
        return page;
    }

    if (![self curseForgeAvailable]) {
        self.lastError = [NSError errorWithDomain:@"ModCatalog" code:1 userInfo:@{NSLocalizedDescriptionKey:
            @"This build has no CurseForge API key, so CurseForge can't be searched. Modrinth still works."}];
        return nil;
    }
    NSMutableDictionary *params = @{
        @"gameId": @(kCurseForgeGameIDMinecraft), @"classId": @(kCurseForgeClassIDMod),
        @"sortField": @[@2, @6, @3, @11][sort], @"sortOrder": @"desc", @"pageSize": @50, @"index": @(offset)}.mutableCopy;
    if (query.length > 0) params[@"searchFilter"] = query;
    if (self.mcVersion) params[@"gameVersion"] = self.mcVersion;
    if (self.loader) params[@"modLoaderType"] = @(CurseForgeLoaderType(self.loader));
    if (category) params[@"categoryId"] = category;
    NSDictionary *response = [api getEndpoint:@"mods/search" params:params];
    if (![response isKindOfClass:NSDictionary.class] || ![response[@"data"] isKindOfClass:NSArray.class]) { [self captureError:api]; return nil; }
    NSMutableArray *page = [NSMutableArray new];
    for (NSDictionary *mod in response[@"data"]) {
        NSDictionary *logo = [mod[@"logo"] isKindOfClass:NSDictionary.class] ? mod[@"logo"] : nil;
        [page addObject:@{
            @"id": mod[@"id"], @"title": mod[@"name"] ?: @"", @"description": mod[@"summary"] ?: @"",
            @"imageUrl": logo[@"thumbnailUrl"] ?: logo[@"url"] ?: @""}];
    }
    *last = page.count == 0 || offset + page.count >= [response[@"pagination"][@"totalCount"] unsignedLongValue];
    return page;
}

#pragma mark - Files

- (ModFile *)fileFromModrinthVersion:(NSDictionary *)version {
    NSDictionary *file = nil;
    for (NSDictionary *candidate in version[@"files"]) {
        if ([candidate[@"primary"] boolValue]) file = candidate;
    }
    file = file ?: [version[@"files"] firstObject];
    if (!file[@"url"]) return nil;
    ModFile *modFile = [ModFile new];
    modFile.label = version[@"name"] ?: version[@"version_number"];
    modFile.releaseType = version[@"version_type"] ?: @"release";
    modFile.versionId = version[@"id"];
    modFile.projectId = version[@"project_id"];
    modFile.fileName = file[@"filename"];
    modFile.url = file[@"url"];
    modFile.sha1 = file[@"hashes"][@"sha1"];
    NSMutableArray *deps = [NSMutableArray new];
    for (NSDictionary *dep in version[@"dependencies"]) {
        if ([dep[@"dependency_type"] isEqualToString:@"required"] && [dep[@"project_id"] isKindOfClass:NSString.class]) {
            [deps addObject:@{@"id": dep[@"project_id"]}];
        }
    }
    modFile.dependencies = deps;
    return modFile;
}

- (ModFile *)fileFromCurseForgeFile:(NSDictionary *)file {
    NSString *url = [file[@"downloadUrl"] isKindOfClass:NSString.class] && [file[@"downloadUrl"] length] > 0 ? file[@"downloadUrl"] : nil;
    if (!url && [file[@"id"] integerValue] > 0 && [file[@"fileName"] length] > 0) {
        // Same CDN fallback the modpack installer uses for files without a downloadUrl
        NSInteger fileId = [file[@"id"] integerValue];
        url = [NSString stringWithFormat:@"https://edge.forgecdn.net/files/%ld/%ld/%@", (long)(fileId / 1000), (long)(fileId % 1000), file[@"fileName"]];
    }
    if (!url) return nil;
    ModFile *modFile = [ModFile new];
    modFile.label = file[@"displayName"] ?: file[@"fileName"];
    modFile.releaseType = CurseForgeReleaseType(file[@"releaseType"]);
    modFile.versionId = StringValue(file[@"id"]);
    modFile.projectId = StringValue(file[@"modId"]);
    modFile.fileName = file[@"fileName"];
    modFile.url = url;
    for (NSDictionary *hash in file[@"hashes"]) {
        if ([hash[@"algo"] integerValue] == 1) modFile.sha1 = hash[@"value"];
    }
    NSMutableArray *deps = [NSMutableArray new];
    for (NSDictionary *dep in file[@"dependencies"]) {
        if ([dep[@"relationType"] integerValue] == kCurseForgeRelationRequired) [deps addObject:@{@"id": StringValue(dep[@"modId"])}];
    }
    modFile.dependencies = deps;
    return modFile;
}

- (NSArray<ModFile *> *)filesForProject:(NSString *)projectId source:(ModSource)source {
    ModpackAPI *api = [self apiForSource:source];
    NSMutableArray<ModFile *> *files = [NSMutableArray new];
    if (source == ModSourceModrinth) {
        NSMutableDictionary *params = [NSMutableDictionary new];
        if (self.mcVersion) params[@"game_versions"] = JSONString(@[self.mcVersion]);
        if (self.loader) params[@"loaders"] = JSONString(@[self.loader]);
        NSArray *versions = [api getEndpoint:[NSString stringWithFormat:@"project/%@/version", projectId] params:params];
        if (![versions isKindOfClass:NSArray.class]) { [self captureError:api]; return nil; }
        for (NSDictionary *version in versions) {
            ModFile *file = [self fileFromModrinthVersion:version];
            if (file) [files addObject:file];
        }
        return files;
    }
    NSMutableDictionary *params = @{@"pageSize": @50}.mutableCopy;
    if (self.mcVersion) params[@"gameVersion"] = self.mcVersion;
    if (self.loader) params[@"modLoaderType"] = @(CurseForgeLoaderType(self.loader));
    NSDictionary *response = [api getEndpoint:[NSString stringWithFormat:@"mods/%@/files", projectId] params:params];
    if (![response isKindOfClass:NSDictionary.class] || ![response[@"data"] isKindOfClass:NSArray.class]) { [self captureError:api]; return nil; }
    // The files endpoint doesn't promise an order, so sort by upload date (ISO 8601 sorts as text)
    NSArray *sorted = [response[@"data"] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [StringValue(b[@"fileDate"]) ?: @"" compare:StringValue(a[@"fileDate"]) ?: @""];
    }];
    for (NSDictionary *file in sorted) {
        ModFile *modFile = [self fileFromCurseForgeFile:file];
        if (modFile) [files addObject:modFile];
    }
    return files;
}

#pragma mark - Installed mods

- (NSArray<InstalledMod *> *)scanLocal {
    NSMutableArray *mods = [NSMutableArray new];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.modsDir error:nil]) {
        BOOL disabled = [name.lowercaseString hasSuffix:@".jar.disabled"];
        if (!disabled && ![name.lowercaseString hasSuffix:@".jar"]) continue;
        InstalledMod *mod = [InstalledMod new];
        mod.path = [self.modsDir stringByAppendingPathComponent:name];
        mod.enabled = !disabled;
        mod.fileName = disabled ? [name substringToIndex:name.length - @".disabled".length] : name;
        [mods addObject:mod];
    }
    [mods sortUsingComparator:^NSComparisonResult(InstalledMod *a, InstalledMod *b) {
        return [a.fileName localizedCaseInsensitiveCompare:b.fileName];
    }];
    return mods;
}

/// Hashes are cached per file, as jars rarely change and big packs have hundreds of them
- (NSMutableDictionary *)hashesForMod:(InstalledMod *)mod {
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:mod.path error:nil];
    NSString *stamp = [NSString stringWithFormat:@"%@-%@", attrs.fileModificationDate, attrs[NSFileSize]];
    NSMutableDictionary *entry = self.hashCache[mod.path].mutableCopy;
    if (![entry[@"stamp"] isEqualToString:stamp]) entry = @{@"stamp": stamp}.mutableCopy;
    if (!entry[@"sha1"]) entry[@"sha1"] = [ModpackUtils sha1ForFileAtPath:mod.path] ?: @"";
    self.hashCache[mod.path] = entry;
    return entry;
}

- (void)refreshInstalled {
    NSArray<InstalledMod *> *mods = [self scanLocal];
    NSMutableDictionary<NSString *, InstalledMod *> *byHash = [NSMutableDictionary new];
    for (InstalledMod *mod in mods) {
        mod.sha1 = [self hashesForMod:mod][@"sha1"];
        if (mod.sha1.length) byHash[mod.sha1] = mod;
    }
    [self recognizeModrinth:byHash];
    [self recognizeCurseForgeAmong:mods];
    [self findUpdatesFor:mods byHash:byHash];
    self.installed = mods;
}

- (void)recognizeModrinth:(NSDictionary<NSString *, InstalledMod *> *)byHash {
    if (!byHash.count) return;
    NSDictionary *found = [[self apiForSource:ModSourceModrinth] postEndpoint:@"version_files" body:@{@"hashes": byHash.allKeys, @"algorithm": @"sha1"}];
    if (![found isKindOfClass:NSDictionary.class]) return;
    NSMutableSet *projectIds = [NSMutableSet new];
    [found enumerateKeysAndObjectsUsingBlock:^(NSString *hash, NSDictionary *version, BOOL *stop) {
        InstalledMod *mod = byHash[hash];
        if (!mod || !version[@"project_id"]) return;
        mod.known = YES;
        mod.source = ModSourceModrinth;
        mod.projectId = version[@"project_id"];
        mod.versionId = version[@"id"];
        mod.versionLabel = version[@"version_number"];
        mod.releaseType = version[@"version_type"] ?: @"release";
        [projectIds addObject:mod.projectId];
    }];
    NSArray *projects = [self.modrinth getEndpoint:@"projects" params:@{@"ids": JSONString(projectIds.allObjects)}];
    NSMutableDictionary *byId = [NSMutableDictionary new];
    for (NSDictionary *project in [projects isKindOfClass:NSArray.class] ? projects : @[]) byId[project[@"id"]] = project;
    for (InstalledMod *mod in byHash.allValues) {
        if (!mod.known || mod.source != ModSourceModrinth) continue;
        NSDictionary *project = byId[mod.projectId];
        mod.title = project[@"title"];
        mod.iconURL = [project[@"icon_url"] isKindOfClass:NSString.class] ? project[@"icon_url"] : nil;
    }
}

/// Jars Modrinth doesn't know are looked up on CurseForge by fingerprint
- (void)recognizeCurseForgeAmong:(NSArray<InstalledMod *> *)mods {
    if (![self curseForgeAvailable]) return;
    NSMutableDictionary<NSNumber *, InstalledMod *> *byPrint = [NSMutableDictionary new];
    for (InstalledMod *mod in mods) {
        if (mod.known) continue;
        NSMutableDictionary *entry = [self hashesForMod:mod];
        if (!entry[@"fp"]) { entry[@"fp"] = @(CurseForgeFingerprint(mod.path)); self.hashCache[mod.path] = entry; }
        byPrint[entry[@"fp"]] = mod;
    }
    if (!byPrint.count) return;
    NSDictionary *response = [[self apiForSource:ModSourceCurseForge] postEndpoint:@"fingerprints" body:@{@"fingerprints": byPrint.allKeys}];
    NSArray *matches = [response isKindOfClass:NSDictionary.class] ? response[@"data"][@"exactMatches"] : nil;
    NSMutableSet *modIds = [NSMutableSet new];
    for (NSDictionary *match in [matches isKindOfClass:NSArray.class] ? matches : @[]) {
        NSNumber *print = @([match[@"file"][@"fileFingerprint"] unsignedIntValue]);
        InstalledMod *mod = byPrint[print];
        if (!mod) continue;
        mod.known = YES;
        mod.source = ModSourceCurseForge;
        mod.projectId = StringValue(match[@"id"]);
        mod.versionId = StringValue(match[@"file"][@"id"]);
        mod.versionLabel = match[@"file"][@"displayName"];
        mod.releaseType = CurseForgeReleaseType(match[@"file"][@"releaseType"]);
        [modIds addObject:@([match[@"id"] longLongValue])];
    }
    if (!modIds.count) return;
    NSDictionary *info = [self.curseForge postEndpoint:@"mods" body:@{@"modIds": modIds.allObjects}];
    NSMutableDictionary *byId = [NSMutableDictionary new];
    for (NSDictionary *project in [info isKindOfClass:NSDictionary.class] ? info[@"data"] : @[]) byId[StringValue(project[@"id"])] = project;
    for (InstalledMod *mod in mods) {
        if (!mod.known || mod.source != ModSourceCurseForge) continue;
        NSDictionary *project = byId[mod.projectId];
        NSDictionary *logo = [project[@"logo"] isKindOfClass:NSDictionary.class] ? project[@"logo"] : nil;
        mod.title = project[@"name"];
        mod.iconURL = logo[@"thumbnailUrl"] ?: logo[@"url"];
    }
}

- (void)findUpdatesFor:(NSArray<InstalledMod *> *)mods byHash:(NSDictionary<NSString *, InstalledMod *> *)byHash {
    // Without a known version and loader "latest" could be for something else entirely
    if (!self.mcVersion || !self.loader) return;
    NSMutableArray *modrinthHashes = [NSMutableArray new];
    for (InstalledMod *mod in mods) {
        if (mod.known && mod.source == ModSourceModrinth) [modrinthHashes addObject:mod.sha1];
    }
    if (modrinthHashes.count) {
        NSDictionary *latest = [[self apiForSource:ModSourceModrinth] postEndpoint:@"version_files/update" body:@{
            @"hashes": modrinthHashes, @"algorithm": @"sha1", @"loaders": @[self.loader], @"game_versions": @[self.mcVersion]}];
        [[latest isKindOfClass:NSDictionary.class] ? latest : @{} enumerateKeysAndObjectsUsingBlock:^(NSString *hash, NSDictionary *version, BOOL *stop) {
            InstalledMod *mod = byHash[hash];
            if (!mod || [version[@"id"] isEqualToString:mod.versionId]) return;
            BOOL onPreRelease = ![mod.releaseType isEqualToString:@"release"];
            if (onPreRelease || [version[@"version_type"] isEqualToString:@"release"]) {
                mod.update = [self fileFromModrinthVersion:version];
            } else {
                // The newest version is a pre-release but this one is a release: offer the newest release instead
                ModFile *release = NewestFile([self filesForProject:mod.projectId source:ModSourceModrinth], NO);
                if (release && ![release.versionId isEqualToString:mod.versionId]) mod.update = release;
            }
        }];
    }
    NSMutableDictionary<NSString *, NSArray<ModFile *> *> *filesByProject = [NSMutableDictionary new];
    for (InstalledMod *mod in mods) {
        if (!mod.known || mod.source != ModSourceCurseForge) continue;
        if (!filesByProject[mod.projectId]) {
            filesByProject[mod.projectId] = [self filesForProject:mod.projectId source:ModSourceCurseForge] ?: @[];
        }
        ModFile *latest = NewestFile(filesByProject[mod.projectId], ![mod.releaseType isEqualToString:@"release"]);
        if (latest && ![latest.versionId isEqualToString:mod.versionId]) mod.update = latest;
    }
}

- (InstalledMod *)installedModForProject:(NSString *)projectId source:(ModSource)source {
    for (InstalledMod *mod in self.installed) {
        if (mod.known && mod.source == source && [mod.projectId isEqualToString:projectId]) return mod;
    }
    return nil;
}

#pragma mark - Installing

/// The file for `fileName` as it is on disk now: enabled (.jar) or disabled (.jar.disabled). nil if it isn't there.
- (NSString *)existingPathForFileName:(NSString *)fileName enabled:(BOOL *)enabled {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *path = [self.modsDir stringByAppendingPathComponent:fileName];
    if ([fm fileExistsAtPath:path]) {
        *enabled = YES;
        return path;
    }
    NSString *disabled = [path stringByAppendingString:@".disabled"];
    if ([fm fileExistsAtPath:disabled]) {
        *enabled = NO;
        return disabled;
    }
    return nil;
}

/// Blocking: downloads one file into mods/. Returns an error message, or nil on success. `destination` is where
/// the file ended up. A file with the same name is replaced where it is (so a disabled mod stays disabled, and
/// there are never two copies), unless it already has the same checksum.
- (NSString *)downloadFile:(ModFile *)file destination:(NSString **)destination {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *name = [ModpackUtils sanitizedFileName:file.fileName ?: file.url.lastPathComponent];
    if (![name.lowercaseString hasSuffix:@".jar"]) name = [name stringByAppendingString:@".jar"];
    [fm createDirectoryAtPath:self.modsDir withIntermediateDirectories:YES attributes:nil error:nil];
    BOOL wasEnabled = YES;
    NSString *dest = [self existingPathForFileName:name enabled:&wasEnabled] ?: [self.modsDir stringByAppendingPathComponent:name];
    *destination = dest;
    if ([fm fileExistsAtPath:dest] && file.sha1.length > 0 &&
        [[ModpackUtils sha1ForFileAtPath:dest].lowercaseString isEqualToString:file.sha1.lowercaseString]) {
        return nil; // this exact file is installed already
    }

    __block NSURL *tmp; __block NSError *error;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURL *url = [NSURL URLWithString:file.url];
    if (!url) return [NSString stringWithFormat:@"Invalid download link for %@", name];
    [[NSURLSession.sharedSession downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *err) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 200;
        error = err ?: (status >= 400 ? [NSError errorWithDomain:@"ModCatalog" code:status userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld", (long)status]}] : nil);
        // The file is deleted when this block returns, so move it out now
        if (!error) {
            // Stage on the destination filesystem so the final rename is atomic.
            NSString *staged = [self.modsDir stringByAppendingPathComponent:
                [@".download-" stringByAppendingString:NSUUID.UUID.UUIDString]];
            if ([fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:staged] error:&error]) tmp = [NSURL fileURLWithPath:staged];
        }
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (error) return [NSString stringWithFormat:@"%@: %@", name, error.localizedDescription];

    if (file.sha1.length > 0 && ![[ModpackUtils sha1ForFileAtPath:tmp.path].lowercaseString isEqualToString:file.sha1.lowercaseString]) {
        [fm removeItemAtURL:tmp error:nil];
        return [NSString stringWithFormat:@"%@ is corrupted (checksum mismatch)", name];
    }
    // Only now that the new file is complete and checked is the old one replaced
    if (rename(tmp.path.fileSystemRepresentation, dest.fileSystemRepresentation) != 0) {
        error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        [fm removeItemAtURL:tmp error:nil];
        return [NSString stringWithFormat:@"%@: %@", name, error.localizedDescription];
    }
    return nil;
}

- (void)installFile:(ModFile *)file source:(ModSource)source replacing:(InstalledMod *)old
    installed:(NSMutableArray<NSString *> *)installed problems:(NSMutableArray<NSString *> *)problems {
    NSMutableSet *visited = [NSMutableSet new];
    // Projects that are on disk already (in any version) are not downloaded again as dependencies
    for (InstalledMod *mod in self.installed) {
        if (mod.known) [visited addObject:[NSString stringWithFormat:@"%ld:%@", (long)mod.source, mod.projectId]];
    }
    if (file.projectId) [visited addObject:[NSString stringWithFormat:@"%ld:%@", (long)source, file.projectId]];
    [self installFile:file source:source replacing:old visited:visited depth:0 installed:installed problems:problems];
}

- (void)installFile:(ModFile *)file source:(ModSource)source replacing:(InstalledMod *)old visited:(NSMutableSet *)visited depth:(int)depth
    installed:(NSMutableArray *)installed problems:(NSMutableArray *)problems {
    NSString *dest;
    NSString *error = [self downloadFile:file destination:&dest];
    if (error) { [problems addObject:error]; return; }
    [installed addObject:file.fileName ?: file.label];
    if (old) {
        // Look at the disk, not at `old`: the mod may have been enabled or disabled since it was listed
        BOOL oldEnabled = YES;
        NSString *oldPath = [self existingPathForFileName:old.fileName enabled:&oldEnabled];
        if (oldPath && ![oldPath isEqualToString:dest]) {
            [NSFileManager.defaultManager removeItemAtPath:oldPath error:nil];
            // An update of a disabled mod stays disabled
            if (!oldEnabled && ![dest hasSuffix:@".disabled"]) {
                [NSFileManager.defaultManager moveItemAtPath:dest toPath:[dest stringByAppendingString:@".disabled"] error:nil];
            }
        }
    }
    if (depth >= kMaxDependencyDepth) return;
    for (NSDictionary *dep in file.dependencies) {
        NSString *key = [NSString stringWithFormat:@"%ld:%@", (long)source, dep[@"id"]];
        if ([visited containsObject:key]) continue;
        [visited addObject:key];
        // A release when there is one, so a dependency isn't pulled in as somebody's alpha
        NSArray<ModFile *> *depFiles = [self filesForProject:dep[@"id"] source:source];
        ModFile *latest = NewestFile(depFiles, NO) ?: depFiles.firstObject;
        if (latest) {
            [self installFile:latest source:source replacing:nil visited:visited depth:depth + 1 installed:installed problems:problems];
        } else {
            [problems addObject:[NSString stringWithFormat:@"No compatible version of required dependency %@", dep[@"id"]]];
        }
    }
}

/// Replaces (or with nil removes) the entry for a file name in -installed, as a new array of immutable objects
- (void)replaceInstalledModNamed:(NSString *)fileName with:(InstalledMod *)replacement {
    NSMutableArray<InstalledMod *> *list = [NSMutableArray new];
    for (InstalledMod *mod in self.installed) {
        if (![mod.fileName isEqualToString:fileName]) {
            [list addObject:mod];
        } else if (replacement) {
            [list addObject:replacement];
        }
    }
    self.installed = list;
}

- (InstalledMod *)setMod:(InstalledMod *)mod enabled:(BOOL)enabled error:(NSError **)error {
    BOOL currentlyEnabled = YES;
    NSString *current = [self existingPathForFileName:mod.fileName enabled:&currentlyEnabled];
    if (!current) {
        if (error) *error = [NSError errorWithDomain:@"ModCatalog" code:2 userInfo:@{NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"%@ is no longer in the mods folder.", mod.fileName]}];
        return nil;
    }
    NSString *base = [self.modsDir stringByAppendingPathComponent:mod.fileName];
    NSString *target = enabled ? base : [base stringByAppendingString:@".disabled"];
    if (![current isEqualToString:target]) {
        if (![NSFileManager.defaultManager moveItemAtPath:current toPath:target error:error]) return nil;
        if (self.hashCache[current]) self.hashCache[target] = self.hashCache[current];
        [self.hashCache removeObjectForKey:current];
    }
    for (InstalledMod *known in self.installed) {
        if ([known.fileName isEqualToString:mod.fileName]) {
            InstalledMod *updated = [known copy];
            updated.path = target;
            updated.enabled = enabled;
            [self replaceInstalledModNamed:mod.fileName with:updated];
            break;
        }
    }
    InstalledMod *result = [mod copy];
    result.path = target;
    result.enabled = enabled;
    return result;
}

- (BOOL)deleteMod:(InstalledMod *)mod error:(NSError **)error {
    BOOL enabled = YES;
    NSString *path = [self existingPathForFileName:mod.fileName enabled:&enabled];
    if (path) {
        [self.hashCache removeObjectForKey:path];
        if (![NSFileManager.defaultManager removeItemAtPath:path error:error]) return NO;
    }
    [self replaceInstalledModNamed:mod.fileName with:nil];
    return YES;
}

@end
