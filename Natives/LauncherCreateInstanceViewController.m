#import "LauncherCreateInstanceViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "LauncherTheme.h"
#import "PLProfiles.h"
#import "installer/FabricUtils.h"
#import "installer/modpack/CurseForgeAPI.h"
#import "installer/modpack/ModrinthAPI.h"
#import "installer/ModpackInstallViewController.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

typedef NS_ENUM(NSInteger, CreateSource) {
    kSourceCustom,
    kSourceFabric,
    kSourceForge,
    kSourceModrinth,
    kSourceCurseForge,
    kSourceImport,
    kSourceCount
};

#pragma mark - Shared

/// Every page that creates an instance implements this; the window's OK button calls it.
@protocol LauncherCreatePage <NSObject>
/// Creates the instance. `completion` gets its name on success (the window then closes) or nil when the
/// page has already told the user what went wrong.
- (void)createInstanceWithCompletion:(void (^)(NSString *name))completion;
@end

/// Adds a profile (= instance) with its own game folder and selects it. nil, after an error dialog, if the name is taken.
static NSString *CreateInstanceProfile(NSString *name, NSString *versionId, NSString *iconURL) {
    if (PLProfiles.current.profiles[name]) {
        showDialog(localize(@"Error", nil), localize(@"profile.error.name_exists", nil));
        return nil;
    }
    NSMutableDictionary *profile = @{
        @"name": name,
        @"lastVersionId": versionId,
        // Every instance gets its own folder, so mods, worlds and configs never mix
        @"gameDir": [PLProfiles isolatedGameDirForName:name]
    }.mutableCopy;
    if (iconURL.length > 0) profile[@"icon"] = iconURL;
    PLProfiles.current.profiles[name] = profile;
    PLProfiles.current.selectedProfileName = name; // saves
    return name;
}

#pragma mark - Embedded navigation

/// Hosts the existing installer screens. Those close themselves with
/// `[self.navigationController dismissViewControllerAnimated:]`, which has to close the whole window.
@interface LauncherEmbeddedNavigationController : UINavigationController
@end

@implementation LauncherEmbeddedNavigationController
- (void)dismissViewControllerAnimated:(BOOL)flag completion:(void (^)(void))completion {
    if (self.presentedViewController || !self.parentViewController) {
        [super dismissViewControllerAnimated:flag completion:completion];
        return;
    }
    [self.parentViewController dismissViewControllerAnimated:flag completion:completion];
}
@end

#pragma mark - Custom (vanilla) page

@interface LauncherCreateCustomPage : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate, UITextFieldDelegate, LauncherCreatePage>
@property(nonatomic) UITextField *nameField;
@property(nonatomic) UISegmentedControl *filterControl;
@property(nonatomic) UISearchBar *searchBar;
@property(nonatomic) UITableView *tableView;
@property(nonatomic) NSArray<NSDictionary *> *visibleVersions;
@property(nonatomic, copy) NSString *selectedVersionId;
@property(nonatomic) BOOL nameEditedByUser;
/// Name to use: what the user typed, or the selected version
- (NSString *)instanceName;
@end

@implementation LauncherCreateCustomPage

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UILabel *nameLabel = [UILabel new];
    nameLabel.text = localize(@"instance.name", nil);
    nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [nameLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    self.nameField = [UITextField new];
    self.nameField.borderStyle = UITextBorderStyleRoundedRect;
    self.nameField.placeholder = localize(@"create.name.placeholder", nil);
    self.nameField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.nameField.returnKeyType = UIReturnKeyDone;
    self.nameField.delegate = self;
    [self.nameField addTarget:self action:@selector(nameEdited) forControlEvents:UIControlEventEditingChanged];

    UIStackView *nameRow = [[UIStackView alloc] initWithArrangedSubviews:@[nameLabel, self.nameField]];
    nameRow.spacing = 12;
    nameRow.alignment = UIStackViewAlignmentCenter;

    self.filterControl = [[UISegmentedControl alloc] initWithItems:@[
        localize(@"Releases", nil), localize(@"Snapshot", nil),
        localize(@"Old-beta", nil), localize(@"Old-alpha", nil), localize(@"Installed", nil)]];
    self.filterControl.selectedSegmentIndex = 0;
    [self.filterControl addTarget:self action:@selector(filterChanged) forControlEvents:UIControlEventValueChanged];

    self.searchBar = [UISearchBar new];
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.placeholder = localize(@"create.search", nil);
    self.searchBar.delegate = self;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.layer.cornerRadius = 10;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[nameRow, self.filterControl, self.searchBar, self.tableView]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
    ]];

    [self reloadVersions];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // The version manifest may have finished downloading since this page was created
    [self reloadVersions];
}

