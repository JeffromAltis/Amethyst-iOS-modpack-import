#import "LauncherIconPickerViewController.h"
#import "InstanceIcons.h"
#import "LauncherTheme.h"
#import "PLProfiles.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

typedef NS_ENUM(NSInteger, IconCategory) {
    IconCategoryAll,
    IconCategoryModern,
    IconCategoryModpacks,
    IconCategoryCustom,
};

static NSString *const kCellIdentifier = @"IconPickerCell";

#pragma mark - Cell

@interface IconPickerCell : UICollectionViewCell
@property(nonatomic) UIImageView *iconView;
@property(nonatomic) UILabel *nameLabel;
@end

@implementation IconPickerCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    setViewPointerInteraction(self, YES);
    self.contentView.layer.cornerRadius = 14;
    self.contentView.layer.borderColor = LauncherTheme.accent.CGColor;
    self.iconView = [UIImageView new];
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.nameLabel = [UILabel new];
    self.nameLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    self.nameLabel.textAlignment = NSTextAlignmentCenter;
    self.nameLabel.numberOfLines = 2;
    self.nameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:self.iconView];
    [self.contentView addSubview:self.nameLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
        [self.iconView.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [self.iconView.widthAnchor constraintEqualToConstant:64],
        [self.iconView.heightAnchor constraintEqualToConstant:64],
        [self.nameLabel.topAnchor constraintEqualToAnchor:self.iconView.bottomAnchor constant:6],
        [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:4],
        [self.nameLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-4],
    ]];
    [self updateSelectionAppearance];
    return self;
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    [self updateSelectionAppearance];
}

- (void)updateSelectionAppearance {
    self.contentView.backgroundColor = self.selected ? LauncherTheme.selectionBackground : UIColor.clearColor;
    self.contentView.layer.borderWidth = self.selected ? 3 : 0;
    self.nameLabel.textColor = self.selected ? UIColor.labelColor : UIColor.secondaryLabelColor;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    self.contentView.layer.borderColor = LauncherTheme.accent.CGColor; // CGColor does not follow dark/light by itself
}

@end

#pragma mark - Picker

@interface LauncherIconPickerViewController () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout,
    UICollectionViewDropDelegate, UISearchBarDelegate, UIDocumentPickerDelegate>
@property(nonatomic, copy) NSString *selectedKey;
@property(nonatomic) NSArray<NSDictionary *> *entries;      // every icon: key, builtIn, modpack
@property(nonatomic) NSArray<NSDictionary *> *visible;      // after the category and search filters
@property(nonatomic) NSArray<NSNumber *> *segmentCategories; // IconCategory for each segment
@property(nonatomic) IconCategory category;
@property(nonatomic, copy) NSString *query;
@property(nonatomic) UISegmentedControl *categoryControl;
@property(nonatomic) UISearchBar *searchBar;
@property(nonatomic) UICollectionView *collectionView;
@property(nonatomic) UILabel *emptyLabel;
@property(nonatomic) UIToolbar *toolbar;
@property(nonatomic) UIBarButtonItem *okItem;
@property(nonatomic) UIBarButtonItem *removeItem;
@property(nonatomic) UIBarButtonItem *folderItem;
@property(nonatomic) UIBarButtonItem *countItem;
@end

@implementation LauncherIconPickerViewController

- (instancetype)initWithSelectedKey:(NSString *)selectedKey {
    self = [super initWithNibName:nil bundle:nil];
    self.selectedKey = selectedKey;
    self.category = IconCategoryAll;
    self.query = @"";
    return self;
}

