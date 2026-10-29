#import "UIKit+AFNetworking.h"
#import "ModBrowserViewController.h"
#import "ModCatalog.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

@interface ModBrowserViewController()
@property(nonatomic) ModCatalog *catalog;
@property(nonatomic) UISegmentedControl *sourceControl;
@property(nonatomic) UISearchController *searchController;
@property(nonatomic) NSMutableArray<NSDictionary *> *list;
@property(nonatomic) BOOL reachedLastPage, busy, installedMarksRequested;
@property(nonatomic) NSUInteger generation; // bumped on every new search so stale pages are dropped
@property(nonatomic, copy) NSString *query;
@property(nonatomic) ModSort sort;
@property(nonatomic) id category; // Modrinth category name or CurseForge category id, nil for all
@property(nonatomic, copy) NSString *categoryTitle;
@end

@implementation ModBrowserViewController

static NSString *StringFromID(id value) {
    return [value isKindOfClass:NSString.class] ? value : [value stringValue];
}

- (instancetype)initWithCatalog:(ModCatalog *)catalog {
    self = [super initWithStyle:UITableViewStylePlain];
    self.catalog = catalog;
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
        self.catalog.mcVersion ?: @"?", self.catalog.loader ?: localize(@"mods.browser.any_loader", nil)];
    footer.frame = CGRectMake(0, 0, 100, 44);
    self.tableView.tableFooterView = footer;

    [self updateBarItems];
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData]; // installed markers may have changed
}

- (ModSource)source {
    return self.sourceControl.selectedSegmentIndex;
}

- (void)setBusy:(BOOL)busy {
    _busy = busy;
    self.navigationController.modalInPresentation = busy;
    [self updateBarItems];
}

#pragma mark - Filters

- (void)updateBarItems {
    NSMutableArray<UIAction *> *sorts = [NSMutableArray new];
    for (ModSort sort = ModSortRelevance; sort <= ModSortNewest; sort++) {
        UIAction *action = [UIAction actionWithTitle:[ModCatalog titleForSort:sort] image:nil identifier:nil handler:^(UIAction *a) {
            self.sort = sort;
            [self updateBarItems];
            [self reload];
        }];
        action.state = self.sort == sort ? UIMenuElementStateOn : UIMenuElementStateOff;
        [sorts addObject:action];
    }
    UIMenu *sortMenu = [UIMenu menuWithTitle:localize(@"mods.browser.sort", nil) image:[UIImage systemImageNamed:@"arrow.up.arrow.down"]
        identifier:nil options:UIMenuOptionsDisplayInline children:sorts];

    // Categories load lazily, so the submenu fills in when the user opens it
    void (^categoryProvider)(void (^)(NSArray<UIMenuElement *> *)) = ^(void (^completion)(NSArray<UIMenuElement *> *)) {
        ModSource source = [self source];
        [self.catalog perform:^{
            NSArray *all = [self.catalog categoriesForSource:source];
            dispatch_async(dispatch_get_main_queue(), ^{
                NSMutableArray *items = [NSMutableArray new];
                UIAction *allAction = [UIAction actionWithTitle:localize(@"mods.browser.all_categories", nil) image:nil identifier:nil handler:^(UIAction *a) {
                    [self selectCategory:nil title:nil];
                }];
                allAction.state = self.category ? UIMenuElementStateOff : UIMenuElementStateOn;
                [items addObject:allAction];
                for (NSDictionary *category in all) {
                    UIAction *action = [UIAction actionWithTitle:category[@"title"] image:nil identifier:nil handler:^(UIAction *a) {
                        [self selectCategory:category[@"id"] title:category[@"title"]];
                    }];
                    action.state = [self.category isEqual:category[@"id"]] ? UIMenuElementStateOn : UIMenuElementStateOff;
                    [items addObject:action];
                }
                completion(items);
            });
        }];
    };
    UIDeferredMenuElement *categories;
    if (@available(iOS 15.0, *)) {
        categories = [UIDeferredMenuElement elementWithUncachedProvider:categoryProvider];
    } else {
        categories = [UIDeferredMenuElement elementWithProvider:categoryProvider];
    }
    UIMenu *categoryMenu = [UIMenu menuWithTitle:self.categoryTitle ?: localize(@"mods.browser.category", nil)
        image:[UIImage systemImageNamed:@"square.grid.2x2"] identifier:nil options:0 children:@[categories]];

    UIBarButtonItem *filter = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"]
        menu:[UIMenu menuWithChildren:@[sortMenu, categoryMenu]]];
    NSMutableArray *items = [NSMutableArray arrayWithObject:filter];
    if (self.busy) {
        UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [indicator startAnimating];
        [items addObject:[[UIBarButtonItem alloc] initWithCustomView:indicator]];
    }
    self.navigationItem.rightBarButtonItems = items;
}

- (void)selectCategory:(id)category title:(NSString *)title {
    self.category = category;
    self.categoryTitle = title;
    [self updateBarItems];
    [self reload];
}

