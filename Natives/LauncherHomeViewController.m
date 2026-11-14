#import "InstanceIcons.h"
#import "LauncherInstallStatus.h"
#import "LauncherHomeViewController.h"
#import "InstanceGroups.h"
#import "LauncherInstanceDashboardViewController.h"
#import "LauncherMenuViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherIconPickerViewController.h"
#import "LauncherSettingsHubViewController.h"
#import "LauncherTheme.h"
#import "PLProfiles.h"
#import "UIKit+hook.h"
#import "utils.h"

NSNotificationName const LauncherJITStatusDidChangeNotification = @"LauncherJITStatusDidChangeNotification";

static const CGFloat kTileIcon = 112;

/// Icon + title centered in a capsule: half the gap moves the image left and the title right, and the side
/// padding grows by the same half, so sizeToFit leaves equal space on both sides (one-sided title insets
/// pushed the text off center)
static void CenterCapsuleContent(UIButton *button, CGFloat side, CGFloat vertical, CGFloat gap) {
    CGFloat half = gap / 2;
    button.imageEdgeInsets = UIEdgeInsetsMake(0, -half, 0, half);
    button.titleEdgeInsets = UIEdgeInsetsMake(0, half, 0, -half);
    button.contentEdgeInsets = UIEdgeInsetsMake(vertical, side + half, vertical, side + half);
}

#pragma mark - Tile

@interface LauncherInstanceTileCell : UICollectionViewCell
@property(nonatomic) UIImageView *iconView;
@property(nonatomic) UILabel *nameLabel, *detailLabel;
@property(nonatomic) CAShapeLayer *dashLayer; // "New Instance" tile only
@property(nonatomic) CAShapeLayer *ringLayer;   // install progress
@property(nonatomic) UIView *dimView;
@property(nonatomic) BOOL showsInstallCaption; // the detail line shows the install stage instead of the version
- (void)setInstallProgress:(float)progress; // < 0: not installing
@end

@implementation LauncherInstanceTileCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    setViewPointerInteraction(self, YES);
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
    [self setInstallProgress:-1];
    self.detailLabel.textColor = UIColor.secondaryLabelColor;
    self.showsInstallCaption = NO;
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

- (void)setInstallProgress:(float)progress {
    if (progress < 0) {
        self.dimView.hidden = YES;
        return;
    }
    if (!self.dimView) {
        self.dimView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kTileIcon, kTileIcon)];
        self.dimView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        self.dimView.userInteractionEnabled = NO;
        CAShapeLayer *track = [CAShapeLayer layer];
        CGRect ringRect = CGRectMake(kTileIcon / 2 - 30, kTileIcon / 2 - 30, 60, 60);
        UIBezierPath *path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(kTileIcon / 2, kTileIcon / 2) radius:28
            startAngle:-M_PI_2 endAngle:M_PI * 1.5 clockwise:YES];
        track.path = path.CGPath;
        track.fillColor = UIColor.clearColor.CGColor;
        track.strokeColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
        track.lineWidth = 5;
        self.ringLayer = [CAShapeLayer layer];
        self.ringLayer.path = path.CGPath;
        self.ringLayer.fillColor = UIColor.clearColor.CGColor;
        self.ringLayer.strokeColor = UIColor.whiteColor.CGColor;
        self.ringLayer.lineWidth = 5;
        self.ringLayer.lineCap = kCALineCapRound;
        (void)ringRect;
        [self.dimView.layer addSublayer:track];
        [self.dimView.layer addSublayer:self.ringLayer];
        [self.iconView addSubview:self.dimView];
    }
    self.dimView.hidden = NO;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.ringLayer.strokeEnd = MAX(0.02, MIN(progress, 1));
    [CATransaction commit];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.contentView.alpha = highlighted ? 0.55 : 1;
}

@end

#pragma mark - Group header

@interface LauncherInstanceGroupHeader : UICollectionReusableView <UIContextMenuInteractionDelegate>
@property(nonatomic) UILabel *titleLabel;
@property(nonatomic) UIImageView *chevron;
@property(nonatomic, copy) void (^onTap)(void);
/// Long-press menu (custom groups only); nil means no menu
@property(nonatomic, copy) UIMenu *(^menuProvider)(void);
@end

