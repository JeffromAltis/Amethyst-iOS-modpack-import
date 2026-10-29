#import "UIKit+AFNetworking.h"
#import "ModBrowserViewController.h"
#import "ModCatalog.h"
#import "ModsManagerViewController.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

@interface ModsManagerViewController()
@property(nonatomic) ModCatalog *catalog;
@property(nonatomic) NSArray<InstalledMod *> *mods;
@property(nonatomic) BOOL busy, resolved;
@end

@implementation ModsManagerViewController

- (instancetype)initWithVersionId:(NSString *)versionId gameDirPath:(NSString *)gameDirPath {
    self = [super initWithStyle:UITableViewStylePlain];
    self.catalog = [[ModCatalog alloc] initWithVersionId:versionId gameDirPath:gameDirPath];
    self.mods = @[];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = localize(@"mods.manager.title", nil);
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];
    [self updateBarItems];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Also after coming back from the browser, which may have installed or updated mods
    [self refresh];
}

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (NSUInteger)updateCount {
    NSUInteger count = 0;
    for (InstalledMod *mod in self.mods) if (mod.update) count++;
    return count;
}

- (void)updateBarItems {
    NSMutableArray *items = [NSMutableArray arrayWithObject:
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(actionBrowse)]];
    [items.firstObject setEnabled:!self.busy];
    if ([self updateCount] > 0 && !self.busy) {
        UIBarButtonItem *all = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"]
            style:UIBarButtonItemStylePlain target:self action:@selector(actionUpdateAll)];
        all.accessibilityLabel = localize(@"mods.manager.update_all", nil);
        [items addObject:all];
    }
    if (self.busy) {
        UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [indicator startAnimating];
        [items addObject:[[UIBarButtonItem alloc] initWithCustomView:indicator]];
    }
    self.navigationItem.rightBarButtonItems = items;
    self.navigationController.modalInPresentation = self.busy;

    UILabel *footer = [UILabel new];
    footer.font = [UIFont systemFontOfSize:13];
    footer.textColor = UIColor.secondaryLabelColor;
    footer.textAlignment = NSTextAlignmentCenter;
    footer.numberOfLines = 0;
    footer.text = self.mods.count == 0 && !self.busy ? localize(@"mods.manager.empty", nil)
        : [NSString stringWithFormat:localize(@"mods.manager.count", nil), (unsigned long)self.mods.count, (unsigned long)[self updateCount]];
    footer.frame = CGRectMake(0, 0, 100, 60);
    self.tableView.tableFooterView = footer;
}

- (void)setBusy:(BOOL)busy {
    _busy = busy;
    self.tableView.userInteractionEnabled = !busy;
    self.navigationItem.leftBarButtonItem.enabled = !busy;
    [self updateBarItems];
}

/// Shows the jars right away, then fills in names, icons and updates once the sites have answered
- (void)refresh {
    self.mods = [self.catalog scanLocal];
    [self.tableView reloadData];
    self.busy = YES;
    [self.catalog perform:^{
        [self.catalog refreshInstalled];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.mods = self.catalog.installed;
            self.busy = NO;
            [self.tableView reloadData];
        });
    }];
}

- (void)actionBrowse {
    if (self.busy) return;
    [self.navigationController pushViewController:[[ModBrowserViewController alloc] initWithCatalog:self.catalog] animated:YES];
}

#pragma mark - Updating