- (NSArray<NSDictionary *> *)allVersionsForFilter:(NSInteger)filter {
    if (filter == 4) {
        return localVersionList ?: @[];
    }
    NSArray *types = @[@"release", @"snapshot", @"old_beta", @"old_alpha"];
    NSArray<NSDictionary *> *source = remoteVersionList;
    if (source.count == 0) {
        // Manifest not loaded (yet): the two "latest" entries always work
        source = @[@{@"id": @"latest-release", @"type": @"release"},
                   @{@"id": @"latest-snapshot", @"type": @"snapshot"}];
    }
    return [source filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"type == %@", types[filter]]];
}

- (void)reloadVersions {
    NSArray<NSDictionary *> *all = [self allVersionsForFilter:self.filterControl.selectedSegmentIndex];
    NSString *query = [self.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (query.length > 0) {
        all = [all filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"id CONTAINS[cd] %@", query]];
    }
    self.visibleVersions = all;
    [self.tableView reloadData];

    NSUInteger index = [[all valueForKey:@"id"] indexOfObject:self.selectedVersionId ?: @""];
    if (index == NSNotFound) {
        index = 0;
        self.selectedVersionId = all.firstObject[@"id"];
        [self applyDefaultName];
    }
    if (all.count > 0) {
        [self.tableView selectRowAtIndexPath:[NSIndexPath indexPathForRow:index inSection:0] animated:NO scrollPosition:UITableViewScrollPositionMiddle];
    }
}

/// "latest-release" is shown with the version it currently points to, like Prism does
- (NSString *)displayNameForVersionId:(NSString *)versionId {
    NSDictionary *latest = getPrefObject(@"internal.latest_version");
    if ([versionId isEqualToString:@"latest-release"] && [latest[@"release"] length] > 0) return latest[@"release"];
    if ([versionId isEqualToString:@"latest-snapshot"] && [latest[@"snapshot"] length] > 0) return latest[@"snapshot"];
    return versionId;
}

- (void)applyDefaultName {
    if (!self.nameEditedByUser && self.selectedVersionId) {
        self.nameField.text = [self displayNameForVersionId:self.selectedVersionId];
    }
}

- (NSString *)instanceName {
    NSString *name = [self.nameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return name.length > 0 ? name : [self displayNameForVersionId:self.selectedVersionId ?: @""];
}

- (void)nameEdited {
    self.nameEditedByUser = self.nameField.text.length > 0;
}

- (void)createInstanceWithCompletion:(void (^)(NSString *))completion {
    [self.view endEditing:YES];
    if (self.selectedVersionId.length == 0) {
        showDialog(localize(@"Error", nil), localize(@"create.error.no_version", nil));
        completion(nil);
        return;
    }
    completion(CreateInstanceProfile([self instanceName], self.selectedVersionId, nil));
}

- (void)filterChanged {
    [self.view endEditing:YES];
    self.selectedVersionId = nil;
    [self reloadVersions];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self reloadVersions];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

#pragma mark Table view

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.visibleVersions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"version"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"version"];
    }
    NSDictionary *version = self.visibleVersions[indexPath.row];
    cell.textLabel.text = [self displayNameForVersionId:version[@"id"]];
    NSString *date = [version[@"releaseTime"] isKindOfClass:NSString.class] ? [version[@"releaseTime"] substringToIndex:MIN(10, [version[@"releaseTime"] length])] : nil;
    BOOL isLatest = [version[@"id"] hasPrefix:@"latest-"];
    cell.detailTextLabel.text = isLatest ? [version[@"id"] stringByReplacingOccurrencesOfString:@"-" withString:@" "] : (date ?: version[@"type"]);
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [self.view endEditing:YES];
    self.selectedVersionId = self.visibleVersions[indexPath.row][@"id"];
    [self applyDefaultName];
}

@end

#pragma mark - Loader pages (Fabric/Quilt, Forge/NeoForge)

typedef NS_ENUM(NSInteger, LoaderKind) { kLoaderFabric, kLoaderForge };

/// Same layout as the Custom page (name, filter, search, Minecraft version list) plus a loader version picker.
@interface LauncherCreateLoaderPage : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate, UITextFieldDelegate, LauncherCreatePage>
@property(nonatomic) LoaderKind kind;
@property(nonatomic) NSArray<NSString *> *vendors;
@property(nonatomic) UITextField *nameField;
@property(nonatomic) UISegmentedControl *vendorControl, *filterControl;
@property(nonatomic) UISearchBar *searchBar;
@property(nonatomic) UITableView *tableView;
@property(nonatomic) UIButton *loaderButton;
@property(nonatomic) UILabel *statusLabel;
@property(nonatomic) UIActivityIndicatorView *spinner;
@property(nonatomic) BOOL nameEditedByUser;

