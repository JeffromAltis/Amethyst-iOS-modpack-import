#import "InstanceIcons.h"
#import "LauncherHomeViewController.h"
#import "LauncherInstanceDashboardViewController.h"
#import "LauncherMenuViewController.h"
#import "LauncherNewsViewController.h"
#import "LauncherSettingsHubViewController.h"
#import "LauncherTheme.h"
#import "PLProfiles.h"
#import "UIKit+hook.h"
#import "utils.h"

NSNotificationName const LauncherJITStatusDidChangeNotification = @"LauncherJITStatusDidChangeNotification";

static const CGFloat kTileIcon = 112;

#pragma mark - Tile

@interface LauncherInstanceTileCell : UICollectionViewCell
@property(nonatomic) UIImageView *iconView;
@property(nonatomic) UILabel *nameLabel, *detailLabel;
@property(nonatomic) CAShapeLayer *dashLayer; // "New Instance" tile only
@end

@implementation LauncherInstanceTileCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    _iconView = [UIImageView new];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.layer.magnificationFilter = kCAFilterNearest; // pixel-art icons stay crisp
    _iconView.layer.cornerRadius = 24;
    _iconView.layer.cornerCurve = kCACornerCurveContinuous;
    _iconView.clipsToBounds = YES;

    _nameLabel = [UILabel new];
    _nameLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _nameLabel.textAlignment = NSTextAlignmentCenter;
    _nameLabel.numberOfLines = 2;
    _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    _detailLabel = [UILabel new];
    _detailLabel.font = LauncherTheme.subtitleFont;
    _detailLabel.textColor = UIColor.secondaryLabelColor;
    _detailLabel.textAlignment = NSTextAlignmentCenter;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_iconView, _nameLabel, _detailLabel]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 3;
    [stack setCustomSpacing:12 afterView:_iconView];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [_iconView.widthAnchor constraintEqualToConstant:kTileIcon],
        [_iconView.heightAnchor constraintEqualToConstant:kTileIcon],
        [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [stack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor],
        [_nameLabel.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [_detailLabel.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    ]];
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self.dashLayer removeFromSuperlayer];
    self.dashLayer = nil;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.tintColor = nil;
    self.nameLabel.textColor = UIColor.labelColor;
}

/// The selected instance (the one the launch bar plays) gets an accent ring around its icon
- (void)setCurrent:(BOOL)current {
    self.iconView.layer.borderWidth = current ? 3 : 0;
    self.iconView.layer.borderColor = LauncherTheme.accent.CGColor;
}

- (void)showAsNewInstanceTile {
    [self setCurrent:NO];
    self.iconView.image = [UIImage systemImageNamed:@"plus" withConfiguration:
        [UIImageSymbolConfiguration configurationWithPointSize:40 weight:UIImageSymbolWeightLight]];
    self.iconView.contentMode = UIViewContentModeCenter;
    self.iconView.tintColor = UIColor.secondaryLabelColor;
    self.nameLabel.text = localize(@"create.title", nil);
    self.nameLabel.textColor = UIColor.secondaryLabelColor;
    self.detailLabel.text = @" ";
    self.dashLayer = [CAShapeLayer layer];
    self.dashLayer.frame = CGRectMake(0, 0, kTileIcon, kTileIcon);
    self.dashLayer.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.dashLayer.frame, 1.5, 1.5) cornerRadius:23].CGPath;
    self.dashLayer.fillColor = UIColor.clearColor.CGColor;
    self.dashLayer.strokeColor = UIColor.tertiaryLabelColor.CGColor;
    self.dashLayer.lineWidth = 2;
    self.dashLayer.lineDashPattern = @[@8, @6];
    [self.iconView.layer addSublayer:self.dashLayer];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.contentView.alpha = highlighted ? 0.55 : 1;
}

@end

#pragma mark - Home

