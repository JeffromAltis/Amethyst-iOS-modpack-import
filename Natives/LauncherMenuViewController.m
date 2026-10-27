#import "authenticator/BaseAuthenticator.h"
#import "AccountListViewController.h"
#import "AFNetworking.h"
#import "ALTServerConnection.h"
#import "LauncherCreateInstanceViewController.h"
#import "LauncherInstanceDashboardViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherMenuViewController.h"
#import "LauncherNewsViewController.h"
#import "LauncherPreferences.h"
#import "LauncherTheme.h"
#import "LauncherPrefGameDirViewController.h"
#import "LauncherPreferencesViewController.h"
#import "LauncherProfilesViewController.h"
#import "PLProfiles.h"
#import "UIButton+AFNetworking.h"
#import "UIImageView+AFNetworking.h"
#import "UIKit+hook.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

#include <dlfcn.h>

@implementation LauncherMenuCustomItem

+ (LauncherMenuCustomItem *)title:(NSString *)title imageName:(NSString *)imageName action:(id)action {
    LauncherMenuCustomItem *item = [[LauncherMenuCustomItem alloc] init];
    item.title = title;
    item.imageName = imageName;
    item.action = action;
    return item;
}

+ (LauncherMenuCustomItem *)vcClass:(Class)class {
    id vc = [class new];
    LauncherMenuCustomItem *item = [[LauncherMenuCustomItem alloc] init];
    item.title = [vc title];
    item.imageName = [vc imageName];
    // View controllers are put into an array to keep its state
    item.vcArray = @[vc];
    return item;
}

@end

typedef NS_ENUM(NSInteger, LauncherMenuSection) {
    kMenuSectionNavigation,
    kMenuSectionInstances,
    kMenuSectionTools,
    kMenuSectionCount
};

@interface LauncherMenuViewController()
// Global app destinations: News, Profiles (instance list), Settings
@property(nonatomic) NSMutableArray<LauncherMenuCustomItem*> *navigationItems;
// Utilities that must not clutter the primary navigation
@property(nonatomic) NSMutableArray<LauncherMenuCustomItem*> *toolItems;
// Whichever navigation item is currently shown in the content area; nil while an instance dashboard is shown
@property(nonatomic, weak) LauncherMenuCustomItem *currentNavItem;
@property(nonatomic) UILabel *statusLabel;
@end

/// Rounded status pill used for the JIT state in the sidebar's bottom bar
@interface LauncherPillLabel : UILabel
@end

@implementation LauncherPillLabel
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    self.backgroundColor = LauncherTheme.pillBackground;
    self.layer.cornerRadius = 10;
    self.clipsToBounds = YES;
    self.font = [UIFont systemFontOfSize:15];
    self.textAlignment = NSTextAlignmentCenter;
    return self;
}
- (void)drawTextInRect:(CGRect)rect {
    [super drawTextInRect:UIEdgeInsetsInsetRect(rect, UIEdgeInsetsMake(6, 14, 6, 14))];
}
- (CGSize)intrinsicContentSize {
    CGSize size = [super intrinsicContentSize];
    return CGSizeMake(size.width + 28, MAX(size.height + 12, 34));
}
@end

@implementation LauncherMenuViewController

