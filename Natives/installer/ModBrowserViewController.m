#import "UIKit+AFNetworking.h"
#import "ModBrowserViewController.h"
#import "modpack/CurseForgeAPI.h"
#import "modpack/ModpackAPI.h"
#import "modpack/ModpackUtils.h"
#import "modpack/ModrinthAPI.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

#define kCurseForgeGameIDMinecraft 432
#define kCurseForgeClassIDMod 6
#define kCurseForgeSortPopularity 2
#define kCurseForgeRelationRequired 3
#define kMaxDependencyDepth 4

typedef NS_ENUM(NSInteger, ModSource) { ModSourceModrinth, ModSourceCurseForge };

/// One downloadable mod file, from either site.
@interface ModFile : NSObject
@property(nonatomic, copy) NSString *label, *fileName, *url, *sha1;
@property(nonatomic) NSArray<NSDictionary *> *dependencies; // @{id: project/mod id}
@end
@implementation ModFile
@end

@interface ModBrowserViewController()
@property(nonatomic, copy) NSString *gameDirPath, *mcVersion, *loader; // loader: fabric, quilt, forge, neoforge or nil
@property(nonatomic) UISegmentedControl *sourceControl;
@property(nonatomic) UISearchController *searchController;
@property(nonatomic) ModrinthAPI *modrinth;
@property(nonatomic) CurseForgeAPI *curseForge;
@property(nonatomic) NSMutableArray<NSDictionary *> *list;
@property(nonatomic) BOOL reachedLastPage, busy;
@property(nonatomic) NSUInteger generation; // bumped on every new search so stale pages are dropped
@property(nonatomic, copy) NSString *query;
@end

@implementation ModBrowserViewController

#pragma mark - Instance info

/// The Minecraft version and loader aren't stored in the profile, only the version id
/// ("fabric-loader-0.15.7-1.20.1", "1.20.1-forge-47.2.0", "neoforge-21.1.5", "1.20.1").
- (void)detectFromVersionId:(NSString *)versionId {
    NSString *gameVersion = nil;
    NSString *current = versionId;
    // Modded version json files name the vanilla version they build on
    for (int i = 0; i < 3 && current.length > 0; i++) {
        NSString *path = [NSString stringWithFormat:@"%s/versions/%@/%@.json", getenv("GAME_DIR"), current, current];
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:nil];
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
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(?<![\\d.])1\\.\\d+(\\.\\d+)?(?![\\d.])" options:0 error:nil];
        NSArray *matches = [regex matchesInString:versionId options:0 range:NSMakeRange(0, versionId.length)];
        // Fabric/Quilt ids end with the game version, after the loader's own version number
        NSTextCheckingResult *match = [self.loader isEqualToString:@"fabric"] || [self.loader isEqualToString:@"quilt"] ? matches.lastObject : matches.firstObject;
        if (match) gameVersion = [versionId substringWithRange:match.range];
    }
    self.mcVersion = gameVersion;
}

- (instancetype)initWithVersionId:(NSString *)versionId gameDirPath:(NSString *)gameDirPath {
    self = [super initWithStyle:UITableViewStylePlain];
    self.gameDirPath = gameDirPath;
    [self detectFromVersionId:versionId ?: @""];
    self.modrinth = [ModrinthAPI new];
    self.curseForge = [CurseForgeAPI new];
    self.list = [NSMutableArray new];
    self.query = @"";
    return self;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = localize(@"mods.browser.title", nil);

    self.sourceControl = [[UISegmentedControl alloc] initWithItems:@[@"Modrinth", @"CurseForge"]];
    self.sourceControl.selectedSegmentIndex = 0;
    [self.sourceControl addTarget:self action:@selector(sourceChanged) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.sourceControl;

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    // Say what is being filtered on, since an empty list is otherwise confusing
    UILabel *footer = [UILabel new];
    footer.font = [UIFont systemFontOfSize:13];
    footer.textColor = UIColor.secondaryLabelColor;
    footer.textAlignment = NSTextAlignmentCenter;
    footer.numberOfLines = 0;
    footer.text = [NSString stringWithFormat:localize(@"mods.browser.filter", nil),
        self.mcVersion ?: @"?", self.loader ?: localize(@"mods.browser.any_loader", nil)];
    footer.frame = CGRectMake(0, 0, 100, 44);
    self.tableView.tableFooterView = footer;

    [self reload];
}

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (ModpackAPI *)api {
    return self.sourceControl.selectedSegmentIndex == ModSourceModrinth ? self.modrinth : self.curseForge;
}

- (void)setBusy:(BOOL)busy {
    _busy = busy;
    if (busy) {
        UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [indicator startAnimating];
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:indicator];
    } else {
        self.navigationItem.rightBarButtonItem = nil;
    }
    self.navigationController.modalInPresentation = busy;
}