/// Plain label + chevron (not a UIButton: a system button animates its title change, and with header reuse
/// during reloadData that showed a blank or the other group's title)
@implementation LauncherInstanceGroupHeader
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    _chevron = [UIImageView new];
    _chevron.tintColor = UIColor.secondaryLabelColor;
    _chevron.contentMode = UIViewContentModeCenter;
    _chevron.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightBold];
    _titleLabel = [UILabel new];
    _titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    _titleLabel.textColor = UIColor.secondaryLabelColor;
    UIView *line = [UIView new];
    line.backgroundColor = LauncherTheme.separator;
    for (UIView *v in @[_chevron, _titleLabel, line]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:v];
    }
    [NSLayoutConstraint activateConstraints:@[
        [_chevron.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:36],
        [_chevron.widthAnchor constraintEqualToConstant:18],
        [_chevron.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:_chevron.trailingAnchor constant:8],
        [_titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [line.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:36],
        [line.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-36],
        [line.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [line.heightAnchor constraintEqualToConstant:1],
    ]];
    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)]];
    [self addInteraction:[[UIContextMenuInteraction alloc] initWithDelegate:self]];
    setViewPointerInteraction(self, NO);
    return self;
}
- (void)prepareForReuse {
    [super prepareForReuse];
    self.onTap = nil;
    self.menuProvider = nil;
}
- (void)tapped {
    if (self.onTap) self.onTap();
}
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    UIMenu *menu = self.menuProvider ? self.menuProvider() : nil;
    if (!menu) return nil;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
        actionProvider:^UIMenu *(NSArray *suggested) { return menu; }];
}
@end

#pragma mark - Home

@interface LauncherHomeViewController () <UICollectionViewDataSource, UICollectionViewDelegate, UISearchBarDelegate,
    UICollectionViewDragDelegate, UICollectionViewDropDelegate>
@property(nonatomic) UICollectionView *collectionView;
/// Groups: @{@"key", @"title", @"names"} plus @"group" (the name) for user-made groups.
/// User groups come first, then ungrouped instances split into automatic Modded/Vanilla groups.
/// The last group ends with the New Instance tile.
@property(nonatomic) NSArray<NSDictionary *> *sections;
@property(nonatomic) NSTimer *progressTimer;
@property(nonatomic) NSString *filter;
@property(nonatomic) UIButton *jitButton;
@property(nonatomic) UISearchBar *searchBar;
@property(nonatomic) UIBarButtonItem *toolsItem;
@property(nonatomic) UIStackView *titleStack; // search field + install pill
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
    self.collectionView.dragDelegate = self;
    self.collectionView.dropDelegate = self;
    self.collectionView.dragInteractionEnabled = YES;
    [self.collectionView registerClass:LauncherInstanceTileCell.class forCellWithReuseIdentifier:@"tile"];
    // Start and end of an install show at once (the timer only covers progress in between)
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateInstallProgress)
        name:LauncherInstallStatusDidChangeNotification object:nil];
    [self.collectionView registerClass:LauncherInstanceGroupHeader.class
        forSupplementaryViewOfKind:UICollectionElementKindSectionHeader withReuseIdentifier:@"group"];
    layout.headerReferenceSize = CGSizeMake(0, 44);
    layout.sectionInset = UIEdgeInsetsMake(20, 36, 24, 36);
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
    self.progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(updateInstallProgress)
        userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.progressTimer invalidate];
    self.progressTimer = nil;
}

/// While the launcher installs an instance (game files or a modpack), its tile shows a progress ring and the install
/// stage ("Files 87/187") in place of the version line
- (void)updateInstallProgress {
    LauncherInstallStatus *status = LauncherInstallStatus.current;
    NSString *installing = status.active ? status.profileName : nil;
    for (NSIndexPath *indexPath in self.collectionView.indexPathsForVisibleItems) {
        if ([self isNewInstanceTile:indexPath]) continue;
        NSString *name = [self nameAtIndexPath:indexPath];
        LauncherInstanceTileCell *cell = (LauncherInstanceTileCell *)[self.collectionView cellForItemAtIndexPath:indexPath];
        if (installing && [name isEqualToString:installing]) {
            [cell setInstallProgress:status.fraction < 0 ? 0 : status.fraction];
            cell.detailLabel.text = status.stage.length ? status.stage : @" ";
            cell.detailLabel.textColor = LauncherTheme.accentText;
            cell.showsInstallCaption = YES;
        } else {
            [cell setInstallProgress:-1];
            if (cell.showsInstallCaption) {
                cell.detailLabel.text = [LauncherHomeViewController versionSummaryForProfile:PLProfiles.current.profiles[name]];
                cell.detailLabel.textColor = UIColor.secondaryLabelColor;
                cell.showsInstallCaption = NO;
            }
        }
    }
}