// Per vendor: @{@"games": NSArray<NSDictionary *> (version, stable), @"loaders": NSArray<NSDictionary *> or NSDictionary<mc, NSArray>}
@property(nonatomic) NSMutableDictionary<NSString *, NSDictionary *> *cache;
@property(nonatomic) NSArray<NSDictionary *> *visibleGames;
@property(nonatomic) NSArray<NSString *> *visibleLoaders;
@property(nonatomic, copy) NSString *selectedGame, *selectedLoader;
@property(nonatomic) NSInteger loadGeneration;
@end

@implementation LauncherCreateLoaderPage

- (instancetype)initWithKind:(LoaderKind)kind {
    self = [super initWithNibName:nil bundle:nil];
    self.kind = kind;
    self.vendors = kind == kLoaderFabric ? @[@"Fabric", @"Quilt"] : @[@"Forge", @"NeoForge"];
    self.cache = [NSMutableDictionary new];
    return self;
}

- (NSString *)vendor {
    return self.vendors[self.vendorControl.selectedSegmentIndex];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UILabel *nameLabel = [UILabel new];
    nameLabel.text = localize(@"instance.name", nil);
    nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [nameLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    self.nameField = [UITextField new];
    self.nameField.borderStyle = UITextBorderStyleRoundedRect;
    self.nameField.placeholder = localize(@"create.name.placeholder", nil);
    self.nameField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.nameField.returnKeyType = UIReturnKeyDone;
    self.nameField.delegate = self;
    [self.nameField addTarget:self action:@selector(nameEdited) forControlEvents:UIControlEventEditingChanged];

    UIStackView *nameRow = [[UIStackView alloc] initWithArrangedSubviews:@[nameLabel, self.nameField]];
    nameRow.spacing = 12;
    nameRow.alignment = UIStackViewAlignmentCenter;

    self.vendorControl = [[UISegmentedControl alloc] initWithItems:self.vendors];
    self.vendorControl.selectedSegmentIndex = 0;
    [self.vendorControl addTarget:self action:@selector(vendorChanged) forControlEvents:UIControlEventValueChanged];

    NSMutableArray<UIView *> *rows = [NSMutableArray arrayWithObjects:nameRow, self.vendorControl, nil];
    if (self.kind == kLoaderFabric) {
        self.filterControl = [[UISegmentedControl alloc] initWithItems:@[localize(@"Releases", nil), localize(@"Snapshot", nil)]];
        self.filterControl.selectedSegmentIndex = 0;
        [self.filterControl addTarget:self action:@selector(filterChanged) forControlEvents:UIControlEventValueChanged];
        [rows addObject:self.filterControl];
    }

    self.searchBar = [UISearchBar new];
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.placeholder = localize(@"create.search", nil);
    self.searchBar.delegate = self;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [rows addObject:self.searchBar];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.layer.cornerRadius = 10;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;

    self.statusLabel = [UILabel new];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.tableView addSubview:self.statusLabel];
    [self.tableView addSubview:self.spinner];
    [NSLayoutConstraint activateConstraints:@[
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.tableView.frameLayoutGuide.centerXAnchor],
        [self.spinner.topAnchor constraintEqualToAnchor:self.tableView.frameLayoutGuide.topAnchor constant:40],
        [self.statusLabel.centerXAnchor constraintEqualToAnchor:self.tableView.frameLayoutGuide.centerXAnchor],
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.spinner.bottomAnchor constant:8],
        [self.statusLabel.widthAnchor constraintLessThanOrEqualToAnchor:self.tableView.frameLayoutGuide.widthAnchor constant:-32],
    ]];
    [rows addObject:self.tableView];

    // Loader version, the equivalent of Prism's mod loader version
    UILabel *loaderLabel = [UILabel new];
    loaderLabel.text = localize(@"create.loader_version", nil);
    loaderLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [loaderLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    self.loaderButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.loaderButton.showsMenuAsPrimaryAction = YES;
    self.loaderButton.tintColor = UIColor.labelColor;
    self.loaderButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.loaderButton.contentEdgeInsets = UIEdgeInsetsMake(8, 12, 8, 36);
    self.loaderButton.layer.cornerRadius = 10;
    self.loaderButton.layer.borderWidth = 1;
    self.loaderButton.layer.borderColor = UIColor.separatorColor.CGColor;
    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.down"]];
    chevron.tintColor = UIColor.secondaryLabelColor;
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loaderButton addSubview:chevron];
    [NSLayoutConstraint activateConstraints:@[
        [chevron.trailingAnchor constraintEqualToAnchor:self.loaderButton.trailingAnchor constant:-12],
        [chevron.centerYAnchor constraintEqualToAnchor:self.loaderButton.centerYAnchor],
    ]];
    UIStackView *loaderRow = [[UIStackView alloc] initWithArrangedSubviews:@[loaderLabel, self.loaderButton]];
    loaderRow.spacing = 12;
    loaderRow.alignment = UIStackViewAlignmentCenter;
    [self.loaderButton.heightAnchor constraintGreaterThanOrEqualToConstant:36].active = YES;
    [rows addObject:loaderRow];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:rows];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
    ]];

    [self loadVendor];
}