#pragma mark - Search

- (void)sourceChanged {
    [self reload];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *text = searchController.searchBar.text ?: @"";
    if ([text isEqualToString:self.query]) return;
    self.query = text;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(reload) object:nil];
    [self performSelector:@selector(reload) withObject:nil afterDelay:0.5];
}

- (void)reload {
    self.generation++;
    self.list = [NSMutableArray new];
    self.reachedLastPage = NO;
    [self.tableView reloadData];
    [self loadNextPage];
}

- (void)loadNextPage {
    if (self.reachedLastPage) return;
    NSUInteger generation = self.generation;
    ModSource source = self.sourceControl.selectedSegmentIndex;
    NSUInteger offset = self.list.count;
    NSString *query = [self.query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    self.busy = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL last = NO;
        NSArray *page = source == ModSourceModrinth ? [self modrinthPageForQuery:query offset:offset last:&last]
                                                    : [self curseForgePageForQuery:query offset:offset last:&last];
        NSError *error = source == ModSourceModrinth ? self.modrinth.lastError : self.curseForge.lastError;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.generation) return; // a newer search replaced this one
            self.busy = NO;
            if (!page) {
                self.reachedLastPage = YES;
                showDialog(localize(@"Error", nil), error.localizedDescription);
                return;
            }
            self.reachedLastPage = last;
            [self.list addObjectsFromArray:page];
            [self.tableView reloadData];
        });
    });
}

static NSString *JSONString(id object) {
    return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:object options:0 error:nil] encoding:NSUTF8StringEncoding];
}

static NSInteger CurseForgeLoaderType(NSString *loader) {
    NSDictionary *types = @{@"forge": @1, @"fabric": @4, @"quilt": @5, @"neoforge": @6};
    return [types[loader] integerValue];
}

- (NSArray *)modrinthPageForQuery:(NSString *)query offset:(NSUInteger)offset last:(BOOL *)last {
    NSMutableArray *facets = [NSMutableArray arrayWithObject:@[@"project_type:mod"]];
    if (self.mcVersion) [facets addObject:@[[@"versions:" stringByAppendingString:self.mcVersion]]];
    if (self.loader) [facets addObject:@[[@"categories:" stringByAppendingString:self.loader]]];
    // Mods that only run on the server are of no use here
    [facets addObject:@[@"client_side:required", @"client_side:optional"]];
    NSDictionary *response = [self.modrinth getEndpoint:@"search" params:@{
        @"facets": JSONString(facets), @"query": query, @"limit": @50, @"index": @"relevance", @"offset": @(offset)}];
    if (![response isKindOfClass:NSDictionary.class]) return nil;
    NSMutableArray *page = [NSMutableArray new];
    for (NSDictionary *hit in response[@"hits"]) {
        [page addObject:@{
            @"id": hit[@"project_id"],
            @"title": hit[@"title"] ?: @"",
            @"description": hit[@"description"] ?: @"",
            @"imageUrl": [hit[@"icon_url"] isKindOfClass:NSString.class] ? hit[@"icon_url"] : @""}];
    }
    *last = page.count == 0 || offset + page.count >= [response[@"total_hits"] unsignedLongValue];
    return page;
}