#pragma mark View

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = localize(@"icon.picker.title", nil);
    self.view.backgroundColor = LauncherTheme.chromeBackground;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:localize(@"Cancel", nil)
        style:UIBarButtonItemStylePlain target:self action:@selector(actionCancel)];
    self.okItem = [[UIBarButtonItem alloc] initWithTitle:localize(@"OK", nil)
        style:UIBarButtonItemStyleDone target:self action:@selector(actionOK)];
    self.navigationItem.rightBarButtonItem = self.okItem;

    self.categoryControl = [[UISegmentedControl alloc] initWithItems:@[]];
    [self.categoryControl addTarget:self action:@selector(categoryChanged:) forControlEvents:UIControlEventValueChanged];
    self.categoryControl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.categoryControl setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    self.searchBar = [UISearchBar new];
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.placeholder = localize(@"icon.picker.search", nil);
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchBar.delegate = self;
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;

    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.itemSize = CGSizeMake(112, 112);
    layout.minimumInteritemSpacing = 6;
    layout.minimumLineSpacing = 6;
    layout.sectionInset = UIEdgeInsetsMake(8, 16, 8, 16);
    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collectionView.backgroundColor = UIColor.clearColor;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.dropDelegate = self;
    self.collectionView.allowsSelection = YES;
    self.collectionView.allowsMultipleSelection = NO;
    self.collectionView.alwaysBounceVertical = YES;
    self.collectionView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.collectionView registerClass:IconPickerCell.class forCellWithReuseIdentifier:kCellIdentifier];
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
    doubleTap.numberOfTapsRequired = 2;
    doubleTap.cancelsTouchesInView = NO;
    [self.collectionView addGestureRecognizer:doubleTap];

    self.emptyLabel = [UILabel new];
    self.emptyLabel.font = LauncherTheme.bodyFont;
    self.emptyLabel.textColor = UIColor.secondaryLabelColor;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.hidden = YES;
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIBarButtonItem *addItem = [[UIBarButtonItem alloc] initWithTitle:localize(@"icon.picker.add", nil)
        style:UIBarButtonItemStylePlain target:self action:@selector(actionAdd)];
    self.removeItem = [[UIBarButtonItem alloc] initWithTitle:localize(@"icon.picker.remove", nil)
        style:UIBarButtonItemStylePlain target:self action:@selector(actionRemove)];
    self.folderItem = [[UIBarButtonItem alloc] initWithTitle:localize(@"icon.picker.open_folder", nil)
        style:UIBarButtonItemStylePlain target:self action:@selector(actionFolderUnavailable)];
    self.countItem = [[UIBarButtonItem alloc] initWithTitle:@"" style:UIBarButtonItemStylePlain target:nil action:nil];
    self.countItem.enabled = NO;
    UIBarButtonItem *flexible = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    self.toolbar = [UIToolbar new];
    self.toolbar.items = @[addItem, self.removeItem, self.folderItem, flexible, self.countItem];
    self.toolbar.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *top = [UIView new];
    top.translatesAutoresizingMaskIntoConstraints = NO;
    [top addSubview:self.categoryControl];
    [top addSubview:self.searchBar];
    [self.view addSubview:top];
    [self.view addSubview:self.collectionView];
    [self.view addSubview:self.emptyLabel];
    [self.view addSubview:self.toolbar];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [top.topAnchor constraintEqualToAnchor:safe.topAnchor constant:6],
        [top.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [top.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [top.heightAnchor constraintEqualToConstant:44],
        [self.categoryControl.leadingAnchor constraintEqualToAnchor:top.leadingAnchor],
        [self.categoryControl.centerYAnchor constraintEqualToAnchor:top.centerYAnchor],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:self.categoryControl.trailingAnchor constant:12],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:top.trailingAnchor],
        [self.searchBar.centerYAnchor constraintEqualToAnchor:top.centerYAnchor],
        [self.collectionView.topAnchor constraintEqualToAnchor:top.bottomAnchor constant:4],
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.toolbar.topAnchor],
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.collectionView.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.collectionView.centerYAnchor],
        [self.emptyLabel.widthAnchor constraintLessThanOrEqualToAnchor:self.collectionView.widthAnchor constant:-64],
        [self.toolbar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.toolbar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.toolbar.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
    ]];
    [self updateFolderMenu];
    [self reloadEntries];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self scrollToSelectedAnimated:NO];
}

#pragma mark Data