@interface LauncherHomeViewController () <UICollectionViewDataSource, UICollectionViewDelegate, UISearchBarDelegate>
@property(nonatomic) UICollectionView *collectionView;
@property(nonatomic) NSArray<NSString *> *names;
@property(nonatomic) NSString *filter;
@property(nonatomic) UIButton *jitButton;
@property(nonatomic) UISearchBar *searchBar;
@property(nonatomic) UIBarButtonItem *toolsItem;
@end

@implementation LauncherHomeViewController

+ (NSString *)versionSummaryForProfile:(NSDictionary *)profile {
    id raw = profile[@"lastVersionId"];
    if (![raw isKindOfClass:NSString.class] || [raw length] == 0) return @"";
    NSString *v = [raw lowercaseString];
    NSString *loader = nil;
    BOOL lastNumber = NO; // fabric-loader-0.16.5-1.21.1: the game version comes last
    if ([v containsString:@"neoforge"]) loader = @"NeoForge";
    else if ([v containsString:@"forge"] || [v containsString:@"lwjgl3ify"]) loader = @"Forge";
    else if ([v containsString:@"fabric"]) { loader = @"Fabric"; lastNumber = YES; }
    else if ([v containsString:@"quilt"]) { loader = @"Quilt"; lastNumber = YES; }
    else if ([v containsString:@"optifine"]) loader = @"OptiFine";

    if (!loader) {
        // A plain id ("1.21.4", "26.3", "24w14a") is vanilla; anything else is shown as it is
        BOOL plain = [v rangeOfString:@"^[0-9a-z.]+$" options:NSRegularExpressionSearch].location != NSNotFound;
        return plain ? [NSString stringWithFormat:@"%@ · Vanilla", raw] : raw;
    }
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\d+\\.\\d+(\\.\\d+)?" options:0 error:nil];
    NSArray<NSTextCheckingResult *> *matches = [re matchesInString:raw options:0 range:NSMakeRange(0, [raw length])];
    if (matches.count == 0) return loader;
    NSTextCheckingResult *m = lastNumber ? matches.lastObject : matches.firstObject;
    return [NSString stringWithFormat:@"%@ · %@", [raw substringWithRange:m.range], loader];
}

- (NSString *)title { return localize(@"launcher.menu.section.instances", nil); }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = LauncherTheme.contentBackground;

    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.itemSize = CGSizeMake(170, 196);
    layout.minimumInteritemSpacing = 24;
    layout.minimumLineSpacing = 28;
    layout.sectionInset = UIEdgeInsetsMake(28, 36, 32, 36);
    self.collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:layout];
    self.collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.collectionView.backgroundColor = UIColor.clearColor;
    self.collectionView.alwaysBounceVertical = YES;
    self.collectionView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    [self.collectionView registerClass:LauncherInstanceTileCell.class forCellWithReuseIdentifier:@"tile"];
    [self.view addSubview:self.collectionView];

    [self reloadInstances];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadInstances)
        name:PLProfilesDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateJITButton)
        name:LauncherJITStatusDidChangeNotification object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self setupBarItems];
    [self reloadInstances];
}

#pragma mark Toolbar

- (UIButton *)capsuleWithTitle:(NSString *)title symbol:(NSString *)symbol filled:(BOOL)filled action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    button.tintColor = filled ? UIColor.whiteColor : UIColor.labelColor;
    button.backgroundColor = filled ? LauncherTheme.accent : LauncherTheme.pillBackground;
    button.contentEdgeInsets = UIEdgeInsetsMake(8, 16, 8, 20);
    button.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, -8);
    [button addTarget:self action:action forControlEvents:UIControlEventPrimaryActionTriggered];
    [button sizeToFit];
    button.layer.cornerRadius = button.bounds.size.height / 2;
    return button;
}