#pragma mark Toolbar

- (UIButton *)capsuleWithTitle:(NSString *)title symbol:(NSString *)symbol filled:(BOOL)filled action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    button.tintColor = filled ? UIColor.whiteColor : UIColor.labelColor;
    button.backgroundColor = filled ? LauncherTheme.accent : LauncherTheme.pillBackground;
    CenterCapsuleContent(button, 16, 8, 8);
    [button addTarget:self action:action forControlEvents:UIControlEventPrimaryActionTriggered];
    [button sizeToFit];
    setButtonPointerInteraction(button);
    button.layer.cornerRadius = button.bounds.size.height / 2;
    return button;
}

- (void)setupBarItems {
    LauncherMenuViewController *menu = sidebarViewController;
    // The page title sits at the left of the bar, followed by the two create buttons (like the mockup)
    UILabel *titleLabel = [UILabel new];
    titleLabel.text = self.title;
    titleLabel.font = [UIFont systemFontOfSize:30 weight:UIFontWeightBold];
    [titleLabel sizeToFit];
    UIBarButtonItem *titleItem = [[UIBarButtonItem alloc] initWithCustomView:titleLabel];
    UIBarButtonItem *create = [[UIBarButtonItem alloc] initWithCustomView:
        [self capsuleWithTitle:localize(@"create.title", nil) symbol:@"plus" filled:YES action:@selector(actionCreate)]];
    self.navigationItem.leftBarButtonItems = @[titleItem, create];

    if (!self.searchBar) {
        self.searchBar = [UISearchBar new];
        self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
        self.searchBar.placeholder = localize(@"home.search", nil);
        self.searchBar.delegate = self;
        // The search field and the install pill share the title view, which fills the space between the left and
        // right items. While something installs the pill takes what it needs and the search field shrinks.
        self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
        [self.searchBar setContentHuggingPriority:UILayoutPriorityDefaultLow - 1 forAxis:UILayoutConstraintAxisHorizontal];
        [self.searchBar setContentCompressionResistancePriority:UILayoutPriorityDefaultLow - 1 forAxis:UILayoutConstraintAxisHorizontal];
        LauncherInstallPill *pill = [LauncherInstallPill pill];
        pill.maxWidth = 380;
        self.titleStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.searchBar, pill]];
        self.titleStack.axis = UILayoutConstraintAxisHorizontal;
        self.titleStack.alignment = UIStackViewAlignmentCenter;
        self.titleStack.spacing = 8;
        self.titleStack.translatesAutoresizingMaskIntoConstraints = NO;
        NSLayoutConstraint *fill = [self.titleStack.widthAnchor constraintEqualToConstant:4000];
        fill.priority = UILayoutPriorityDefaultLow;
        fill.active = YES;
    }
    self.navigationItem.titleView = self.titleStack;
    if (!self.jitButton) {
        self.jitButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.jitButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        self.jitButton.backgroundColor = LauncherTheme.pillBackground;
        CenterCapsuleContent(self.jitButton, 14, 7, 6);
        [self.jitButton addTarget:self action:@selector(actionJIT) forControlEvents:UIControlEventPrimaryActionTriggered];
        setButtonPointerInteraction(self.jitButton);
    }
    [self updateJITButton];

    UIBarButtonItem *settings = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape.fill"]
        style:UIBarButtonItemStylePlain target:self action:@selector(actionSettings)];

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

    // Right to left: gear, account, JIT, tools
    NSMutableArray *right = [NSMutableArray arrayWithObject:settings];
    UIBarButtonItem *account = [menu drawAccountButton];
    if (account) [right addObject:account];
    [right addObjectsFromArray:@[[[UIBarButtonItem alloc] initWithCustomView:self.jitButton], self.toolsItem]];
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