- (NSArray *)curseForgePageForQuery:(NSString *)query offset:(NSUInteger)offset last:(BOOL *)last {
    if (self.curseForge.apiKey.length == 0) {
        self.curseForge.lastError = [NSError errorWithDomain:@"ModBrowser" code:1 userInfo:@{NSLocalizedDescriptionKey:
            @"This build has no CurseForge API key, so CurseForge can't be searched. Modrinth still works."}];
        return nil;
    }
    NSMutableDictionary *params = @{
        @"gameId": @(kCurseForgeGameIDMinecraft), @"classId": @(kCurseForgeClassIDMod),
        @"sortField": @(kCurseForgeSortPopularity), @"sortOrder": @"desc",
        @"pageSize": @50, @"index": @(offset)}.mutableCopy;
    if (query.length > 0) params[@"searchFilter"] = query;
    if (self.mcVersion) params[@"gameVersion"] = self.mcVersion;
    if (self.loader) params[@"modLoaderType"] = @(CurseForgeLoaderType(self.loader));
    NSDictionary *response = [self.curseForge getEndpoint:@"mods/search" params:params];
    if (![response isKindOfClass:NSDictionary.class] || ![response[@"data"] isKindOfClass:NSArray.class]) return nil;
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

#pragma mark - Versions and downloading

/// Files of a project that fit this instance, newest first.
- (NSArray<ModFile *> *)filesForProject:(id)projectId source:(ModSource)source {
    NSMutableArray<ModFile *> *files = [NSMutableArray new];
    if (source == ModSourceModrinth) {
        NSMutableDictionary *params = [NSMutableDictionary new];
        if (self.mcVersion) params[@"game_versions"] = JSONString(@[self.mcVersion]);
        if (self.loader) params[@"loaders"] = JSONString(@[self.loader]);
        NSArray *versions = [self.modrinth getEndpoint:[NSString stringWithFormat:@"project/%@/version", projectId] params:params];
        if (![versions isKindOfClass:NSArray.class]) return nil;
        for (NSDictionary *version in versions) {
            NSDictionary *file = nil;
            for (NSDictionary *candidate in version[@"files"]) {
                if ([candidate[@"primary"] boolValue]) file = candidate;
            }
            file = file ?: [version[@"files"] firstObject];
            if (!file[@"url"]) continue;
            ModFile *modFile = [ModFile new];
            modFile.label = [NSString stringWithFormat:@"%@ (%@)", version[@"name"] ?: version[@"version_number"], version[@"version_type"] ?: @"release"];
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
            [files addObject:modFile];
        }
    } else {
        NSMutableDictionary *params = @{@"pageSize": @50}.mutableCopy;
        if (self.mcVersion) params[@"gameVersion"] = self.mcVersion;
        if (self.loader) params[@"modLoaderType"] = @(CurseForgeLoaderType(self.loader));
        NSDictionary *response = [self.curseForge getEndpoint:[NSString stringWithFormat:@"mods/%@/files", projectId] params:params];
        if (![response isKindOfClass:NSDictionary.class] || ![response[@"data"] isKindOfClass:NSArray.class]) return nil;
        for (NSDictionary *file in response[@"data"]) {
            NSString *url = [file[@"downloadUrl"] isKindOfClass:NSString.class] && [file[@"downloadUrl"] length] > 0 ? file[@"downloadUrl"] : nil;
            if (!url && [file[@"id"] integerValue] > 0 && [file[@"fileName"] length] > 0) {
                // Same CDN fallback the modpack installer uses for files without a downloadUrl
                NSInteger fileId = [file[@"id"] integerValue];
                url = [NSString stringWithFormat:@"https://edge.forgecdn.net/files/%ld/%ld/%@", (long)(fileId / 1000), (long)(fileId % 1000), file[@"fileName"]];
            }
            if (!url) continue;
            ModFile *modFile = [ModFile new];
            modFile.label = file[@"displayName"] ?: file[@"fileName"];
            modFile.fileName = file[@"fileName"];
            modFile.url = url;
            for (NSDictionary *hash in file[@"hashes"]) {
                if ([hash[@"algo"] integerValue] == 1) modFile.sha1 = hash[@"value"];
            }
            NSMutableArray *deps = [NSMutableArray new];
            for (NSDictionary *dep in file[@"dependencies"]) {
                if ([dep[@"relationType"] integerValue] == kCurseForgeRelationRequired) [deps addObject:@{@"id": dep[@"modId"]}];
            }
            modFile.dependencies = deps;
            [files addObject:modFile];
        }
    }
    return files;
}

/// Blocking: downloads one file into mods/. Returns an error message, or nil on success.
- (NSString *)downloadFile:(ModFile *)file {
    NSString *name = [ModpackUtils sanitizedFileName:file.fileName ?: file.url.lastPathComponent];
    if (![name.lowercaseString hasSuffix:@".jar"]) name = [name stringByAppendingString:@".jar"];
    NSString *modsDir = [self.gameDirPath stringByAppendingPathComponent:@"mods"];
    NSString *dest = [modsDir stringByAppendingPathComponent:name];
    [NSFileManager.defaultManager createDirectoryAtPath:modsDir withIntermediateDirectories:YES attributes:nil error:nil];
    if ([NSFileManager.defaultManager fileExistsAtPath:dest]) return nil;

    __block NSURL *tmp; __block NSError *error;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURL *url = [NSURL URLWithString:file.url];
    if (!url) return [NSString stringWithFormat:@"Invalid download link for %@", name];
    [[NSURLSession.sharedSession downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *err) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 200;
        error = err ?: (status >= 400 ? [NSError errorWithDomain:@"ModBrowser" code:status userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld", (long)status]}] : nil);
        // The file is deleted when this block returns, so move it out now
        if (!error) {
            NSString *staged = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
            if ([NSFileManager.defaultManager moveItemAtURL:location toURL:[NSURL fileURLWithPath:staged] error:&error]) tmp = [NSURL fileURLWithPath:staged];
        }
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (error) return [NSString stringWithFormat:@"%@: %@", name, error.localizedDescription];

    if (file.sha1.length > 0 && ![[ModpackUtils sha1ForFileAtPath:tmp.path].lowercaseString isEqualToString:file.sha1.lowercaseString]) {
        [NSFileManager.defaultManager removeItemAtURL:tmp error:nil];
        return [NSString stringWithFormat:@"%@ is corrupted (checksum mismatch)", name];
    }
    if (![NSFileManager.defaultManager moveItemAtURL:tmp toURL:[NSURL fileURLWithPath:dest] error:&error]) {
        return [NSString stringWithFormat:@"%@: %@", name, error.localizedDescription];
    }
    return nil;
}

/// Blocking: downloads a file and its required dependencies. Appends installed names / problems.
- (void)installFile:(ModFile *)file source:(ModSource)source visited:(NSMutableSet *)visited depth:(int)depth
          installed:(NSMutableArray *)installed problems:(NSMutableArray *)problems {
    NSString *error = [self downloadFile:file];
    if (error) { [problems addObject:error]; return; }
    [installed addObject:file.fileName ?: file.label];
    if (depth >= kMaxDependencyDepth) return;
    for (NSDictionary *dep in file.dependencies) {
        NSString *key = [NSString stringWithFormat:@"%ld:%@", (long)source, dep[@"id"]];
        if ([visited containsObject:key]) continue;
        [visited addObject:key];
        ModFile *latest = [self filesForProject:dep[@"id"] source:source].firstObject;
        if (latest) {
            [self installFile:latest source:source visited:visited depth:depth + 1 installed:installed problems:problems];
        } else {
            [problems addObject:[NSString stringWithFormat:@"No compatible version of required dependency %@", dep[@"id"]]];
        }
    }
}

- (void)pickVersionForRow:(NSIndexPath *)indexPath {
    NSDictionary *item = self.list[indexPath.row];
    ModSource source = self.sourceControl.selectedSegmentIndex;
    self.tableView.userInteractionEnabled = NO;
    self.busy = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray<ModFile *> *files = [self filesForProject:item[@"id"] source:source];
        NSError *error = source == ModSourceModrinth ? self.modrinth.lastError : self.curseForge.lastError;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.tableView.userInteractionEnabled = YES;
            if (!files) {
                showDialog(localize(@"Error", nil), error.localizedDescription);
            } else if (files.count == 0) {
                showDialog(localize(@"Error", nil), [NSString stringWithFormat:localize(@"mods.browser.no_versions", nil),
                    self.mcVersion ?: @"?", self.loader ?: @"-"]);
            } else {
                [self presentVersions:files title:item[@"title"] source:source indexPath:indexPath];
            }
        });
    });
}