- (void)setupBarItems {
    LauncherMenuViewController *menu = sidebarViewController;
    // The page title sits at the left of the bar, followed by the two create buttons (like the mockup)
    self.navigationItem.titleView = [UIView new];
    UILabel *titleLabel = [UILabel new];
    titleLabel.text = self.title;
    titleLabel.font = [UIFont systemFontOfSize:30 weight:UIFontWeightBold];
    [titleLabel sizeToFit];
    UIBarButtonItem *titleItem = [[UIBarButtonItem alloc] initWithCustomView:titleLabel];
    UIBarButtonItem *create = [[UIBarButtonItem alloc] initWithCustomView:
        [self capsuleWithTitle:localize(@"create.title", nil) symbol:@"plus" filled:YES action:@selector(actionCreate)]];
    UIBarButtonItem *import = [[UIBarButtonItem alloc] initWithCustomView:
        [self capsuleWithTitle:localize(@"home.import_modpack", nil) symbol:@"square.and.arrow.down" filled:NO action:@selector(actionImport)]];
    self.navigationItem.leftBarButtonItems = @[titleItem, create, import];

    if (!self.searchBar) {
        self.searchBar = [UISearchBar new];
        self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
        self.searchBar.placeholder = localize(@"home.search", nil);
        self.searchBar.delegate = self;
        self.searchBar.frame = CGRectMake(0, 0, 230, 36);
    }
    if (!self.jitButton) {
        self.jitButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.jitButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        self.jitButton.backgroundColor = LauncherTheme.pillBackground;
        self.jitButton.contentEdgeInsets = UIEdgeInsetsMake(7, 12, 7, 14);
        self.jitButton.titleEdgeInsets = UIEdgeInsetsMake(0, 6, 0, -6);
        [self.jitButton addTarget:self action:@selector(actionJIT) forControlEvents:UIControlEventPrimaryActionTriggered];
    }
    [self updateJITButton];

    UIBarButtonItem *settings = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape.fill"]
        style:UIBarButtonItemStylePlain target:self action:@selector(actionSettings)];
    UIBarButtonItem *news = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"newspaper"]
        style:UIBarButtonItemStylePlain target:self action:@selector(actionNews)];

    // Former "Advanced Tools" sidebar section: custom controls, execute .jar, send logs
    NSMutableArray<UIMenuElement *> *tools = [NSMutableArray new];
    for (LauncherMenuCustomItem *item in menu.toolItems) {
        UIImage *image = [UIImage imageNamed:item.imageName] ?: [UIImage systemImageNamed:item.imageName];
        void (^action)(void) = item.action;
        [tools addObject:[UIAction actionWithTitle:item.title image:image identifier:nil
            handler:^(UIAction *a) { if (action) action(); }]];
    }
    self.toolsItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
        style:UIBarButtonItemStylePlain target:nil action:nil];
    self.toolsItem.menu = [UIMenu menuWithChildren:tools];
    menu.popoverAnchorItem = self.toolsItem;

    // Right to left: gear, account, JIT, tools, news, search
    NSMutableArray *right = [NSMutableArray arrayWithObject:settings];
    UIBarButtonItem *account = [menu drawAccountButton];
    if (account) [right addObject:account];
    [right addObjectsFromArray:@[[[UIBarButtonItem alloc] initWithCustomView:self.jitButton], self.toolsItem, news,
        [[UIBarButtonItem alloc] initWithCustomView:self.searchBar]]];
    self.navigationItem.rightBarButtonItems = right;
}

