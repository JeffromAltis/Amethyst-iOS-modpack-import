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

#pragma mark - Tile

@interface LauncherInstanceTileCell : UICollectionViewCell
@property(nonatomic) UIImageView *iconView;
@property(nonatomic) UILabel *nameLabel, *detailLabel;
@end

@implementation LauncherInstanceTileCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    self.contentView.layer.cornerRadius = 14;
    self.contentView.layer.cornerCurve = kCACornerCurveContinuous;

    _iconView = [UIImageView new];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.layer.magnificationFilter = kCAFilterNearest; // pixel-art icons stay crisp
    _iconView.layer.cornerRadius = 12;
    _iconView.clipsToBounds = YES;

    _nameLabel = [UILabel new];
    _nameLabel.font = LauncherTheme.rowTitleFont;
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
    stack.spacing = 6;
    [stack setCustomSpacing:10 afterView:_iconView];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [_iconView.widthAnchor constraintEqualToConstant:96],
        [_iconView.heightAnchor constraintEqualToConstant:96],
        [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:14],
        [stack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:8],
        [stack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-8],
        [_nameLabel.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [_detailLabel.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    ]];
    return self;
}

- (void)setCurrent:(BOOL)current {
    self.contentView.backgroundColor = current ? LauncherTheme.selectionBackground : LauncherTheme.panelBackground;
    self.contentView.layer.borderWidth = current ? 2 : 0;
    self.contentView.layer.borderColor = LauncherTheme.accent.CGColor;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.contentView.alpha = highlighted ? 0.6 : 1;
}

@end

#pragma mark - Home

@interface LauncherHomeViewController () <UICollectionViewDataSource, UICollectionViewDelegate>
@property(nonatomic) UICollectionView *collectionView;
@property(nonatomic) NSArray<NSString *> *names;
@property(nonatomic) UIButton *jitButton;
@property(nonatomic) UIBarButtonItem *toolsItem;
@end

@implementation LauncherHomeViewController

- (NSString *)title { return localize(@"launcher.menu.section.instances", nil); }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = LauncherTheme.contentBackground;

    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.itemSize = CGSizeMake(156, 196);
    layout.minimumInteritemSpacing = 16;
    layout.minimumLineSpacing = 18;
    layout.sectionInset = UIEdgeInsetsMake(20, 24, 24, 24);
    self.collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:layout];
    self.collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.collectionView.backgroundColor = UIColor.clearColor;
    self.collectionView.alwaysBounceVertical = YES;
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

- (void)setupBarItems {
    LauncherMenuViewController *menu = sidebarViewController;

    UIBarButtonItem *create = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus"]
        style:UIBarButtonItemStylePlain target:self action:@selector(actionCreate)];
    create.accessibilityLabel = localize(@"create.title", nil);

    if (!self.jitButton) {
        self.jitButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.jitButton.titleLabel.font = LauncherTheme.subtitleFont;
        self.jitButton.backgroundColor = LauncherTheme.pillBackground;
        self.jitButton.layer.cornerRadius = 14;
        self.jitButton.contentEdgeInsets = UIEdgeInsetsMake(5, 12, 5, 12);
        [self.jitButton addTarget:self action:@selector(actionJIT) forControlEvents:UIControlEventPrimaryActionTriggered];
    }
    [self updateJITButton];
    self.navigationItem.leftBarButtonItems = @[create, [[UIBarButtonItem alloc] initWithCustomView:self.jitButton]];

    UIBarButtonItem *settings = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"]
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

    UIBarButtonItem *account = [menu drawAccountButton];
    self.navigationItem.rightBarButtonItems = account ? @[account, settings, news, self.toolsItem] : @[settings, news, self.toolsItem];
}

- (void)updateJITButton {
    NSString *text = sidebarViewController.jitStatusText;
    self.jitButton.hidden = text.length == 0;
    [self.jitButton setTitle:text forState:UIControlStateNormal];
    BOOL on = [text isEqualToString:localize(@"launcher.jit.on", nil)];
    [self.jitButton setTitleColor:(on ? UIColor.systemGreenColor : UIColor.labelColor) forState:UIControlStateNormal];
    [self.jitButton sizeToFit];
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
    [sidebarViewController presentCreateInstanceWindow];
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

#pragma mark Instances

- (void)reloadInstances {
    self.names = [PLProfiles.current.profiles.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
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
    return self.names.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    LauncherInstanceTileCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"tile" forIndexPath:indexPath];
    NSString *name = self.names[indexPath.item];
    NSDictionary *profile = PLProfiles.current.profiles[name];
    cell.nameLabel.text = name;
    id version = profile[@"lastVersionId"];
    cell.detailLabel.text = [version isKindOfClass:NSString.class] ? version : @"";
    id icon = profile[@"icon"];
    [InstanceIcons setIconString:([icon isKindOfClass:NSString.class] ? icon : nil)
        onImageView:cell.iconView placeholder:[UIImage imageNamed:@"DefaultProfile"]];
    [cell setCurrent:[name isEqualToString:PLProfiles.current.selectedProfileName]];
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:NO];
    [self openInstanceNamed:self.names[indexPath.item] animated:YES];
}

@end