/// Re-reads the icon folders and rebuilds the category control, then re-applies the filters.
- (void)reloadEntries {
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray new];
    for (NSString *key in InstanceIcons.builtInKeys) {
        [entries addObject:@{@"key": key, @"builtIn": @YES, @"modpack": @NO}];
    }
    BOOL anyModpack = NO;
    for (NSString *key in InstanceIcons.customKeys) {
        BOOL modpack = [InstanceIcons isModpackKey:key];
        anyModpack |= modpack;
        [entries addObject:@{@"key": key, @"builtIn": @NO, @"modpack": @(modpack)}];
    }
    // One list sorted by name, like Prism's
    self.entries = [entries sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"key"] localizedStandardCompare:b[@"key"]];
    }];

    // The Modpacks category only appears once there is something in it
    NSMutableArray<NSNumber *> *categories = [@[@(IconCategoryAll), @(IconCategoryModern)] mutableCopy];
    NSMutableArray<NSString *> *titles = [@[localize(@"icon.picker.category.all", nil), localize(@"icon.picker.category.modern", nil)] mutableCopy];
    if (anyModpack) {
        [categories addObject:@(IconCategoryModpacks)];
        [titles addObject:localize(@"icon.picker.category.modpacks", nil)];
    }
    [categories addObject:@(IconCategoryCustom)];
    [titles addObject:localize(@"icon.picker.category.custom", nil)];
    if (![categories containsObject:@(self.category)]) self.category = IconCategoryAll;
    self.segmentCategories = categories;
    [self.categoryControl removeAllSegments];
    for (NSUInteger i = 0; i < titles.count; i++) {
        [self.categoryControl insertSegmentWithTitle:titles[i] atIndex:i animated:NO];
    }
    self.categoryControl.selectedSegmentIndex = [categories indexOfObject:@(self.category)];
    [self applyFilters];
}

- (BOOL)entryMatches:(NSDictionary *)entry {
    BOOL builtIn = [entry[@"builtIn"] boolValue], modpack = [entry[@"modpack"] boolValue];
    switch (self.category) {
        case IconCategoryModern: if (!builtIn) return NO; break;
        case IconCategoryModpacks: if (!modpack) return NO; break;
        case IconCategoryCustom: if (builtIn || modpack) return NO; break;
        default: break;
    }
    if (self.query.length > 0 &&
        [entry[@"key"] rangeOfString:self.query options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location == NSNotFound) {
        return NO;
    }
    return YES;
}

- (void)applyFilters {
    NSMutableArray<NSDictionary *> *visible = [NSMutableArray new];
    for (NSDictionary *entry in self.entries) {
        if ([self entryMatches:entry]) [visible addObject:entry];
    }
    self.visible = visible;
    [self.collectionView reloadData];
    [self reselectCurrent];
    self.countItem.title = [NSString stringWithFormat:localize(@"icon.picker.count", nil), (int)visible.count];
    if (visible.count == 0) {
        BOOL searching = self.query.length > 0;
        self.emptyLabel.text = searching ? localize(@"icon.picker.empty_search", nil)
            : (self.category == IconCategoryCustom ? localize(@"icon.picker.empty_custom", nil) : @"");
    }
    self.emptyLabel.hidden = visible.count > 0;
    [self updateButtons];
}

- (NSIndexPath *)indexPathForKey:(NSString *)key {
    if (key.length == 0) return nil;
    for (NSUInteger i = 0; i < self.visible.count; i++) {
        if ([self.visible[i][@"key"] isEqualToString:key]) return [NSIndexPath indexPathForItem:i inSection:0];
    }
    return nil;
}

- (void)reselectCurrent {
    NSIndexPath *path = [self indexPathForKey:self.selectedKey];
    if (path) {
        [self.collectionView selectItemAtIndexPath:path animated:NO scrollPosition:UICollectionViewScrollPositionNone];
    }
}

- (void)scrollToSelectedAnimated:(BOOL)animated {
    NSIndexPath *path = [self indexPathForKey:self.selectedKey];
    if (path) {
        [self.collectionView scrollToItemAtIndexPath:path atScrollPosition:UICollectionViewScrollPositionCenteredVertically animated:animated];
    }
}

- (void)updateButtons {
    self.okItem.enabled = self.selectedKey.length > 0;
    // Only icons the user added can be removed, as in Prism
    self.removeItem.enabled = self.selectedKey.length > 0 && ![InstanceIcons isBuiltInKey:self.selectedKey]
        && [InstanceIcons.customKeys containsObject:self.selectedKey];
}

#pragma mark Collection view

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.visible.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    IconPickerCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:kCellIdentifier forIndexPath:indexPath];
    NSString *key = self.visible[indexPath.item][@"key"];
    cell.iconView.image = [InstanceIcons imageForKey:key];
    cell.nameLabel.text = key;
    cell.isAccessibilityElement = YES;
    cell.accessibilityLabel = key;
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    self.selectedKey = self.visible[indexPath.item][@"key"];
    [self updateButtons];
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)gesture {
    NSIndexPath *path = [self.collectionView indexPathForItemAtPoint:[gesture locationInView:self.collectionView]];
    if (!path) return;
    self.selectedKey = self.visible[path.item][@"key"];
    [self actionOK];
}