- (void)actionSettings {
    // Two panes when there is room, the category list alone otherwise
    BOOL wide = self.view.safeAreaLayoutGuide.layoutFrame.size.width >= 700;
    UIViewController *page = wide ? [LauncherSettingsPageViewController new] : [LauncherSettingsHubViewController new];
    [self.navigationController pushViewController:page animated:YES];
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
    NSMutableArray *modded = [NSMutableArray new], *vanilla = [NSMutableArray new];
    NSMutableDictionary<NSString *, NSMutableArray *> *custom = [NSMutableDictionary new];
    for (NSString *name in all) {
        NSString *group = [InstanceGroups groupOfProfile:PLProfiles.current.profiles[name]];
        if (group) {
            if (!custom[group]) custom[group] = [NSMutableArray new];
            [custom[group] addObject:name];
            continue;
        }
        NSString *summary = [LauncherHomeViewController versionSummaryForProfile:PLProfiles.current.profiles[name]];
        BOOL isVanilla = [summary hasSuffix:@"· Vanilla"];
        [(isVanilla ? vanilla : modded) addObject:name];
    }
    NSMutableArray *sections = [NSMutableArray new];
    for (NSString *group in [custom.allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
        [sections addObject:@{@"key": [@"group:" stringByAppendingString:group], @"title": group,
            @"group": group, @"names": custom[group]}];
    }
    if (modded.count) [sections addObject:@{@"key": @"modded", @"title": localize(@"home.group.modded", nil), @"names": modded}];
    if (vanilla.count || sections.count == 0) [sections addObject:@{@"key": @"vanilla", @"title": localize(@"home.group.vanilla", nil), @"names": vanilla}];
    self.sections = sections;
    [self.collectionView reloadData];
}

#pragma mark Groups

/// "Move to Group" submenu for an instance's long-press menu
- (UIMenu *)groupMenuForInstanceNamed:(NSString *)name {
    NSString *current = [InstanceGroups groupOfProfile:PLProfiles.current.profiles[name]];
    NSArray *children = [InstanceGroups pickerMenuElementsWithCurrent:current presenter:self onPick:^(NSString *group) {
        [InstanceGroups setGroup:group forInstances:@[name]];
    }];
    return [UIMenu menuWithTitle:localize(@"home.group.move", nil) image:[UIImage systemImageNamed:@"folder"]
        identifier:nil options:0 children:children];
}

/// Long-press menu on a user-made group's header: rename, or ungroup its instances
- (UIMenu *)menuForGroup:(NSString *)group {
    __weak typeof(self) weakSelf = self;
    UIAction *rename = [UIAction actionWithTitle:localize(@"home.group.rename", nil) image:[UIImage systemImageNamed:@"pencil"]
        identifier:nil handler:^(UIAction *a) {
            [InstanceGroups promptForGroupNameFrom:weakSelf title:localize(@"home.group.rename", nil) initial:group completion:^(NSString *newName) {
                if ([newName isEqualToString:group]) return;
                BOOL collapsed = [weakSelf isGroupKeyCollapsed:[@"group:" stringByAppendingString:group]];
                if ([InstanceGroups setGroup:newName forInstances:[InstanceGroups instancesInGroup:group]]) {
                    [weakSelf setGroupKey:[@"group:" stringByAppendingString:group] collapsed:NO];
                    if (collapsed) [weakSelf setGroupKey:[@"group:" stringByAppendingString:newName] collapsed:YES];
                }
            }];
        }];
    UIAction *delete = [UIAction actionWithTitle:localize(@"home.group.delete", nil) image:[UIImage systemImageNamed:@"trash"]
        identifier:nil handler:^(UIAction *a) {
            if ([InstanceGroups setGroup:nil forInstances:[InstanceGroups instancesInGroup:group]]) {
                [weakSelf setGroupKey:[@"group:" stringByAppendingString:group] collapsed:NO];
            }
        }];
    delete.attributes = UIMenuElementAttributesDestructive;
    if (@available(iOS 15.0, *)) delete.subtitle = localize(@"home.group.delete.subtitle", nil);
    return [UIMenu menuWithTitle:group children:@[rename, delete]];
}

- (BOOL)isGroupKeyCollapsed:(NSString *)key {
    return [[NSUserDefaults.standardUserDefaults arrayForKey:@"home.collapsed_groups"] containsObject:key];
}

- (void)setGroupKey:(NSString *)key collapsed:(BOOL)collapsed {
    NSMutableArray *list = [[NSUserDefaults.standardUserDefaults arrayForKey:@"home.collapsed_groups"] mutableCopy] ?: [NSMutableArray new];
    [list removeObject:key];
    if (collapsed) [list addObject:key];
    [NSUserDefaults.standardUserDefaults setObject:list forKey:@"home.collapsed_groups"];
}

- (BOOL)isCollapsed:(NSInteger)section {
    NSArray *collapsed = [NSUserDefaults.standardUserDefaults arrayForKey:@"home.collapsed_groups"];
    return [collapsed containsObject:self.sections[section][@"key"]] && self.filter.length == 0;
}

- (void)toggleGroupWithKey:(NSString *)key {
    NSMutableArray *collapsed = [[NSUserDefaults.standardUserDefaults arrayForKey:@"home.collapsed_groups"] mutableCopy] ?: [NSMutableArray new];
    if ([collapsed containsObject:key]) [collapsed removeObject:key]; else [collapsed addObject:key];
    [NSUserDefaults.standardUserDefaults setObject:collapsed forKey:@"home.collapsed_groups"];
    [self.collectionView reloadData];
}

- (BOOL)isNewInstanceTile:(NSIndexPath *)indexPath {
    return indexPath.item >= (NSInteger)[self.sections[indexPath.section][@"names"] count];
}

- (NSString *)nameAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section >= (NSInteger)self.sections.count || [self isNewInstanceTile:indexPath]) return nil;
    return self.sections[indexPath.section][@"names"][indexPath.item];
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

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return self.sections.count;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    if ([self isCollapsed:section]) return 0;
    // The last group ends with the "New Instance" tile (not while searching)
    BOOL last = section == (NSInteger)self.sections.count - 1;
    return [self.sections[section][@"names"] count] + (last && self.filter.length == 0 ? 1 : 0);
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath {
    LauncherInstanceGroupHeader *header = [collectionView dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:@"group" forIndexPath:indexPath];
    NSDictionary *group = self.sections[indexPath.section];
    header.titleLabel.text = [NSString stringWithFormat:@"%@  %lu", [group[@"title"] uppercaseString], (unsigned long)[group[@"names"] count]];
    header.chevron.image = [UIImage systemImageNamed:([self isCollapsed:indexPath.section] ? @"chevron.right" : @"chevron.down")];
    NSString *key = group[@"key"];
    __weak typeof(self) weakSelf = self;
    header.onTap = ^{ [weakSelf toggleGroupWithKey:key]; };
    NSString *custom = group[@"group"];
    header.menuProvider = custom ? ^UIMenu *{ return [weakSelf menuForGroup:custom]; } : nil;
    return header;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    LauncherInstanceTileCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"tile" forIndexPath:indexPath];
    if ([self isNewInstanceTile:indexPath]) {
        [cell showAsNewInstanceTile];
        return cell;
    }
    NSString *name = [self nameAtIndexPath:indexPath];
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
    if ([self isNewInstanceTile:indexPath]) {
        [self actionCreate];
        return;
    }
    [self openInstanceNamed:[self nameAtIndexPath:indexPath] animated:YES];
}

