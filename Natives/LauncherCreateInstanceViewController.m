#import "LauncherCreateInstanceViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "installer/FabricInstallViewController.h"
#import "installer/ForgeInstallViewController.h"
#import "installer/ModpackInstallViewController.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

typedef NS_ENUM(NSInteger, CreateSource) {
    kSourceCustom,
    kSourceFabric,
    kSourceForge,
    kSourceModrinth,
    kSourceImport,
    kSourceCount
};

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

@interface LauncherCreateCustomPage : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate, UITextFieldDelegate>
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
    button.backgroundColor = [UIColor colorWithRed:121/255.0 green:56/255.0 blue:162/255.0 alpha:1.0];
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
            page = [[LauncherEmbeddedNavigationController alloc] initWithRootViewController:[FabricInstallViewController new]];
            break;
        case kSourceForge:
            page = [[LauncherEmbeddedNavigationController alloc] initWithRootViewController:[ForgeInstallViewController new]];
            break;
        case kSourceModrinth:
            page = [[LauncherEmbeddedNavigationController alloc] initWithRootViewController:[ModpackInstallViewController new]];
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

    // Only the Custom page is confirmed with OK; the others finish by themselves
    if (source == kSourceCustom) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:localize(@"OK", nil) style:UIBarButtonItemStyleDone target:self action:@selector(actionCreateCustom)];
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
    NSArray *titles = @[@"create.source.custom", @"Fabric/Quilt", @"Forge", @"Modrinth", @"create.source.import"];
    NSArray *icons = @[@"cube", @"scissors", @"hammer", @"shippingbox", @"square.and.arrow.down"];
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

- (void)actionCreateCustom {
    LauncherCreateCustomPage *page = (id)[self pageForSource:kSourceCustom];
    [self.view endEditing:YES];
    NSString *versionId = page.selectedVersionId;
    if (versionId.length == 0) {
        showDialog(localize(@"Error", nil), localize(@"create.error.no_version", nil));
        return;
    }
    NSString *name = [page instanceName];
    if (PLProfiles.current.profiles[name]) {
        showDialog(localize(@"Error", nil), localize(@"profile.error.name_exists", nil));
        return;
    }

    // Every instance gets its own folder, so mods, worlds and configs never mix
    PLProfiles.current.profiles[name] = @{
        @"name": name,
        @"lastVersionId": versionId,
        @"gameDir": [PLProfiles isolatedGameDirForName:name]
    }.mutableCopy;
    PLProfiles.current.selectedProfileName = name; // saves
    [self dismissViewControllerAnimated:YES completion:nil];
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