#pragma mark Filters

- (void)categoryChanged:(UISegmentedControl *)sender {
    if (sender.selectedSegmentIndex < 0 || sender.selectedSegmentIndex >= (NSInteger)self.segmentCategories.count) return;
    self.category = (IconCategory)self.segmentCategories[sender.selectedSegmentIndex].integerValue;
    [self applyFilters];
    [self scrollToSelectedAnimated:NO];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    self.query = [searchText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    [self applyFilters];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

#pragma mark Actions

- (void)actionCancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)actionOK {
    NSString *key = self.selectedKey;
    if (key.length == 0) return;
    void (^completion)(NSString *) = self.completion;
    [self dismissViewControllerAnimated:YES completion:^{
        if (completion) completion(key);
    }];
}

- (void)actionAdd {
    // Several images at once, as Prism allows. The system picker copies them into the app's temporary folder.
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[@"public.image"] inMode:UIDocumentPickerModeImport];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSMutableArray<NSString *> *added = [NSMutableArray new];
    NSMutableArray<NSString *> *failures = [NSMutableArray new];
    for (NSURL *url in urls) {
        NSError *error;
        NSString *key = [InstanceIcons importImageAtURL:url error:&error];
        if (key) [added addObject:key];
        else [failures addObject:[NSString stringWithFormat:@"%@: %@", url.lastPathComponent, error.localizedDescription ?: @"?"]];
        [NSFileManager.defaultManager removeItemAtURL:url error:nil]; // the copy the picker made
    }
    [self finishAddingKeys:added failures:failures];
}

/// Shows the newly added icons: selects the first one (like Prism) and makes sure a filter doesn't hide it.
- (void)finishAddingKeys:(NSArray<NSString *> *)added failures:(NSArray<NSString *> *)failures {
    if (added.count > 0) {
        self.selectedKey = added.firstObject;
        self.category = IconCategoryAll; // so no filter can hide what was just added
        self.query = @"";
        self.searchBar.text = @"";
    }
    [self reloadEntries];
    [self scrollToSelectedAnimated:YES];
    if (failures.count > 0) {
        showDialog(localize(@"Error", nil), [NSString stringWithFormat:localize(@"icon.picker.import.failed", nil),
            [failures componentsJoinedByString:@"\n"]]);
    }
}