#pragma mark Data

- (NSDictionary *)endpoint {
    return FabricUtils.endpoints[[self vendor]];
}

- (void)setLoading:(BOOL)loading message:(NSString *)message {
    loading ? [self.spinner startAnimating] : [self.spinner stopAnimating];
    self.statusLabel.text = message;
    self.statusLabel.hidden = message.length == 0;
}

- (void)fetchJSONFromURL:(NSString *)url completion:(void (^)(id json, NSError *error))completion {
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:url]
    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        id json = nil;
        if (!error) {
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 200;
            if (status != 200 || !data) {
                error = [NSError errorWithDomain:@"CreateInstance" code:status userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld for %@", (long)status, url]}];
            } else {
                json = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&error];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(json, error); });
    }];
    [task resume];
}

- (void)loadVendor {
    NSString *vendor = [self vendor];
    NSDictionary *cached = self.cache[vendor];
    if (cached) {
        [self applyData];
        return;
    }
    NSInteger generation = ++self.loadGeneration;
    self.visibleGames = @[];
    self.visibleLoaders = @[];
    [self.tableView reloadData];
    [self updateLoaderMenu];
    [self setLoading:YES message:nil];

    __weak typeof(self) weakSelf = self;
    void (^failed)(NSError *) = ^(NSError *error) {
        if (weakSelf.loadGeneration != generation) return;
        [weakSelf setLoading:NO message:[NSString stringWithFormat:localize(@"create.error.load", nil), error.localizedDescription]];
    };

    if (self.kind == kLoaderFabric) {
        NSDictionary *endpoint = [self endpoint];
        [self fetchJSONFromURL:endpoint[@"game"] completion:^(id games, NSError *error) {
            if (error || ![games isKindOfClass:NSArray.class]) { failed(error); return; }
            [weakSelf fetchJSONFromURL:endpoint[@"loader"] completion:^(id loaders, NSError *loaderError) {
                if (loaderError || ![loaders isKindOfClass:NSArray.class]) { failed(loaderError); return; }
                weakSelf.cache[vendor] = @{@"games": games, @"loaders": loaders};
                if (weakSelf.loadGeneration == generation) [weakSelf applyData];
            }];
        }];
        return;
    }

    // Forge / NeoForge: maven-metadata.xml lists every build
    NSString *metadataURL = [vendor isEqualToString:@"Forge"]
        ? @"https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml"
        : @"https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml";
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:metadataURL]
    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *parsed = nil;
        if (!error && data) {
            parsed = [LauncherCreateLoaderPage parseMetadata:data forVendor:vendor];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!parsed) {
                failed(error ?: [NSError errorWithDomain:@"CreateInstance" code:1 userInfo:@{NSLocalizedDescriptionKey: @"unexpected response"}]);
                return;
            }
            weakSelf.cache[vendor] = parsed;
            if (weakSelf.loadGeneration == generation) [weakSelf applyData];
        });
    }];
    [task resume];
}