- (void)presentVersions:(NSArray<ModFile *> *)files title:(NSString *)title source:(ModSource)source indexPath:(NSIndexPath *)indexPath {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title message:localize(@"mods.browser.pick_version", nil)
        preferredStyle:UIAlertControllerStyleActionSheet];
    for (ModFile *file in files) {
        [sheet addAction:[UIAlertAction actionWithTitle:file.label style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self install:file source:source];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    UIView *cell = [self.tableView cellForRowAtIndexPath:indexPath] ?: self.view;
    sheet.popoverPresentationController.sourceView = cell;
    sheet.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)install:(ModFile *)file source:(ModSource)source {
    self.tableView.userInteractionEnabled = NO;
    self.busy = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray *installed = [NSMutableArray new], *problems = [NSMutableArray new];
        [self installFile:file source:source visited:[NSMutableSet new] depth:0 installed:installed problems:problems];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.tableView.userInteractionEnabled = YES;
            NSMutableArray *lines = [NSMutableArray new];
            if (installed.count) [lines addObject:[NSString stringWithFormat:localize(@"mods.browser.installed", nil), [installed componentsJoinedByString:@"\n"]]];
            if (problems.count) [lines addObject:[problems componentsJoinedByString:@"\n"]];
            showDialog(localize(problems.count && !installed.count ? @"Error" : @"mods.browser.done", nil), [lines componentsJoinedByString:@"\n\n"]);
        });
    });
}

#pragma mark - UITableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.list.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
        cell.imageView.contentMode = UIViewContentModeScaleAspectFill;
        cell.imageView.clipsToBounds = YES;
        cell.imageView.layer.cornerRadius = 6;
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    }
    NSDictionary *item = self.list[indexPath.row];
    cell.textLabel.text = item[@"title"];
    cell.detailTextLabel.text = item[@"description"];
    cell.detailTextLabel.numberOfLines = 2;
    UIImage *fallback = [UIImage imageNamed:@"DefaultProfile"];
    [cell.imageView setImageWithURL:[NSURL URLWithString:item[@"imageUrl"]] placeholderImage:fallback];
    if (!self.reachedLastPage && !self.busy && indexPath.row == self.list.count - 1) {
        [self loadNextPage];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!self.busy) [self pickVersionForRow:indexPath];
}

@end