- (void)actionRemove {
    NSString *key = self.selectedKey;
    if (key.length == 0 || [InstanceIcons isBuiltInKey:key]) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"icon.picker.remove", nil)
        message:[NSString stringWithFormat:localize(@"icon.picker.remove.confirm", nil), key]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"icon.picker.remove", nil) style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *action) {
        if ([InstanceIcons removeCustomKey:key]) {
            self.selectedKey = nil;
            [self reloadEntries];
            // Instances that used it show the default icon now: tell the lists and the dashboard to reload
            [NSNotificationCenter.defaultCenter postNotificationName:PLProfilesDidChangeNotification object:self];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark Open Folder (same file-manager apps as the instance dashboard)

- (void)updateFolderMenu {
    NSDictionary *apps = @{@"shareddocuments": @"Files", @"filza": @"Filza", @"santander": @"Santander"};
    NSMutableArray<UIAction *> *actions = [NSMutableArray new];
    __weak typeof(self) weakSelf = self;
    for (NSString *scheme in [apps.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if (![UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:[scheme stringByAppendingString:@"://"]]]) continue;
        [actions addObject:[UIAction actionWithTitle:apps[scheme] image:nil identifier:nil handler:^(UIAction *action) {
            [weakSelf openIconsFolderInScheme:scheme];
        }]];
    }
    if (actions.count > 0) {
        // A bar button item that has both a menu and a tap action runs the action on tap and shows the menu only on
        // long press. Without the action, a tap shows the menu.
        self.folderItem.menu = [UIMenu menuWithTitle:@"" children:actions];
        self.folderItem.target = nil;
        self.folderItem.action = NULL;
    } else {
        self.folderItem.menu = nil;
        self.folderItem.target = self;
        self.folderItem.action = @selector(actionFolderUnavailable);
    }
}

- (void)actionFolderUnavailable {
    // Only reachable when no supported file manager app is installed (otherwise the button shows a menu)
    showDialog(localize(@"Error", nil), localize(@"instance.folder.no_app", nil));
}

- (void)openIconsFolderInScheme:(NSString *)scheme {
    NSString *path = InstanceIcons.customIconsDirectory;
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@", scheme, path]];
    if (!url) {
        NSString *escaped = [path stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
        url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@", scheme, escaped]];
    }
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

#pragma mark Dropping images onto the grid (Files, Photos, Safari, ...)

- (BOOL)collectionView:(UICollectionView *)collectionView canHandleDropSession:(id<UIDropSession>)session {
    return [session canLoadObjectsOfClass:UIImage.class];
}

- (UICollectionViewDropProposal *)collectionView:(UICollectionView *)collectionView dropSessionDidUpdate:(id<UIDropSession>)session
    withDestinationIndexPath:(NSIndexPath *)destinationIndexPath {
    return [[UICollectionViewDropProposal alloc] initWithDropOperation:UIDropOperationCopy
        intent:UICollectionViewDropIntentUnspecified];
}

- (void)collectionView:(UICollectionView *)collectionView performDropWithCoordinator:(id<UICollectionViewDropCoordinator>)coordinator {
    NSArray<UIDragItem *> *items = coordinator.session.items;
    dispatch_group_t group = dispatch_group_create();
    NSMutableArray<NSString *> *added = [NSMutableArray new];
    NSMutableArray<NSString *> *failures = [NSMutableArray new];
    for (UIDragItem *item in items) {
        NSItemProvider *provider = item.itemProvider;
        NSString *name = provider.suggestedName ?: @"icon";
        dispatch_group_enter(group);
        // Called exactly once per dropped item, from any thread
        void (^finish)(NSString *, NSError *) = ^(NSString *key, NSError *error) {
            @synchronized (added) {
                if (key) [added addObject:key];
                else [failures addObject:[NSString stringWithFormat:@"%@: %@", name, error.localizedDescription ?: @"?"]];
            }
            dispatch_group_leave(group);
        };
        if (![provider hasItemConformingToTypeIdentifier:@"public.image"]) {
            finish(nil, [NSError errorWithDomain:@"InstanceIcons" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Not an image."}]);
            continue;
        }
        [provider loadFileRepresentationForTypeIdentifier:@"public.image" completionHandler:^(NSURL *url, NSError *error) {
            if (url) {
                // The file only exists until this handler returns, so it is imported right here
                NSError *importError;
                NSString *key = [InstanceIcons importImageAtURL:url suggestedName:name error:&importError];
                finish(key, importError);
                return;
            }
            // No file: take the encoded bytes. They are decoded with the same size bound; a decoded UIImage
            // is never requested, because building one can need far more memory than the icon is worth.
            [provider loadDataRepresentationForTypeIdentifier:@"public.image" completionHandler:^(NSData *data, NSError *dataError) {
                NSError *importError;
                NSString *key = data ? [InstanceIcons importImageData:data suggestedName:name error:&importError] : nil;
                finish(key, importError ?: dataError ?: error);
            }];
        }];
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        [self finishAddingKeys:added failures:failures];
    });
}

@end