/// @{@"games": [@{@"version": mc}], @"loaders": @{mc: [loader versions, newest first]}}
+ (NSDictionary *)parseMetadata:(NSData *)data forVendor:(NSString *)vendor {
    NSString *xml = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"<version>([^<]+)</version>" options:0 error:nil];
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *byGame = [NSMutableDictionary new];
    for (NSTextCheckingResult *match in [regex matchesInString:xml options:0 range:NSMakeRange(0, xml.length)]) {
        NSString *version = [xml substringWithRange:[match rangeAtIndex:1]];
        NSString *mc, *loader;
        if ([vendor isEqualToString:@"Forge"]) {
            // "1.20.1-47.2.0", older ones "1.7.10-10.13.4.1614-1.7.10"
            NSRange dash = [version rangeOfString:@"-"];
            if (dash.location == NSNotFound) continue;
            mc = [version substringToIndex:dash.location];
            loader = [version substringFromIndex:NSMaxRange(dash)];
        } else {
            // NeoForge "21.1.5" belongs to Minecraft 1.21.1, "21.0.3" to 1.21; prereleases carry letters
            NSArray<NSString *> *parts = [version componentsSeparatedByString:@"."];
            if (parts.count < 3 || [version rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].length > 0) continue;
            NSInteger minor = parts[1].integerValue;
            mc = minor == 0 ? [NSString stringWithFormat:@"1.%@", parts[0]] : [NSString stringWithFormat:@"1.%@.%ld", parts[0], (long)minor];
            loader = version;
        }
        if (mc.length == 0 || loader.length == 0) continue;
        if (!byGame[mc]) byGame[mc] = [NSMutableArray new];
        [byGame[mc] addObject:loader];
    }
    if (byGame.count == 0) return nil;
    // The order of the metadata file isn't consistent (1.7.10 is newest first, newer versions oldest first), and the
    // first entry becomes the default, so sort every list by version number, newest first
    for (NSMutableArray<NSString *> *loaders in byGame.allValues) {
        [loaders sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            return [b compare:a options:NSNumericSearch];
        }];
    }
    NSArray<NSString *> *sorted = [byGame.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [b compare:a options:NSNumericSearch];
    }];
    NSMutableArray *games = [NSMutableArray new];
    for (NSString *mc in sorted) [games addObject:@{@"version": mc}];
    return @{@"games": games, @"loaders": byGame};
}

- (void)applyData {
    NSDictionary *data = self.cache[[self vendor]];
    [self setLoading:NO message:nil];
    NSArray<NSDictionary *> *games = data[@"games"];
    if (self.kind == kLoaderFabric) {
        // Fabric has an explicit stable flag, Quilt marks prereleases in the version name
        BOOL wantStable = self.filterControl.selectedSegmentIndex == 0;
        games = [games filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *g, id _) {
            return [g[@"stable"] boolValue] == wantStable;
        }]];
    }
    NSString *query = [self.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (query.length > 0) {
        games = [games filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"version CONTAINS[cd] %@", query]];
    }
    self.visibleGames = games;
    [self.tableView reloadData];

    NSUInteger index = [[games valueForKey:@"version"] indexOfObject:self.selectedGame ?: @""];
    if (index == NSNotFound) {
        index = 0;
        self.selectedGame = games.firstObject[@"version"];
        self.selectedLoader = nil;
    }
    if (games.count > 0) {
        [self.tableView selectRowAtIndexPath:[NSIndexPath indexPathForRow:index inSection:0] animated:NO scrollPosition:UITableViewScrollPositionMiddle];
    }
    [self updateLoaderMenu];
    [self applyDefaultName];
}

/// Newest stable Fabric/Quilt loader
- (NSString *)defaultLoaderVersion {
    for (NSDictionary *l in self.cache[[self vendor]][@"loaders"]) {
        BOOL isStable = l[@"stable"] ? [l[@"stable"] boolValue] : ![l[@"version"] containsString:@"beta"];
        if (isStable) return l[@"version"];
    }
    return [self.cache[[self vendor]][@"loaders"] firstObject][@"version"];
}