#define contentNavigationController ((LauncherNavigationController *)self.splitViewController.viewControllers[1])

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.isInitialVc = YES;
    
    UIImageView *titleView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"AppLogo"]];
    [titleView setContentMode:UIViewContentModeScaleAspectFit];
    self.navigationItem.titleView = titleView;
    [titleView sizeToFit];
    
    self.navigationItems = @[
        [LauncherMenuCustomItem vcClass:LauncherNewsViewController.class],
        [LauncherMenuCustomItem vcClass:LauncherPreferencesViewController.class],
    ].mutableCopy;

    // No separate "Profiles" page: the Instances section below is the profile list
    self.toolItems = [NSMutableArray new];
    [self.toolItems addObject:(id)[LauncherMenuCustomItem
        title:localize(@"launcher.menu.game_folders", nil)
        imageName:@"folder" action:^{
        [contentNavigationController pushViewController:[LauncherPrefGameDirViewController new] animated:YES];
    }]];
    if (realUIIdiom != UIUserInterfaceIdiomTV) {
        [self.toolItems addObject:(id)[LauncherMenuCustomItem
                                     title:localize(@"launcher.menu.custom_controls", nil)
                                     imageName:@"MenuCustomControls" action:^{
            [contentNavigationController performSelector:@selector(enterCustomControls)];
        }]];
    }
    [self.toolItems addObject:
     (id)[LauncherMenuCustomItem
          title:localize(@"launcher.menu.execute_jar", nil)
          imageName:@"MenuInstallJar" action:^{
        [contentNavigationController performSelector:@selector(enterModInstaller)];
    }]];
    
    // TODO: Finish log-uploading service integration
    [self.toolItems addObject:
     (id)[LauncherMenuCustomItem
          title:localize(@"login.menu.sendlogs", nil)
          imageName:@"square.and.arrow.up" action:^{
        NSString *latestlogPath = [NSString stringWithFormat:@"file://%s/latestlog.old.txt", getenv("AME_HOME")];
        NSLog(@"Path is %@", latestlogPath);
        UIActivityViewController *activityVC;
        if (realUIIdiom != UIUserInterfaceIdiomTV) {
            activityVC = [[UIActivityViewController alloc]
                          initWithActivityItems:@[[NSURL URLWithString:latestlogPath]]
                          applicationActivities:nil];
        } else {
            dlopen("/System/Library/PrivateFrameworks/SharingUI.framework/SharingUI", RTLD_GLOBAL);
            activityVC =
            [[NSClassFromString(@"SFAirDropSharingViewControllerTV") alloc]
             performSelector:@selector(initWithSharingItems:)
             withObject:@[[NSURL URLWithString:latestlogPath]]];
        }
        activityVC.popoverPresentationController.sourceView = titleView;
        activityVC.popoverPresentationController.sourceRect = titleView.bounds;
        [self presentViewController:activityVC animated:YES completion:nil];
    }]];
    
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    dateFormatter.dateFormat = @"MM-dd";
    NSString* date = [dateFormatter stringFromDate:NSDate.date];
    if([date isEqualToString:@"06-29"] || [date isEqualToString:@"06-30"] || [date isEqualToString:@"07-01"]) {
        [self.toolItems addObject:(id)[LauncherMenuCustomItem
                                     title:@"Technoblade never dies!"
                                     imageName:@"" action:^{
            openLink(self, [NSURL URLWithString:@"https://youtu.be/DPMluEVUqS0"]);
        }]];
    }
    
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    
    self.navigationController.toolbarHidden = NO;
    UIActivityIndicatorViewStyle indicatorStyle = UIActivityIndicatorViewStyleMedium;
    UIActivityIndicatorView *toolbarIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:indicatorStyle];
    [toolbarIndicator startAnimating];
    LauncherPillLabel *statusPill = [LauncherPillLabel new];
    statusPill.textColor = UIColor.labelColor;
    self.toolbarItems = @[
        [[UIBarButtonItem alloc] initWithCustomView:toolbarIndicator],
        [[UIBarButtonItem alloc] initWithCustomView:statusPill]
    ];
    // Sidebar column: gray chrome like the bottom bar
    self.tableView.backgroundColor = LauncherTheme.chromeBackground;
    if (!(_UISolariumEnabled && _UISolariumEnabled())) {
        // (iOS 26 glass bars are left alone)
        [LauncherTheme applyBarBackground:LauncherTheme.chromeBackground toNavigationController:self.navigationController];
    }
    
    // Setup the account button
    self.accountBtnItem = [self drawAccountButton];
    
    [self updateAccountInfo];

    // The split view controller starts with the selected instance's dashboard in the content area
    [self decorateContentViewController:contentNavigationController.viewControllers.firstObject];
    [self restoreHighlightedSelection];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(profilesDidChange:)
        name:PLProfilesDidChangeNotification object:nil];
    
    if (getEntitlementValue(@"get-task-allow")) {
        [self displayProgress:localize(@"login.jit.checking", nil)];
        if (isJITEnabled(false)) {
            [self displayProgress:localize(@"login.jit.enabled", nil)];
            [self displayProgress:nil];
        } else if (@available(iOS 17.0, *)) {
            // enabling JIT for 17.0+ is done when we actually launch the game
        } else {
            [self enableJITWithAltKit];
        }
    } else if (!NSProcessInfo.processInfo.macCatalystApp && !getenv("SIMULATOR_DEVICE_NAME")) {
        [self displayProgress:localize(@"login.jit.fail", nil)];
        [self displayProgress:nil];
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:localize(@"login.jit.fail.title", nil)
            message:localize(@"login.jit.fail.description_unsupported", nil)
            preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction* okAction = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:^(id action){
            exit(-1);
        }];
        [alert addAction:okAction];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self restoreHighlightedSelection];
}