- (void)updateMods:(NSArray<InstalledMod *> *)mods {
    self.busy = YES;
    self.tableView.userInteractionEnabled = NO;
    [self.catalog perform:^{
        NSMutableArray *installed = [NSMutableArray new], *problems = [NSMutableArray new];
        for (InstalledMod *mod in mods) {
            [self.catalog installFile:mod.update source:mod.source replacing:mod installed:installed problems:problems];
        }
        [self.catalog refreshInstalled];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.mods = self.catalog.installed;
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

- (void)actionUpdateAll {
    NSMutableArray *withUpdates = [NSMutableArray new];
    for (InstalledMod *mod in self.mods) if (mod.update) [withUpdates addObject:mod];
    [self updateMods:withUpdates];
}

#pragma mark - Row actions

- (void)toggleSwitch:(UISwitch *)sender {
    if (self.busy) return;
    // The row is looked up now: the cell may have moved since it was configured (rows shift when one is deleted)
    UIView *view = sender;
    while (view && ![view isKindOfClass:UITableViewCell.class]) view = view.superview;
    NSIndexPath *indexPath = view ? [self.tableView indexPathForCell:(UITableViewCell *)view] : nil;
    if (!indexPath || indexPath.row >= (NSInteger)self.mods.count) return;
    InstalledMod *mod = self.mods[indexPath.row];
    BOOL enabled = sender.on;
    self.busy = YES;
    [self.catalog perform:^{
        NSError *error;
        InstalledMod *updated = [self.catalog setMod:mod enabled:enabled error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            if (!updated) {
                sender.on = !enabled;
                showDialog(localize(@"Error", nil), error.localizedDescription);
                return;
            }
            // Swap in the changed copy by file name, wherever the row is by now
            NSMutableArray *list = self.mods.mutableCopy;
            for (NSUInteger i = 0; i < list.count; i++) {
                if ([[list[i] fileName] isEqualToString:updated.fileName]) list[i] = updated;
            }
            self.mods = list;
            [self.tableView reloadData];
        });
    }];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.busy || indexPath.row >= (NSInteger)self.mods.count) return nil;
    InstalledMod *mod = self.mods[indexPath.row];
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:localize(@"Delete", nil) handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
        if (self.busy) { done(NO); return; }
        self.busy = YES;
        [self.catalog perform:^{
            NSError *error;
            BOOL ok = [self.catalog deleteMod:mod error:&error];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.busy = NO;
                if (ok) {
                    NSMutableArray *rest = self.mods.mutableCopy;
                    NSIndexSet *matches = [rest indexesOfObjectsPassingTest:^BOOL(InstalledMod *item, NSUInteger idx, BOOL *stop) {
                        return [item.fileName isEqualToString:mod.fileName];
                    }];
                    [rest removeObjectsAtIndexes:matches];
                    self.mods = rest;
                    [self.tableView reloadData];
                    [self updateBarItems];
                } else {
                    showDialog(localize(@"Error", nil), error.localizedDescription);
                }
                done(ok);
            });
        }];
    }];
    NSMutableArray *actions = [NSMutableArray arrayWithObject:delete];
    if (mod.update) {
        UIContextualAction *update = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
            title:localize(@"mods.manager.update", nil) handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
            if (self.busy) { done(NO); return; }
            [self updateMods:@[mod]];
            done(YES);
        }];
        update.backgroundColor = UIColor.systemOrangeColor;
        [actions addObject:update];
    }
    return [UISwipeActionsConfiguration configurationWithActions:actions];
}

#pragma mark - UITableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.mods.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
        cell.imageView.contentMode = UIViewContentModeScaleAspectFill;
        cell.imageView.clipsToBounds = YES;
        cell.imageView.layer.cornerRadius = 6;
        cell.detailTextLabel.numberOfLines = 2;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    InstalledMod *mod = self.mods[indexPath.row];
    cell.textLabel.text = mod.title ?: mod.fileName;
    cell.textLabel.textColor = mod.enabled ? UIColor.labelColor : UIColor.secondaryLabelColor;
    NSMutableString *detail = [NSMutableString stringWithString:mod.fileName];
    if (mod.update) {
        [detail appendFormat:@"\n%@", [NSString stringWithFormat:localize(@"mods.manager.update_to", nil), mod.update.label]];
    }
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.textColor = mod.update ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor;

    UIImage *fallback = [UIImage imageNamed:@"DefaultProfile"];
    cell.imageView.image = fallback;
    if (mod.iconURL) [cell.imageView setImageWithURL:[NSURL URLWithString:mod.iconURL] placeholderImage:fallback];

    UISwitch *toggle = [UISwitch new];
    toggle.on = mod.enabled;
    [toggle addTarget:self action:@selector(toggleSwitch:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

@end