- (void)updateLoaderMenu {
    NSDictionary *data = self.cache[[self vendor]];
    NSArray<NSString *> *loaders = @[];
    if (self.kind == kLoaderFabric) {
        // Stable builds first (Quilt has no flag: prereleases carry "beta" in the name)
        NSMutableArray *stable = [NSMutableArray new], *other = [NSMutableArray new];
        for (NSDictionary *l in data[@"loaders"]) {
            BOOL isStable = l[@"stable"] ? [l[@"stable"] boolValue] : ![l[@"version"] containsString:@"beta"];
            [(isStable ? stable : other) addObject:l[@"version"]];
        }
        loaders = [stable arrayByAddingObjectsFromArray:other];
    } else if (self.selectedGame) {
        loaders = ((NSDictionary *)data[@"loaders"])[self.selectedGame] ?: @[];
    }
    self.visibleLoaders = loaders;
    if (![loaders containsObject:self.selectedLoader ?: @""]) {
        self.selectedLoader = loaders.firstObject;
    }

    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIAction *> *actions = [NSMutableArray new];
    for (NSString *loader in loaders) {
        UIAction *action = [UIAction actionWithTitle:loader image:nil identifier:nil handler:^(UIAction *a) {
            weakSelf.selectedLoader = loader;
            [weakSelf updateLoaderMenu];
        }];
        action.state = [loader isEqualToString:self.selectedLoader] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    self.loaderButton.menu = [UIMenu menuWithTitle:@"" children:actions];
    [self.loaderButton setTitle:self.selectedLoader ?: @"-" forState:UIControlStateNormal];

    // Keep the selected row's right-hand version in step with the dropdown
    NSIndexPath *selected = self.tableView.indexPathForSelectedRow;
    if (selected && self.kind == kLoaderFabric) {
        [self.tableView cellForRowAtIndexPath:selected].detailTextLabel.text = self.selectedLoader;
    }
}

#pragma mark Name

- (NSString *)defaultName {
    return self.selectedGame ? [NSString stringWithFormat:@"%@ %@", [self vendor], self.selectedGame] : @"";
}

- (void)applyDefaultName {
    if (!self.nameEditedByUser) self.nameField.text = [self defaultName];
}

- (void)nameEdited {
    self.nameEditedByUser = self.nameField.text.length > 0;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

#pragma mark Controls

- (void)vendorChanged {
    [self.view endEditing:YES];
    self.selectedGame = nil;
    self.selectedLoader = nil;
    [self loadVendor];
}

- (void)filterChanged {
    [self.view endEditing:YES];
    self.selectedGame = nil;
    if (self.cache[[self vendor]]) [self applyData];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    if (self.cache[[self vendor]]) [self applyData];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

#pragma mark Table view

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.visibleGames.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"game"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"game"];
    }
    NSString *game = self.visibleGames[indexPath.row][@"version"];
    cell.textLabel.text = game;
    if (self.kind == kLoaderForge) {
        NSString *latest = ((NSArray *)((NSDictionary *)self.cache[[self vendor]][@"loaders"])[game]).firstObject;
        cell.detailTextLabel.text = latest;
    } else {
        // Fabric/Quilt loaders work with every game version: the chosen one for the selected row, else the default
        cell.detailTextLabel.text = [game isEqualToString:self.selectedGame] ? self.selectedLoader : [self defaultLoaderVersion];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [self.view endEditing:YES];
    self.selectedGame = self.visibleGames[indexPath.row][@"version"];
    self.selectedLoader = nil;
    [self updateLoaderMenu];
    [self applyDefaultName];
}

#pragma mark Creating

- (NSString *)instanceName {
    NSString *name = [self.nameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return name.length > 0 ? name : [self defaultName];
}

- (void)createInstanceWithCompletion:(void (^)(NSString *))completion {
    [self.view endEditing:YES];
    if (!self.selectedGame || !self.selectedLoader) {
        showDialog(localize(@"Error", nil), localize(@"create.error.no_version", nil));
        completion(nil);
        return;
    }
    NSString *name = [self instanceName];
    if (PLProfiles.current.profiles[name]) {
        showDialog(localize(@"Error", nil), localize(@"profile.error.name_exists", nil));
        completion(nil);
        return;
    }

    if (self.kind == kLoaderForge) {
        // Forge and NeoForge are unpacked the first time Play is pressed (ModLoaderInstaller)
        NSString *versionId = [[self vendor] isEqualToString:@"Forge"]
            ? [NSString stringWithFormat:@"%@-forge-%@", self.selectedGame, self.selectedLoader]
            : [@"neoforge-" stringByAppendingString:self.selectedLoader];
        completion(CreateInstanceProfile(name, versionId, nil));
        return;
    }

    // Fabric / Quilt: fetch the launch profile of this game + loader combination now
    NSDictionary *endpoint = [self endpoint];
    NSString *url = [NSString stringWithFormat:endpoint[@"json"], self.selectedGame, self.selectedLoader];
    self.view.userInteractionEnabled = NO;
    __weak typeof(self) weakSelf = self;
    [self fetchJSONFromURL:url completion:^(id profile, NSError *error) {
        weakSelf.view.userInteractionEnabled = YES;
        if (error || ![profile isKindOfClass:NSDictionary.class] || ![profile[@"id"] length]) {
            showDialog(localize(@"Error", nil), error.localizedDescription ?: @"unexpected response");
            completion(nil);
            return;
        }
        NSString *versionId = profile[@"id"];
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("GAME_DIR"), versionId];
        [NSFileManager.defaultManager createDirectoryAtPath:jsonPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        NSError *saveError = saveJSONToFile(profile, jsonPath);
        if (saveError) {
            showDialog(localize(@"Error", nil), saveError.localizedDescription);
            completion(nil);
            return;
        }
        [localVersionList addObject:@{@"id": versionId, @"type": @"custom"}];
        completion(CreateInstanceProfile(name, versionId, endpoint[@"icon"]));
    }];
}

@end

#pragma mark - Import page

@interface LauncherCreateImportPage : UIViewController
@property(nonatomic, copy) void (^onChooseFile)(UIButton *sender);
@end

@implementation LauncherCreateImportPage

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"square.and.arrow.down.on.square"]];
    icon.tintColor = UIColor.secondaryLabelColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [icon.heightAnchor constraintEqualToConstant:64].active = YES;

    UILabel *title = [UILabel new];
    title.text = localize(@"create.import.title", nil);
    title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *detail = [UILabel new];
    detail.text = localize(@"create.import.detail", nil);
    detail.font = [UIFont systemFontOfSize:15];
    detail.textColor = UIColor.secondaryLabelColor;
    detail.textAlignment = NSTextAlignmentCenter;
    detail.numberOfLines = 0;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:localize(@"create.import.choose", nil) forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    button.tintColor = UIColor.whiteColor;
    button.backgroundColor = LauncherTheme.accent;
    button.layer.cornerRadius = 10;
    button.contentEdgeInsets = UIEdgeInsetsMake(12, 28, 12, 28);
    [button addTarget:self action:@selector(chooseTapped:) forControlEvents:UIControlEventPrimaryActionTriggered];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[icon, title, detail, button]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
    ]];
}