#pragma mark Long-press menu

- (void)playInstanceNamed:(NSString *)name fromView:(UIView *)view {
    if (![PLProfiles.current.selectedProfileName isEqualToString:name]) {
        PLProfiles.current.selectedProfileName = name;
        [NSNotificationCenter.defaultCenter postNotificationName:PLProfilesDidChangeNotification object:self];
    }
    SEL launch = NSSelectorFromString(@"performInstallOrShowDetails:");
    if ([self.navigationController respondsToSelector:launch]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self.navigationController performSelector:launch withObject:view];
        #pragma clang diagnostic pop
    }
}

- (void)changeIconOfInstanceNamed:(NSString *)name {
    NSMutableDictionary *profile = PLProfiles.current.profiles[name];
    id current = profile[@"icon"];
    NSString *currentKey = [current isKindOfClass:NSString.class] && [InstanceIcons isKeyReference:current] ? current : nil;
    LauncherIconPickerViewController *picker = [[LauncherIconPickerViewController alloc] initWithSelectedKey:currentKey];
    picker.completion = ^(NSString *key) {
        if (key.length == 0 || !PLProfiles.current.profiles[name]) return;
        id previous = profile[@"icon"];
        profile[@"icon"] = key;
        if (![PLProfiles.current save]) {
            if (previous) profile[@"icon"] = previous; else [profile removeObjectForKey:@"icon"];
            return;
        }
        [NSNotificationCenter.defaultCenter postNotificationName:PLProfilesDidChangeNotification object:self];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:picker];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    nav.preferredContentSize = CGSizeMake(720, 660);
    [LauncherTheme applyBarBackground:LauncherTheme.chromeBackground toNavigationController:nav];
    [self presentViewController:nav animated:YES completion:nil];
}

- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)collectionView contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    NSString *name = [self nameAtIndexPath:indexPath];
    if (!name) return nil;
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested) {
        UIView *cell = [collectionView cellForItemAtIndexPath:indexPath] ?: collectionView;
        return [UIMenu menuWithTitle:name children:@[
            [UIAction actionWithTitle:localize(@"Play", nil) image:[UIImage systemImageNamed:@"play.fill"] identifier:nil
                handler:^(UIAction *a) { [weakSelf playInstanceNamed:name fromView:cell]; }],
            [UIAction actionWithTitle:localize(@"home.menu.open", nil) image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil
                handler:^(UIAction *a) { [weakSelf openInstanceNamed:name animated:YES]; }],
            [UIAction actionWithTitle:localize(@"icon.change", nil) image:[UIImage systemImageNamed:@"photo"] identifier:nil
                handler:^(UIAction *a) { [weakSelf changeIconOfInstanceNamed:name]; }],
            [weakSelf groupMenuForInstanceNamed:name] ?: [UIMenu menuWithChildren:@[]],
        ]];
    }];
}

#pragma mark Drag and drop between groups

- (NSArray<UIDragItem *> *)collectionView:(UICollectionView *)collectionView itemsForBeginningDragSession:(id<UIDragSession>)session atIndexPath:(NSIndexPath *)indexPath {
    NSString *name = [self nameAtIndexPath:indexPath];
    if (!name) return @[];
    UIDragItem *item = [[UIDragItem alloc] initWithItemProvider:[[NSItemProvider alloc] initWithObject:name]];
    item.localObject = name;
    return @[item];
}

- (BOOL)collectionView:(UICollectionView *)collectionView canHandleDropSession:(id<UIDropSession>)session {
    return session.localDragSession != nil && self.filter.length == 0;
}

- (UICollectionViewDropProposal *)collectionView:(UICollectionView *)collectionView dropSessionDidUpdate:(id<UIDropSession>)session withDestinationIndexPath:(NSIndexPath *)destinationIndexPath {
    if (!session.localDragSession || !destinationIndexPath || destinationIndexPath.section >= (NSInteger)self.sections.count) {
        return [[UICollectionViewDropProposal alloc] initWithDropOperation:UIDropOperationForbidden];
    }
    return [[UICollectionViewDropProposal alloc] initWithDropOperation:UIDropOperationMove
        intent:UICollectionViewDropIntentInsertAtDestinationIndexPath];
}

/// Dropping a tile into a section moves it to that group; automatic groups mean "ungrouped".
/// Order inside a group stays alphabetical, like Prism.
- (void)collectionView:(UICollectionView *)collectionView performDropWithCoordinator:(id<UICollectionViewDropCoordinator>)coordinator {
    NSIndexPath *destination = coordinator.destinationIndexPath;
    if (!destination || destination.section >= (NSInteger)self.sections.count) return;
    NSString *group = self.sections[destination.section][@"group"];
    NSMutableArray *names = [NSMutableArray new];
    for (id<UICollectionViewDropItem> item in coordinator.items) {
        id name = item.dragItem.localObject;
        if ([name isKindOfClass:NSString.class]) [names addObject:name];
    }
    if (names.count) [InstanceGroups setGroup:group forInstances:names];
}

@end