#pragma mark - Search

- (void)sourceChanged {
    // Category ids differ between the sites
    self.category = nil;
    self.categoryTitle = nil;
    [self updateBarItems];
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
    ModSource source = [self source];
    NSUInteger offset = self.list.count;
    NSString *query = [self.query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    ModSort sort = self.sort;
    id category = self.category;
    self.busy = YES;
    [self.catalog perform:^{
        BOOL last = NO;
        NSArray *page = [self.catalog searchSource:source query:query offset:offset sort:sort category:category last:&last];
        NSError *error = self.catalog.lastError;
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
            [self loadInstalledMarksIfNeeded];
        });
    }];
}

/// The "Installed" badges need the jars recognized, which can take a while. That happens after the results are
/// on screen, once per browser, and only when the manager hasn't done it already.
- (void)loadInstalledMarksIfNeeded {
    if (self.installedMarksRequested || self.catalog.installed.count > 0) return;
    self.installedMarksRequested = YES;
    [self.catalog perform:^{
        [self.catalog refreshInstalled];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.tableView reloadData];
        });
    }];
}

#pragma mark - Versions and installing

- (void)pickVersionForRow:(NSIndexPath *)indexPath {
    NSDictionary *item = self.list[indexPath.row];
    NSUInteger generation = self.generation;
    ModSource source = [self source];
    self.tableView.userInteractionEnabled = NO;
    self.busy = YES;
    [self.catalog perform:^{
        NSArray<ModFile *> *files = [self.catalog filesForProject:StringFromID(item[@"id"]) source:source];
        NSError *error = self.catalog.lastError;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.tableView.userInteractionEnabled = YES;
            if (generation != self.generation) return;
            self.busy = NO;
            if (!files) {
                showDialog(localize(@"Error", nil), error.localizedDescription);
            } else if (files.count == 0) {
                showDialog(localize(@"Error", nil), [NSString stringWithFormat:localize(@"mods.browser.no_versions", nil),
                    self.catalog.mcVersion ?: @"?", self.catalog.loader ?: @"-"]);
            } else {
                [self presentVersions:files title:item[@"title"] projectId:StringFromID(item[@"id"]) source:source indexPath:indexPath];
            }
        });
    }];
}

- (void)presentVersions:(NSArray<ModFile *> *)files title:(NSString *)title projectId:(NSString *)projectId source:(ModSource)source indexPath:(NSIndexPath *)indexPath {
    InstalledMod *installed = [self.catalog installedModForProject:projectId source:source];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
        message:localize(installed ? @"mods.browser.pick_version.replace" : @"mods.browser.pick_version", nil)
        preferredStyle:UIAlertControllerStyleActionSheet];
    for (ModFile *file in files) {
        BOOL isInstalled = [file.versionId isEqualToString:installed.versionId];
        // Newest first; mark pre-releases so a stable one is easy to pick
        NSString *label = [file.releaseType isEqualToString:@"release"] ? file.label : [NSString stringWithFormat:@"%@ [%@]", file.label, file.releaseType];
        if (isInstalled) label = [@"✓ " stringByAppendingString:label];
        UIAlertAction *action = [UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self install:file source:source replacing:isInstalled ? nil : installed];
        }];
        action.enabled = !isInstalled;
        [sheet addAction:action];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    UIView *cell = [self.tableView cellForRowAtIndexPath:indexPath] ?: self.view;
    sheet.popoverPresentationController.sourceView = cell;
    sheet.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)install:(ModFile *)file source:(ModSource)source replacing:(InstalledMod *)old {
    self.tableView.userInteractionEnabled = NO;
    self.busy = YES;
    [self.catalog perform:^{
        NSMutableArray *installed = [NSMutableArray new], *problems = [NSMutableArray new];
        [self.catalog installFile:file source:source replacing:old installed:installed problems:problems];
        [self.catalog refreshInstalled];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.tableView.userInteractionEnabled = YES;
            [self.tableView reloadData];
            NSMutableArray *lines = [NSMutableArray new];
            if (installed.count) [lines addObject:[NSString stringWithFormat:localize(@"mods.browser.installed", nil), [installed componentsJoinedByString:@"\n"]]];
            if (problems.count) [lines addObject:[problems componentsJoinedByString:@"\n"]];
            showDialog(localize(problems.count && !installed.count ? @"Error" : @"mods.browser.done", nil), [lines componentsJoinedByString:@"\n\n"]);
        });
    }];
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

    InstalledMod *installed = [self.catalog installedModForProject:StringFromID(item[@"id"]) source:[self source]];
    if (installed) {
        UILabel *badge = [UILabel new];
        badge.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        badge.text = localize(installed.update ? @"mods.browser.update_available" : @"mods.browser.installed_badge", nil);
        badge.textColor = installed.update ? UIColor.systemOrangeColor : UIColor.systemGreenColor;
        [badge sizeToFit];
        cell.accessoryView = badge;
    } else {
        cell.accessoryView = nil;
    }
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