- (void)chooseTapped:(UIButton *)sender {
    if (self.onChooseFile) self.onChooseFile(sender);
}

@end

#pragma mark - Create window

@interface LauncherCreateInstanceViewController () <UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate>
@property(nonatomic) UITableView *sourceTable;
@property(nonatomic) UIView *container;
@property(nonatomic) NSMutableDictionary<NSNumber *, UIViewController *> *pages;
@property(nonatomic) UIViewController *currentPage;
@property(nonatomic) NSInteger currentSource;
@property(nonatomic) NSSet<NSString *> *profileNamesAtStart;
@property(nonatomic) NSString *selectedAtStart;
@end

@implementation LauncherCreateInstanceViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = localize(@"create.title", nil);
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.pages = [NSMutableDictionary new];
    self.profileNamesAtStart = [NSSet setWithArray:PLProfiles.current.profiles.allKeys];
    self.selectedAtStart = PLProfiles.current.selectedProfileName;

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(actionCancel)];
    self.navigationController.modalInPresentation = YES;

    self.sourceTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.sourceTable.dataSource = self;
    self.sourceTable.delegate = self;
    self.sourceTable.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.sourceTable];

    UIView *divider = [UIView new];
    divider.backgroundColor = UIColor.separatorColor;
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:divider];

    self.container = [UIView new];
    self.container.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.container];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *sidebarWidth = [self.sourceTable.widthAnchor constraintEqualToAnchor:self.view.widthAnchor multiplier:0.3];
    sidebarWidth.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [self.sourceTable.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.sourceTable.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.sourceTable.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        sidebarWidth,
        [self.sourceTable.widthAnchor constraintGreaterThanOrEqualToConstant:150],
        [self.sourceTable.widthAnchor constraintLessThanOrEqualToConstant:230],

        [divider.leadingAnchor constraintEqualToAnchor:self.sourceTable.trailingAnchor],
        [divider.widthAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale],
        [divider.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [divider.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.container.leadingAnchor constraintEqualToAnchor:divider.trailingAnchor],
        [self.container.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.container.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.container.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [self showSource:kSourceCustom];
    [self.sourceTable selectRowAtIndexPath:[NSIndexPath indexPathForRow:kSourceCustom inSection:0] animated:NO scrollPosition:UITableViewScrollPositionNone];
}

#pragma mark Pages

- (UIViewController *)pageForSource:(CreateSource)source {
    UIViewController *page = self.pages[@(source)];
    if (page) return page;

    switch (source) {
        case kSourceCustom:
            page = [LauncherCreateCustomPage new];
            break;
        case kSourceFabric:
            page = [[LauncherCreateLoaderPage alloc] initWithKind:kLoaderFabric];
            break;
        case kSourceForge:
            page = [[LauncherCreateLoaderPage alloc] initWithKind:kLoaderForge];
            break;
        case kSourceModrinth:
            page = [self modpackPageWithAPI:[ModrinthAPI new] title:@"Modrinth"];
            break;
        case kSourceCurseForge:
            page = [self modpackPageWithAPI:[CurseForgeAPI new] title:@"CurseForge"];
            break;
        case kSourceImport: {
            LauncherCreateImportPage *importPage = [LauncherCreateImportPage new];
            __weak typeof(self) weakSelf = self;
            importPage.onChooseFile = ^(UIButton *sender) { [weakSelf actionChooseFile]; };
            page = importPage;
            break;
        }
        default:
            return nil;
    }
    self.pages[@(source)] = page;
    return page;
}

- (UIViewController *)modpackPageWithAPI:(ModpackAPI *)api title:(NSString *)title {
    ModpackInstallViewController *list = [ModpackInstallViewController new];
    list.api = api;
    list.embedded = YES;
    list.title = title;
    return [[LauncherEmbeddedNavigationController alloc] initWithRootViewController:list];
}

- (void)showSource:(CreateSource)source {
    UIViewController *page = [self pageForSource:source];
    if (!page || page == self.currentPage) return;

    [self.currentPage willMoveToParentViewController:nil];
    [self.currentPage.view removeFromSuperview];
    [self.currentPage removeFromParentViewController];

    [self addChildViewController:page];
    page.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.container addSubview:page.view];
    [NSLayoutConstraint activateConstraints:@[
        [page.view.topAnchor constraintEqualToAnchor:self.container.topAnchor],
        [page.view.bottomAnchor constraintEqualToAnchor:self.container.bottomAnchor],
        [page.view.leadingAnchor constraintEqualToAnchor:self.container.leadingAnchor],
        [page.view.trailingAnchor constraintEqualToAnchor:self.container.trailingAnchor],
    ]];
    [page didMoveToParentViewController:self];
    self.currentPage = page;
    self.currentSource = source;

    // Pages that create an instance themselves are confirmed with OK; Modrinth and Import finish by themselves
    if ([page conformsToProtocol:@protocol(LauncherCreatePage)]) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:localize(@"OK", nil) style:UIBarButtonItemStyleDone target:self action:@selector(actionCreate)];
    } else {
        self.navigationItem.rightBarButtonItem = nil;
    }
}