- (void)updateJITButton {
    NSString *text = sidebarViewController.jitStatusText;
    self.jitButton.hidden = text.length == 0;
    BOOL on = [text isEqualToString:localize(@"launcher.jit.on", nil)];
    BOOL checking = [text isEqualToString:localize(@"launcher.jit.checking", nil)];
    UIColor *dot = on ? UIColor.systemGreenColor : (checking ? UIColor.systemYellowColor : UIColor.systemRedColor);
    [self.jitButton setImage:[[UIImage systemImageNamed:@"circle.fill" withConfiguration:
        [UIImageSymbolConfiguration configurationWithPointSize:9]] imageWithTintColor:dot renderingMode:UIImageRenderingModeAlwaysOriginal]
        forState:UIControlStateNormal];
    [self.jitButton setTitle:text forState:UIControlStateNormal];
    [self.jitButton setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
    [self.jitButton sizeToFit];
    self.jitButton.layer.cornerRadius = self.jitButton.bounds.size.height / 2;
}

- (void)actionJIT {
    NSString *text = sidebarViewController.jitStatusText;
    BOOL on = [text isEqualToString:localize(@"launcher.jit.on", nil)];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:text
        message:(on ? nil : localize(@"launcher.wait_jit.message", nil))
        preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleCancel handler:nil]];
    alert.popoverPresentationController.sourceView = self.jitButton;
    alert.popoverPresentationController.sourceRect = self.jitButton.bounds;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)actionCreate {
    [sidebarViewController presentCreateInstanceWindowOnImport:NO];
}

- (void)actionImport {
    [sidebarViewController presentCreateInstanceWindowOnImport:YES];
}

- (void)actionSettings {
    // Two panes when there is room, the category list alone otherwise
    BOOL wide = self.view.safeAreaLayoutGuide.layoutFrame.size.width >= 700;
    UIViewController *page = wide ? [LauncherSettingsPageViewController new] : [LauncherSettingsHubViewController new];
    [self.navigationController pushViewController:page animated:YES];
}

- (void)actionNews {
    [self.navigationController pushViewController:[LauncherNewsViewController new] animated:YES];
}

#pragma mark Search

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    self.filter = searchText;
    [self reloadInstances];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

#pragma mark Instances

- (void)reloadInstances {
    NSArray<NSString *> *all = [PLProfiles.current.profiles.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSString *filter = [self.filter stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (filter.length > 0) {
        all = [all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *name, id bindings) {
            NSString *version = [LauncherHomeViewController versionSummaryForProfile:PLProfiles.current.profiles[name]];
            return [name localizedCaseInsensitiveContainsString:filter] || [version localizedCaseInsensitiveContainsString:filter];
        }]];
    }
    self.names = all;
    [self.collectionView reloadData];
}

- (void)openInstanceNamed:(NSString *)name animated:(BOOL)animated {
    if (!PLProfiles.current.profiles[name]) return;
    if (![PLProfiles.current.selectedProfileName isEqualToString:name]) {
        PLProfiles.current.selectedProfileName = name;
        // The launch bar follows the selected instance
        [NSNotificationCenter.defaultCenter postNotificationName:PLProfilesDidChangeNotification object:self];
    }
    LauncherInstanceDashboardViewController *page = [[LauncherInstanceDashboardViewController alloc] initWithProfileName:name];
    [self.navigationController setViewControllers:@[self, page] animated:animated];
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    // The last tile is "New Instance" (not while searching)
    return self.names.count + (self.filter.length > 0 ? 0 : 1);
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    LauncherInstanceTileCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"tile" forIndexPath:indexPath];
    if (indexPath.item >= (NSInteger)self.names.count) {
        [cell showAsNewInstanceTile];
        return cell;
    }
    NSString *name = self.names[indexPath.item];
    NSDictionary *profile = PLProfiles.current.profiles[name];
    cell.nameLabel.text = name;
    cell.detailLabel.text = [LauncherHomeViewController versionSummaryForProfile:profile];
    id icon = profile[@"icon"];
    [InstanceIcons setIconString:([icon isKindOfClass:NSString.class] ? icon : nil)
        onImageView:cell.iconView placeholder:[UIImage imageNamed:@"DefaultProfile"]];
    [cell setCurrent:[name isEqualToString:PLProfiles.current.selectedProfileName]];
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:NO];
    if (indexPath.item >= (NSInteger)self.names.count) {
        [self actionCreate];
        return;
    }
    [self openInstanceNamed:self.names[indexPath.item] animated:YES];
}

@end