- (UIBarButtonItem *)drawAccountButton {
    if (!self.accountBtnItem) {
        self.accountButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [self.accountButton addTarget:self action:@selector(selectAccount:) forControlEvents:UIControlEventPrimaryActionTriggered];
        self.accountButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;

        self.accountButton.titleEdgeInsets = UIEdgeInsetsMake(0, 4, 0, -4);
        self.accountButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
        self.accountButton.titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
        self.accountBtnItem = [[UIBarButtonItem alloc] initWithCustomView:self.accountButton];
    }

    [self updateAccountInfo];
    
    return self.accountBtnItem;
}

#pragma mark - Instances

/// Instances are the profiles of the current game directory; keep their order stable between reloads.
- (NSArray<NSString *> *)instanceNames {
    return [PLProfiles.current.profiles.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

- (void)profilesDidChange:(NSNotification *)notification {
    // Selection can change without the sidebar (new instance created, modpack imported, ...):
    // an open dashboard follows the selected instance
    UIViewController *content = contentNavigationController.viewControllers.firstObject;
    if (!self.currentNavItem && [content isKindOfClass:LauncherInstanceDashboardViewController.class]) {
        [(LauncherInstanceDashboardViewController *)content switchToProfileNamed:PLProfiles.current.selectedProfileName];
    }
    [self.tableView reloadData];
    [self restoreHighlightedSelection];
}

- (void)presentCreateInstanceWindow {
    LauncherCreateInstanceViewController *create = [LauncherCreateInstanceViewController new];
    create.onFinished = ^(NSString *selectedName) {
        // A new instance was made: take the user to its dashboard
        [self openDashboardForProfile:selectedName];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:create];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    nav.preferredContentSize = CGSizeMake(820, 640);
    // Present from the split view controller: the installers inside expect it as their presenter
    [(self.splitViewController ?: self) presentViewController:nav animated:YES completion:nil];
}

- (void)openDashboardForProfile:(NSString *)name {
    if (!PLProfiles.current.profiles[name]) return;

    [self stashCurrentNavItemState];
    self.currentNavItem = nil;
    if (![PLProfiles.current.selectedProfileName isEqualToString:name]) {
        PLProfiles.current.selectedProfileName = name;
    }

    LauncherInstanceDashboardViewController *dashboard = [[LauncherInstanceDashboardViewController alloc] initWithProfileName:name];
    [contentNavigationController setViewControllers:@[dashboard] animated:NO];
    [self decorateContentViewController:dashboard];
    // The launch bar and the sidebar follow the selected instance
    [NSNotificationCenter.defaultCenter postNotificationName:PLProfilesDidChangeNotification object:self];
}

- (void)showNavigationItem:(LauncherMenuCustomItem *)item {
    [self stashCurrentNavItemState];
    self.currentNavItem = item;
    [contentNavigationController setViewControllers:item.vcArray animated:NO];
    [self decorateContentViewController:item.vcArray[0]];
}

/// View controllers are put into an array to keep their state while another destination is shown
- (void)stashCurrentNavItemState {
    if (self.currentNavItem) {
        self.currentNavItem.vcArray = contentNavigationController.viewControllers;
    }
}

- (void)decorateContentViewController:(UIViewController *)vc {
    vc.navigationItem.rightBarButtonItem = self.accountBtnItem;
    vc.navigationItem.leftBarButtonItem = self.splitViewController.displayModeButtonItem;
    vc.navigationItem.leftItemsSupplementBackButton = true;
}

#pragma mark - Table view

- (NSIndexPath *)indexPathForCurrentContent {
    if (self.currentNavItem) {
        NSUInteger index = [self.navigationItems indexOfObject:self.currentNavItem];
        return index == NSNotFound ? nil : [NSIndexPath indexPathForRow:index inSection:kMenuSectionNavigation];
    }
    NSUInteger index = [[self instanceNames] indexOfObject:PLProfiles.current.selectedProfileName];
    return index == NSNotFound ? nil : [NSIndexPath indexPathForRow:index inSection:kMenuSectionInstances];
}

- (void)restoreHighlightedSelection {
    // Restore the selected row when the view appears again
    NSIndexPath *indexPath = [self indexPathForCurrentContent];
    if (indexPath) {
        [self.tableView selectRowAtIndexPath:indexPath animated:NO scrollPosition:UITableViewScrollPositionNone];
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return kMenuSectionCount;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case kMenuSectionNavigation: return localize(@"launcher.menu.section.navigation", nil).uppercaseString;
        case kMenuSectionInstances: return localize(@"launcher.menu.section.instances", nil).uppercaseString;
        case kMenuSectionTools: return localize(@"launcher.menu.section.advanced_tools", nil).uppercaseString;
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) {
        UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
        header.textLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        header.textLabel.textColor = UIColor.secondaryLabelColor;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case kMenuSectionNavigation: return self.navigationItems.count;
        case kMenuSectionInstances: return [self instanceNames].count + 1; // + "Create Instance..."
        case kMenuSectionTools: return self.toolItems.count;
    }
    return 0;
}

- (void)setIconNamed:(NSString *)imageName forCell:(UITableViewCell *)cell {
    UIImage *origImage = [UIImage systemImageNamed:imageName];
    if (origImage) {
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(40, 40)];
        UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext*_Nonnull myContext) {
            CGFloat scaleFactor = 40/origImage.size.height;
            [origImage drawInRect:CGRectMake(20 - origImage.size.width*scaleFactor/2, 0, origImage.size.width*scaleFactor, 40)];
        }];
        cell.imageView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    
    if (cell.imageView.image == nil) {
        cell.imageView.layer.magnificationFilter = kCAFilterNearest;
        cell.imageView.layer.minificationFilter = kCAFilterNearest;
        cell.imageView.image = [UIImage imageNamed:imageName];
        cell.imageView.image = [cell.imageView.image _imageWithSize:CGSizeMake(40, 40)];
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSArray<NSString *> *instances = [self instanceNames];
    BOOL isCreateRow = indexPath.section == kMenuSectionInstances && indexPath.row == (NSInteger)instances.count;
    // Separate identifiers per kind: instance icons load asynchronously and must not land on a reused cell of another kind
    NSString *reuseID = @[@"navCell", isCreateRow ? @"createCell" : @"instanceCell", @"toolCell"][indexPath.section];

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseID];
        if (indexPath.section == kMenuSectionInstances && !isCreateRow) {
            // Same setup the old profile list used so the icon is drawn at a fixed size
            cell.imageView.frame = CGRectMake(0, 0, 40, 40);
            cell.imageView.isSizeFixed = YES;
        }
    }
    cell.backgroundColor = UIColor.clearColor;
    if (!cell.selectedBackgroundView) {
        // Rounded, inset highlight like the concept
        UIView *container = [UIView new];
        UIView *highlight = [UIView new];
        highlight.backgroundColor = LauncherTheme.selectionBackground;
        highlight.layer.cornerRadius = 10;
        highlight.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:highlight];
        [NSLayoutConstraint activateConstraints:@[
            [highlight.topAnchor constraintEqualToAnchor:container.topAnchor constant:2],
            [highlight.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-2],
            [highlight.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
            [highlight.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
        ]];
        cell.selectedBackgroundView = container;
    }
    cell.imageView.image = nil;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.imageView.tintColor = nil;

    switch (indexPath.section) {
        case kMenuSectionNavigation: {
            LauncherMenuCustomItem *item = self.navigationItems[indexPath.row];
            cell.textLabel.text = item.title;
            [self setIconNamed:item.imageName forCell:cell];
            break;
        }
        case kMenuSectionInstances: {
            if (isCreateRow) {
                // Deliberately low contrast, it should not compete with the instances themselves
                cell.textLabel.text = localize(@"launcher.menu.create_instance", nil);
                cell.textLabel.textColor = UIColor.secondaryLabelColor;
                [self setIconNamed:@"plus" forCell:cell];
                cell.imageView.tintColor = UIColor.secondaryLabelColor;
            } else {
                NSDictionary *profile = PLProfiles.current.profiles[instances[indexPath.row]];
                cell.textLabel.text = instances[indexPath.row];
                cell.imageView.layer.magnificationFilter = kCAFilterNearest;
                cell.imageView.isSizeFixed = YES;
                UIImage *fallbackImage = [[UIImage imageNamed:@"DefaultProfile"] _imageWithSize:CGSizeMake(40, 40)];
                [cell.imageView setImageWithURL:[NSURL URLWithString:profile[@"icon"]] placeholderImage:fallbackImage];
            }
            break;
        }
        case kMenuSectionTools: {
            LauncherMenuCustomItem *item = self.toolItems[indexPath.row];
            cell.textLabel.text = item.title;
            [self setIconNamed:item.imageName forCell:cell];
            cell.textLabel.textColor = UIColor.secondaryLabelColor;
            cell.imageView.tintColor = UIColor.secondaryLabelColor;
            break;
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    switch (indexPath.section) {
        case kMenuSectionNavigation: {
            LauncherMenuCustomItem *selected = self.navigationItems[indexPath.row];
            if (selected == self.currentNavItem) return;
            [self showNavigationItem:selected];
            break;
        }
        case kMenuSectionInstances: {
            NSArray<NSString *> *instances = [self instanceNames];
            if (indexPath.row >= (NSInteger)instances.count) {
                [self restoreHighlightedSelection];
                [self presentCreateInstanceWindow];
                return;
            }
            [self openDashboardForProfile:instances[indexPath.row]];
            break;
        }
        case kMenuSectionTools: {
            LauncherMenuCustomItem *selected = self.toolItems[indexPath.row];
            [self restoreHighlightedSelection];
            if (selected.action) selected.action();
            break;
        }
    }
}

- (void)selectAccount:(UIButton *)sender {
    AccountListViewController *vc = [[AccountListViewController alloc] init];
    vc.whenDelete = ^void(NSString* name) {
        if ([name isEqualToString:getPrefObject(@"internal.selected_account")]) {
            BaseAuthenticator.current = nil;
            setPrefObject(@"internal.selected_account", @"");
            [self updateAccountInfo];
        }
    };
    vc.whenItemSelected = ^void() {
        setPrefObject(@"internal.selected_account", BaseAuthenticator.current.authData[@"username"]);
        [self updateAccountInfo];
        if (sender != self.accountButton) {
            // Called from the play button, so call back to continue
            [sender sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
        }
    };
    vc.modalPresentationStyle = UIModalPresentationPopover;
    vc.preferredContentSize = CGSizeMake(350, 250);

    UIPopoverPresentationController *popoverController = vc.popoverPresentationController;
    popoverController.sourceView = sender;
    popoverController.sourceRect = sender.bounds;
    popoverController.permittedArrowDirections = UIPopoverArrowDirectionAny;
    popoverController.delegate = vc;
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)updateAccountInfo {
    NSDictionary *selected = BaseAuthenticator.current.authData;
    CGSize size = CGSizeMake(contentNavigationController.view.frame.size.width, contentNavigationController.view.frame.size.height);
    
    if (selected == nil) {
        if((size.width / 3) > 200) {
            [self.accountButton setAttributedTitle:[[NSAttributedString alloc] initWithString:localize(@"login.option.select", nil)] forState:UIControlStateNormal];
        } else {
            [self.accountButton setAttributedTitle:(NSAttributedString *)@"" forState:UIControlStateNormal];
        }
        [self.accountButton setImage:[UIImage imageNamed:@"DefaultAccount"] forState:UIControlStateNormal];
        [self.accountButton sizeToFit];
        return;
    }

    // Remove the prefix "Demo." if there is
    BOOL isDemo = [selected[@"username"] hasPrefix:@"Demo."];
    NSMutableAttributedString *title = [[NSMutableAttributedString alloc] initWithString:[selected[@"username"] substringFromIndex:(isDemo?5:0)]];

    // Check if we're switching between demo and full mode
    BOOL shouldUpdateProfiles = (getenv("DEMO_LOCK")!=NULL) != isDemo;

    // Reset states
    unsetenv("DEMO_LOCK");
    setenv("GAME_DIR", [NSString stringWithFormat:@"%s/Library/Application Support/minecraft", getenv("AME_HOME")].UTF8String, 1);

    id subtitle;
    if (isDemo) {
        subtitle = localize(@"login.option.demo", nil);
        setenv("DEMO_LOCK", "1", 1);
        setenv("GAME_DIR", [NSString stringWithFormat:@"%s/.demo", getenv("AME_HOME")].UTF8String, 1);
    } else if (selected[@"xboxGamertag"] == nil) {
        subtitle = localize(@"login.option.local", nil);
    } else {
        // Display the Xbox gamertag for online accounts
        subtitle = selected[@"xboxGamertag"];
    }

    subtitle = [[NSAttributedString alloc] initWithString:subtitle attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12]}];
    [title appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:nil]];
    [title appendAttributedString:subtitle];
    
    if((size.width / 3) > 200) {
        [self.accountButton setAttributedTitle:title forState:UIControlStateNormal];
    } else {
        [self.accountButton setAttributedTitle:(NSAttributedString *)@"" forState:UIControlStateNormal];
    }
    
    // TODO: Add caching mechanism for profile pictures
    NSURL *url = [NSURL URLWithString:[selected[@"profilePicURL"] stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"]];
    UIImage *placeholder = [UIImage imageNamed:@"DefaultAccount"];
    [self.accountButton setImageForState:UIControlStateNormal withURL:url placeholderImage:placeholder];
    [self.accountButton.imageView setImageWithURL:url placeholderImage:placeholder];
    [self.accountButton sizeToFit];

    // Update profiles and local version list if needed
    if (shouldUpdateProfiles) {
        [contentNavigationController fetchLocalVersionList];
        [contentNavigationController performSelector:@selector(reloadProfileList)];
    }

    // Update tableView whenever we have
    UITableViewController *tableVC = contentNavigationController.viewControllers.lastObject;
    if ([tableVC isKindOfClass:UITableViewController.class]) {
        [tableVC.tableView reloadData];
    }
}

- (void)displayProgress:(NSString *)status {
    if (status == nil) {
        [(UIActivityIndicatorView *)self.toolbarItems[0].customView stopAnimating];
    } else {
        LauncherPillLabel *pill = (LauncherPillLabel *)self.toolbarItems[1].customView;
        pill.text = status;
        [pill sizeToFit];
    }
}

- (void)enableJITWithAltKit {
    [ALTServerManager.sharedManager startDiscovering];
    [ALTServerManager.sharedManager autoconnectWithCompletionHandler:^(ALTServerConnection *connection, NSError *error) {
        if (error) {
            NSLog(@"[AltKit] Could not auto-connect to server. %@", error.localizedRecoverySuggestion);
            [self displayProgress:localize(@"login.jit.fail", nil)];
            [self displayProgress:nil];
        }
        [connection enableUnsignedCodeExecutionWithCompletionHandler:^(BOOL success, NSError *error) {
            if (success) {
                NSLog(@"[AltKit] Successfully enabled JIT compilation!");
                [ALTServerManager.sharedManager stopDiscovering];
                [self displayProgress:localize(@"login.jit.enabled", nil)];
                [self displayProgress:nil];
            } else {
                NSLog(@"[AltKit] Error enabling JIT: %@", error.localizedRecoverySuggestion);
                [self displayProgress:localize(@"login.jit.fail", nil)];
                [self displayProgress:nil];
            }
            [connection disconnect];
        }];
    }];
}

@end