#pragma mark Source list

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return kSourceCount;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"source"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"source"];
    }
    NSArray *titles = @[@"create.source.custom", @"Fabric/Quilt", @"Forge", @"Modrinth", @"CurseForge", @"create.source.import"];
    NSArray *icons = @[@"cube", @"scissors", @"hammer", @"shippingbox", @"flame", @"square.and.arrow.down"];
    NSString *title = titles[indexPath.row];
    cell.textLabel.text = [title hasPrefix:@"create."] ? localize(title, nil) : title;
    cell.imageView.image = [UIImage systemImageNamed:icons[indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [self.view endEditing:YES];
    [self showSource:(CreateSource)indexPath.row];
}

#pragma mark Actions

- (void)actionCancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)actionCreate {
    id<LauncherCreatePage> page = (id)self.currentPage;
    if (![page conformsToProtocol:@protocol(LauncherCreatePage)]) return;
    self.navigationItem.rightBarButtonItem.enabled = NO;
    [page createInstanceWithCompletion:^(NSString *name) {
        self.navigationItem.rightBarButtonItem.enabled = YES;
        if (name) [self dismissViewControllerAnimated:YES completion:nil];
    }];
}

- (void)actionChooseFile {
    // .zip = CurseForge pack or Prism instance, .mrpack = Modrinth pack (itself a zip). The .mrpack type is
    // usually undeclared on iOS, so ask for its extension as well as plain zip files.
    NSMutableArray<UTType *> *types = [NSMutableArray arrayWithObject:UTTypeZIP];
    UTType *mrpack = [UTType typeWithFilenameExtension:@"mrpack"];
    if (mrpack) [types addObject:mrpack];

    // asCopy: the pack is copied into our sandbox first (like Android copies it to its cache)
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSString *path = urls.firstObject.path;
    if (!path) return;
    // Close the window first so the progress in the launch bar is visible; LauncherNavigationController owns the task
    [self dismissViewControllerAnimated:YES completion:^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"ImportModpack" object:self userInfo:@{@"path": path}];
    }];
}

#pragma mark Dismissal

/// Also used by the embedded installers (through LauncherEmbeddedNavigationController) to close the window.
- (void)dismissViewControllerAnimated:(BOOL)flag completion:(void (^)(void))completion {
    if (self.presentedViewController) {
        // A file picker or alert on top of this window
        [super dismissViewControllerAnimated:flag completion:completion];
        return;
    }
    UIViewController *presenter = self.navigationController.presentingViewController ?: self.presentingViewController;
    if (!presenter) {
        [super dismissViewControllerAnimated:flag completion:completion];
        return;
    }
    void (^onFinished)(NSString *) = self.onFinished;
    BOOL changed = ![[NSSet setWithArray:PLProfiles.current.profiles.allKeys] isEqualToSet:self.profileNamesAtStart] ||
        ![PLProfiles.current.selectedProfileName isEqualToString:self.selectedAtStart];
    [presenter dismissViewControllerAnimated:flag completion:^{
        if (changed) {
            [NSNotificationCenter.defaultCenter postNotificationName:PLProfilesDidChangeNotification object:nil];
            if (onFinished) onFinished(PLProfiles.current.selectedProfileName);
        }
        if (completion) completion();
    }];
}

@end
