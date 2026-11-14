#import "LauncherHomeViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherInstanceDashboardViewController.h"
#import "InstanceGroups.h"
#import "InstanceIcons.h"
#import "LauncherIconPickerViewController.h"
#import "LauncherInstallStatus.h"
#import "LauncherPreferences.h"
#import "LauncherTheme.h"
#import "LauncherProfileEditorViewController.h"
#import "installer/ModsManagerViewController.h"
#import "PLProfiles.h"
#import "UIImageView+AFNetworking.h"
#import "UIKit+hook.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

#define kCardRadius 14.0
#define kRowMinHeight 64.0
#define kRowInset 16.0
#define kRamStepMB 256.0
#define kRamMinMB 512.0

@interface LauncherInstanceDashboardViewController ()
@property(nonatomic, copy) NSString *profileName;

@property(nonatomic) UIStackView *contentStack;
/// Two columns on wide screens: hero card (icon, name, Play, Open Folder) left, settings right
@property(nonatomic) UIStackView *heroStack, *rightStack;
@property(nonatomic) UILabel *heroVersionLabel;
@property(nonatomic) UIStackView *heroChips;
@property(nonatomic) UIButton *heroFolderButton;
@property(nonatomic) UIButton *heroPlayButton;
/// Under Play while this instance installs: "Files 87/187 · 8.1 MB/s · 21 sec left"
@property(nonatomic) UILabel *heroInstallLabel;
@property(nonatomic) NSTimer *progressTimer;
// Inside the big rounded panel that holds the settings groups
@property(nonatomic) UIStackView *panelStack;

@property(nonatomic) UILabel *headerLabel;
@property(nonatomic) UIImageView *headerIconView;
@property(nonatomic) UILabel *nameValueLabel;
@property(nonatomic) UILabel *versionValueLabel;
@property(nonatomic) UILabel *gameDirValueLabel;
@property(nonatomic) UIButton *folderButton;

@property(nonatomic) UISlider *ramSlider;
@property(nonatomic) UILabel *ramValueLabel;
@property(nonatomic) UIButton *javaButton;
@property(nonatomic) UIButton *groupButton;
@property(nonatomic) UIButton *javaArgsButton;
@property(nonatomic) UIButton *deleteFilesButton;
@end

/// Slider with a tick mark at every whole gigabyte, so the steps between 256MB stops are easy to read
@interface RamSlider : UISlider
@property(nonatomic) NSMutableArray<CALayer *> *tickLayers;
@end

@implementation RamSlider
- (void)layoutSubviews {
    [super layoutSubviews];
    if (!self.tickLayers) self.tickLayers = [NSMutableArray new];
    CGRect track = [self trackRectForBounds:self.bounds];
    NSInteger count = 0;
    for (CGFloat mb = 1024; mb <= self.maximumValue; mb += 1024, count++) {
        CALayer *tick;
        if (count < (NSInteger)self.tickLayers.count) {
            tick = self.tickLayers[count];
        } else {
            tick = [CALayer layer];
            tick.cornerRadius = 1;
            // Below the track and thumb so the thumb slides over the marks
            [self.layer insertSublayer:tick atIndex:0];
            [self.tickLayers addObject:tick];
        }
        if (mb < self.minimumValue) { tick.hidden = YES; continue; }
        tick.hidden = NO;
        CGRect thumb = [self thumbRectForBounds:self.bounds trackRect:track value:mb];
        tick.frame = CGRectMake(CGRectGetMidX(thumb) - 1, CGRectGetMidY(track) - 7, 2, 14);
        tick.backgroundColor = [UIColor.secondaryLabelColor resolvedColorWithTraitCollection:self.traitCollection].CGColor;
    }
    while ((NSInteger)self.tickLayers.count > count) { // the maximum shrank
        [self.tickLayers.lastObject removeFromSuperlayer];
        [self.tickLayers removeLastObject];
    }
}
@end

// The fallback icon never changes, so it is drawn once instead of on every refresh
static UIImage *DefaultInstanceIcon(void) {
    static UIImage *icon;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        icon = [[UIImage imageNamed:@"DefaultProfile"] _imageWithSize:CGSizeMake(44, 44)];
    });
    return icon;
}

@implementation LauncherInstanceDashboardViewController

#pragma mark - Lifecycle

- (instancetype)initWithProfileName:(NSString *)profileName {
    self = [super initWithNibName:nil bundle:nil];
    self.profileName = profileName;
    self.title = localize(@"instance.dashboard.breadcrumb", nil);
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = LauncherTheme.contentBackground;
    self.navigationItem.rightBarButtonItems = @[[LauncherInstallPill barButtonItem]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updatePlayProgress)
        name:LauncherInstallStatusDidChangeNotification object:nil];

    UIScrollView *scrollView = [UIScrollView new];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = YES;
    scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scrollView];

    self.contentStack = [UIStackView new];
    self.contentStack.axis = UILayoutConstraintAxisVertical;
    self.contentStack.spacing = 8;
    self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentStack.axis = UILayoutConstraintAxisHorizontal;
    self.contentStack.alignment = UIStackViewAlignmentTop;
    self.contentStack.spacing = 24;
    [scrollView addSubview:self.contentStack];

    UIView *hero = [UIView new];
    hero.backgroundColor = LauncherTheme.panelBackground;
    hero.layer.cornerRadius = 18;
    hero.layer.borderWidth = 1;
    hero.layer.borderColor = LauncherTheme.separator.CGColor;
    self.heroStack = [UIStackView new];
    self.heroStack.axis = UILayoutConstraintAxisVertical;
    self.heroStack.alignment = UIStackViewAlignmentCenter;
    self.heroStack.spacing = 10;
    self.heroStack.layoutMarginsRelativeArrangement = YES;
    self.heroStack.layoutMargins = UIEdgeInsetsMake(24, 18, 20, 18);
    self.heroStack.translatesAutoresizingMaskIntoConstraints = NO;
    [hero addSubview:self.heroStack];
    self.rightStack = [UIStackView new];
    self.rightStack.axis = UILayoutConstraintAxisVertical;
    self.rightStack.spacing = 8;
    [self.contentStack addArrangedSubview:hero];
    [self.contentStack addArrangedSubview:self.rightStack];
    NSLayoutConstraint *heroWidth = [hero.widthAnchor constraintEqualToConstant:300];
    heroWidth.priority = UILayoutPriorityDefaultHigh; // the stacked (narrow) layout stretches it
    [NSLayoutConstraint activateConstraints:@[
        heroWidth,
        [self.heroStack.topAnchor constraintEqualToAnchor:hero.topAnchor],
        [self.heroStack.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor],
        [self.heroStack.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor],
        [self.heroStack.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor],
    ]];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],

        [self.contentStack.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor constant:8],
        [self.contentStack.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor constant:-24],
        [self.contentStack.leadingAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.leadingAnchor constant:24],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.trailingAnchor constant:-24],
    ]];

    [self buildHeader];
    [self buildPanel];
    [self buildInstanceSettingsGroup];
    [self buildModsGroup];
    [self buildDedicatedSettingsGroup];
    [self buildDangerZone];

    [self reloadFromProfile];

    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(reloadFromProfile)
        name:PLProfilesDidChangeNotification object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

/// Java and renderer facts under the version, like the Edit Instance page shows them
- (void)updateHeroChips {
    for (UIView *v in self.heroChips.arrangedSubviews) [v removeFromSuperview];
    NSDictionary *profile = [self profile];
    NSString *java = [profile[@"javaVersion"] isKindOfClass:NSString.class] && [profile[@"javaVersion"] length] > 0 ?
        [@"Java " stringByAppendingString:profile[@"javaVersion"]] : [NSString stringWithFormat:@"Java %@", localize(@"instance.java_version.automatic", nil)];
    NSString *rendererKey = [profile[@"renderer"] isKindOfClass:NSString.class] && [profile[@"renderer"] length] > 0 ?
        profile[@"renderer"] : getPrefObject(@"video.renderer");
    NSString *renderer = rendererKey ? rendererDisplayName(rendererKey) : nil;
    for (NSString *text in @[java, renderer ?: @""]) {
        if (text.length == 0) continue;
        UILabel *chip = [UILabel new];
        chip.text = [NSString stringWithFormat:@"  %@  ", text];
        chip.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        chip.backgroundColor = LauncherTheme.pillBackground;
        chip.layer.cornerRadius = 13;
        chip.clipsToBounds = YES;
        [chip.heightAnchor constraintEqualToConstant:26].active = YES;
        [self.heroChips addArrangedSubview:chip];
    }
}

/// Side by side when there is room, stacked otherwise (portrait iPhone, Slide Over)
- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    BOOL wide = self.view.safeAreaLayoutGuide.layoutFrame.size.width >= 700;
    self.contentStack.axis = wide ? UILayoutConstraintAxisHorizontal : UILayoutConstraintAxisVertical;
    self.contentStack.alignment = wide ? UIStackViewAlignmentTop : UIStackViewAlignmentFill;
}

/// Same as the launch bar's Play: this page's instance is the selected one (the home screen selects it)
- (void)actionPlay:(UIButton *)sender {
    if (![PLProfiles.current.selectedProfileName isEqualToString:self.profileName]) {
        PLProfiles.current.selectedProfileName = self.profileName;
        [NSNotificationCenter.defaultCenter postNotificationName:PLProfilesDidChangeNotification object:self];
    }
    SEL launch = NSSelectorFromString(@"performInstallOrShowDetails:");
    if ([self.navigationController respondsToSelector:launch]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self.navigationController performSelector:launch withObject:sender];
        #pragma clang diagnostic pop
    }
}

/// The launch bar is gone, so Play shows the download while it runs (tapping it then opens the details)
- (void)updatePlayProgress {
    LauncherNavigationController *nav = (LauncherNavigationController *)self.navigationController;
    if (![nav isKindOfClass:LauncherNavigationController.class] || !self.heroPlayButton) return;
    BOOL busy = !nav.progressViewMain.hidden;
    NSString *title = busy ? [NSString stringWithFormat:@"%d%%", (int)round(nav.progressViewMain.progress * 100)] : localize(@"Play", nil);
    // The stage line only appears on the page of the instance being installed
    LauncherInstallStatus *status = LauncherInstallStatus.current;
    BOOL installingThis = status.active && [status.profileName isEqualToString:self.profileName];
    NSString *line = nil;
    if (installingThis) {
        line = status.stage ?: @"";
        if (status.detail.length) line = [line stringByAppendingFormat:@"  ·  %@", status.detail];
    }
    if (self.heroInstallLabel.hidden != (line.length == 0)) self.heroInstallLabel.hidden = line.length == 0;
    if (line.length && ![self.heroInstallLabel.text isEqualToString:line]) self.heroInstallLabel.text = line;
    if (![[self.heroPlayButton titleForState:UIControlStateNormal] isEqualToString:title]) {
        [UIView performWithoutAnimation:^{
            [self.heroPlayButton setTitle:title forState:UIControlStateNormal];
            [self.heroPlayButton setImage:[UIImage systemImageNamed:(busy ? @"arrow.down.circle" : @"play.fill")] forState:UIControlStateNormal];
            [self.heroPlayButton layoutIfNeeded];
        }];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.progressTimer invalidate];
    self.progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(updatePlayProgress) userInfo:nil repeats:YES];
    [self updatePlayProgress];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.progressTimer invalidate];
    self.progressTimer = nil;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Also called by LauncherProfileEditorViewController after it saves
    [self reloadFromProfile];
}

#pragma mark - Model helpers

- (NSMutableDictionary *)profile {
    return PLProfiles.current.profiles[self.profileName];
}

- (void)saveProfile {
    [PLProfiles.current save];
}

- (NSString *)absoluteGameDirPath {
    return [PLProfiles absolutePathForGameDir:[self profile][@"gameDir"]];
}

- (CGFloat)systemMemoryMB {
    return NSProcessInfo.processInfo.physicalMemory / 1048576.0;
}

/// Highest allocation we let the slider reach (same 85% cap as the global memory preference).
- (CGFloat)maxAllocatableMB {
    return floor([self systemMemoryMB] * 0.85 / kRamStepMB) * kRamStepMB;
}

- (CGFloat)currentAllocationMB {
    NSString *own = [self profile][@"allocatedMemory"];
    if (own.intValue > 0) return own.intValue;
    return getPrefInt(@"java.allocated_memory");
}

- (NSString *)formatMB:(CGFloat)mb {
    if (fmod(mb, 1024) == 0) {
        return [NSString stringWithFormat:@"%dGB", (int)(mb / 1024)];
    }
    return [NSString stringWithFormat:@"%.1fGB", mb / 1024];
}

#pragma mark - View building

- (UILabel *)labelWithFont:(UIFont *)font color:(UIColor *)color {
    UILabel *label = [UILabel new];
    label.font = font;
    label.textColor = color;
    label.numberOfLines = 0;
    return label;
}

- (UIButton *)iconButtonWithSystemName:(NSString *)name action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightRegular];
    [button setImage:[UIImage systemImageNamed:name withConfiguration:config] forState:UIControlStateNormal];
    button.tintColor = UIColor.secondaryLabelColor;
    [button addTarget:self action:action forControlEvents:UIControlEventPrimaryActionTriggered];
    setButtonPointerInteraction(button);
    [button.widthAnchor constraintEqualToConstant:36].active = YES;
    [button.heightAnchor constraintEqualToConstant:36].active = YES;
    return button;
}

- (UILabel *)sectionCaption:(NSString *)text {
    UILabel *label = [self labelWithFont:LauncherTheme.headerFont color:UIColor.secondaryLabelColor];
    label.text = text.uppercaseString;
    return label;
}

/// Rounded container that stacks rows with hairline separators between them.
- (UIView *)cardWithRows:(NSArray<UIView *> *)rows {
    UIView *card = [UIView new];
    card.backgroundColor = LauncherTheme.rowBackground;
    card.layer.cornerRadius = kCardRadius;
    card.clipsToBounds = YES;

    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
    ]];

    for (NSUInteger i = 0; i < rows.count; i++) {
        if (i > 0) {
            UIView *separator = [UIView new];
            separator.backgroundColor = LauncherTheme.separator;
            [separator.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale].active = YES;
            UIView *holder = [UIView new];
            separator.translatesAutoresizingMaskIntoConstraints = NO;
            [holder addSubview:separator];
            [NSLayoutConstraint activateConstraints:@[
                [separator.topAnchor constraintEqualToAnchor:holder.topAnchor],
                [separator.bottomAnchor constraintEqualToAnchor:holder.bottomAnchor],
                [separator.leadingAnchor constraintEqualToAnchor:holder.leadingAnchor constant:kRowInset],
                [separator.trailingAnchor constraintEqualToAnchor:holder.trailingAnchor],
            ]];
            [stack addArrangedSubview:holder];
        }
        [stack addArrangedSubview:rows[i]];
    }
    return card;
}

/// A row with a title (+ optional value label underneath) on the left and an optional control on the right.
- (UIView *)rowWithTitle:(NSString *)title valueLabel:(UILabel *)valueLabel trailing:(UIView *)trailing {
    UIView *row = [UIView new];
    [row.heightAnchor constraintGreaterThanOrEqualToConstant:kRowMinHeight].active = YES;

    UILabel *titleLabel = [self labelWithFont:LauncherTheme.rowTitleFont color:UIColor.labelColor];
    titleLabel.text = title;

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel]];
    if (valueLabel) {
        valueLabel.font = LauncherTheme.bodyFont;
        valueLabel.textColor = UIColor.secondaryLabelColor;
        valueLabel.numberOfLines = 2;
        valueLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [textStack addArrangedSubview:valueLabel];
    }
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 2;
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:textStack];

    [NSLayoutConstraint activateConstraints:@[
        [textStack.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:kRowInset],
        [textStack.topAnchor constraintEqualToAnchor:row.topAnchor constant:12],
        [textStack.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-12],
    ]];

    if (trailing) {
        trailing.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:trailing];
        [trailing setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [trailing setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [NSLayoutConstraint activateConstraints:@[
            [trailing.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-kRowInset],
            [trailing.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:trailing.leadingAnchor constant:-12],
        ]];
    } else {
        [textStack.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-kRowInset].active = YES;
    }
    return row;
}

/// Bordered 260pt button with a chevron that opens its menu on tap (Java version, Group)
- (UIButton *)dropdownButton {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.showsMenuAsPrimaryAction = YES;
    setButtonPointerInteraction(button);
    button.tintColor = UIColor.labelColor;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    button.contentEdgeInsets = UIEdgeInsetsMake(8, 12, 8, 36);
    button.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    button.layer.cornerRadius = 10;
    button.layer.borderWidth = 1;
    button.layer.borderColor = UIColor.separatorColor.CGColor;
    [button.widthAnchor constraintEqualToConstant:260].active = YES;
    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.down"]];
    chevron.tintColor = UIColor.secondaryLabelColor;
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.userInteractionEnabled = NO;
    [button addSubview:chevron];
    [NSLayoutConstraint activateConstraints:@[
        [chevron.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-12],
        [chevron.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
    ]];
    return button;
}

- (UIStackView *)trailingStackWithViews:(NSArray<UIView *> *)views {
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:views];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 10;
    return stack;
}

/// One large rounded panel holds all settings groups, like the design concept
- (void)buildPanel {
    UIView *panel = [UIView new];
    panel.backgroundColor = UIColor.clearColor; // groups sit straight on the page (mockup)

    self.panelStack = [UIStackView new];
    self.panelStack.axis = UILayoutConstraintAxisVertical;
    self.panelStack.spacing = 8;
    self.panelStack.layoutMarginsRelativeArrangement = YES;
    self.panelStack.layoutMargins = UIEdgeInsetsZero;
    self.panelStack.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:self.panelStack];
    [NSLayoutConstraint activateConstraints:@[
        [self.panelStack.topAnchor constraintEqualToAnchor:panel.topAnchor],
        [self.panelStack.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor],
        [self.panelStack.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor],
        [self.panelStack.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],
    ]];
    [self.rightStack addArrangedSubview:panel];
    [self.rightStack setCustomSpacing:28 afterView:panel];
}

- (void)addGroupWithCaption:(NSString *)caption rows:(NSArray<UIView *> *)rows {
    UILabel *captionLabel = [self sectionCaption:caption];
    [self.panelStack addArrangedSubview:captionLabel];
    [self.panelStack setCustomSpacing:8 afterView:captionLabel];
    UIView *card = [self cardWithRows:rows];
    [self.panelStack addArrangedSubview:card];
    [self.panelStack setCustomSpacing:22 afterView:card];
}

- (void)buildHeader {
    self.headerLabel = [self labelWithFont:LauncherTheme.pageTitleFont color:UIColor.labelColor];
    self.headerLabel.numberOfLines = 2;
    self.headerLabel.adjustsFontSizeToFitWidth = YES;
    self.headerLabel.minimumScaleFactor = 0.6;

    UIButton *edit = [self iconButtonWithSystemName:@"pencil" action:@selector(actionRename)];
    edit.accessibilityLabel = localize(@"Rename", nil);
    [edit setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIView *spacer = [UIView new];
    [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow - 1 forAxis:UILayoutConstraintAxisHorizontal];

    // Instance icon to the left of the title, same image as in the sidebar
    self.headerIconView = [UIImageView new];
    self.headerIconView.contentMode = UIViewContentModeScaleAspectFit;
    self.headerIconView.layer.magnificationFilter = kCAFilterNearest;
    self.headerIconView.layer.cornerRadius = 18;
    self.headerIconView.clipsToBounds = YES;
    self.headerIconView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.headerIconView setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.headerIconView setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [NSLayoutConstraint activateConstraints:@[
        [self.headerIconView.widthAnchor constraintEqualToConstant:160],
        [self.headerIconView.heightAnchor constraintEqualToConstant:160],
    ]];
    // Tap the icon to pick another one (a small pencil in the corner says so)
    self.headerIconView.userInteractionEnabled = YES;
    self.headerIconView.isAccessibilityElement = YES;
    self.headerIconView.accessibilityTraits = UIAccessibilityTraitButton;
    self.headerIconView.accessibilityLabel = localize(@"icon.change", nil);
    [self.headerIconView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(actionChangeIcon)]];
    setViewPointerInteraction(self.headerIconView, YES);
    UIImageView *iconBadge = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"pencil.circle.fill"]];
    iconBadge.tintColor = LauncherTheme.accent;
    iconBadge.backgroundColor = UIColor.whiteColor;
    iconBadge.layer.cornerRadius = 15;
    iconBadge.clipsToBounds = YES;
    iconBadge.translatesAutoresizingMaskIntoConstraints = NO;
    [self.headerIconView addSubview:iconBadge];
    [NSLayoutConstraint activateConstraints:@[
        [iconBadge.widthAnchor constraintEqualToConstant:30],
        [iconBadge.heightAnchor constraintEqualToConstant:30],
        [iconBadge.trailingAnchor constraintEqualToAnchor:self.headerIconView.trailingAnchor],
        [iconBadge.bottomAnchor constraintEqualToAnchor:self.headerIconView.bottomAnchor],
    ]];

    self.headerLabel.textAlignment = NSTextAlignmentCenter;
    UIStackView *title = [[UIStackView alloc] initWithArrangedSubviews:@[self.headerLabel, edit]];
    title.axis = UILayoutConstraintAxisHorizontal;
    title.alignment = UIStackViewAlignmentCenter;
    title.spacing = 6;
    self.heroVersionLabel = [self labelWithFont:LauncherTheme.subtitleFont color:UIColor.secondaryLabelColor];

    UIButton *play = [UIButton buttonWithType:UIButtonTypeSystem];
    [play setTitle:localize(@"Play", nil) forState:UIControlStateNormal];
    [play setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal];
    play.titleLabel.font = LauncherTheme.buttonFont;
    play.tintColor = UIColor.whiteColor;
    play.backgroundColor = LauncherTheme.accent;
    play.layer.cornerRadius = 28;
    play.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    play.imageEdgeInsets = UIEdgeInsetsMake(0, -6, 0, 6);
    [play addTarget:self action:@selector(actionPlay:) forControlEvents:UIControlEventPrimaryActionTriggered];
    setButtonPointerInteraction(play);
    self.heroPlayButton = play;

    self.heroFolderButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.heroFolderButton setTitle:localize(@"instance.open_folder", nil) forState:UIControlStateNormal];
    [self.heroFolderButton setImage:[UIImage systemImageNamed:@"folder"] forState:UIControlStateNormal];
    self.heroFolderButton.titleLabel.font = LauncherTheme.buttonFont;
    self.heroFolderButton.backgroundColor = LauncherTheme.rowBackground;
    self.heroFolderButton.layer.cornerRadius = 25;
    self.heroFolderButton.imageEdgeInsets = UIEdgeInsetsMake(0, -6, 0, 6);
    [self.heroFolderButton addTarget:self action:@selector(actionOpenFolderUnavailable) forControlEvents:UIControlEventPrimaryActionTriggered];
    setButtonPointerInteraction(self.heroFolderButton);

    self.heroVersionLabel.font = [UIFont systemFontOfSize:16];
    self.headerLabel.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    self.heroChips = [UIStackView new];
    self.heroChips.spacing = 8;
    self.heroInstallLabel = [self labelWithFont:[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold] color:LauncherTheme.accentText];
    self.heroInstallLabel.textAlignment = NSTextAlignmentCenter;
    self.heroInstallLabel.numberOfLines = 2;
    self.heroInstallLabel.hidden = YES;
    for (UIView *v in @[self.headerIconView, title, self.heroVersionLabel, self.heroChips, play, self.heroInstallLabel, self.heroFolderButton]) {
        [self.heroStack addArrangedSubview:v];
    }
    [self.heroStack setCustomSpacing:8 afterView:play];
    [self.heroStack setCustomSpacing:16 afterView:self.headerIconView];
    [self.heroStack setCustomSpacing:12 afterView:self.heroVersionLabel];
    [self.heroStack setCustomSpacing:22 afterView:self.heroChips];
    [NSLayoutConstraint activateConstraints:@[
        [title.widthAnchor constraintLessThanOrEqualToAnchor:self.heroStack.layoutMarginsGuide.widthAnchor],
        [play.widthAnchor constraintEqualToAnchor:self.heroStack.layoutMarginsGuide.widthAnchor],
        [play.heightAnchor constraintEqualToConstant:56],
        [self.heroFolderButton.widthAnchor constraintEqualToAnchor:self.heroStack.layoutMarginsGuide.widthAnchor],
        [self.heroFolderButton.heightAnchor constraintEqualToConstant:50],
    ]];
    (void)spacer;
}

- (void)buildInstanceSettingsGroup {
    // Instance name
    self.nameValueLabel = [UILabel new];
    UIView *nameRow = [self rowWithTitle:localize(@"instance.name", nil)
        valueLabel:self.nameValueLabel
        trailing:[self iconButtonWithSystemName:@"pencil" action:@selector(actionRename)]];

    // Group (like Prism's instance groups): dropdown with the existing groups and New Group…
    self.groupButton = [self dropdownButton];
    UIView *groupRow = [self rowWithTitle:localize(@"home.group.label", nil) valueLabel:nil trailing:self.groupButton];

    // Game version: gear opens the full profile editor, Update lets the user pick another version
    self.versionValueLabel = [UILabel new];
    UIButton *gear = [self iconButtonWithSystemName:@"gearshape" action:@selector(actionOpenProfileEditor)];
    gear.accessibilityLabel = localize(@"instance.version.settings", nil);

    UIButton *update = [UIButton buttonWithType:UIButtonTypeSystem];
    [update setTitle:localize(@"instance.version.update", nil) forState:UIControlStateNormal];
    update.titleLabel.font = LauncherTheme.buttonFont;
    update.tintColor = UIColor.labelColor;
    update.backgroundColor = UIColor.tertiarySystemFillColor;
    update.layer.cornerRadius = 10;
    update.contentEdgeInsets = UIEdgeInsetsMake(8, 18, 8, 18);
    [update addTarget:self action:@selector(actionOpenProfileEditor) forControlEvents:UIControlEventPrimaryActionTriggered];
    setButtonPointerInteraction(update);

    UIView *versionRow = [self rowWithTitle:localize(@"instance.version", nil)
        valueLabel:self.versionValueLabel
        trailing:[self trailingStackWithViews:@[gear, update]]];

    // Game directory
    self.gameDirValueLabel = [UILabel new];
    self.folderButton = [self iconButtonWithSystemName:@"folder" action:@selector(actionOpenFolderUnavailable)];
    self.folderButton.tintColor = UIColor.systemBlueColor;
    UIButton *editDir = [self iconButtonWithSystemName:@"pencil" action:@selector(actionEditGameDir)];
    UIView *dirRow = [self rowWithTitle:localize(@"instance.game_directory", nil)
        valueLabel:self.gameDirValueLabel
        trailing:[self trailingStackWithViews:@[self.folderButton, editDir]]];

    [self addGroupWithCaption:localize(@"instance.group.instance", nil) rows:@[nameRow, groupRow, versionRow, dirRow]];
}

- (UIView *)manageRowWithTitle:(NSString *)title hint:(NSString *)hintText action:(SEL)action {
    UIButton *browse = [UIButton buttonWithType:UIButtonTypeSystem];
    [browse setTitle:localize(@"mods.manage", nil) forState:UIControlStateNormal];
    browse.titleLabel.font = LauncherTheme.buttonFont;
    browse.tintColor = UIColor.labelColor;
    browse.backgroundColor = UIColor.tertiarySystemFillColor;
    browse.layer.cornerRadius = 10;
    browse.contentEdgeInsets = UIEdgeInsetsMake(8, 18, 8, 18);
    [browse addTarget:self action:action forControlEvents:UIControlEventPrimaryActionTriggered];
    setButtonPointerInteraction(browse);

    UILabel *hint = [UILabel new];
    hint.text = hintText;
    return [self rowWithTitle:title valueLabel:hint trailing:browse];
}

- (void)buildModsGroup {
    UIView *mods = [self manageRowWithTitle:localize(@"mods.manage.title", nil) hint:localize(@"mods.manage.hint", nil) action:@selector(actionBrowseMods)];
    UIView *packs = [self manageRowWithTitle:localize(@"packs.manage.title", nil) hint:localize(@"packs.manage.hint", nil) action:@selector(actionBrowseResourcePacks)];
    [self addGroupWithCaption:localize(@"instance.group.mods", nil) rows:@[mods, packs]];
}

- (void)buildDedicatedSettingsGroup {
    // RAM allocation
    self.ramSlider = [RamSlider new];
    self.ramSlider.minimumValue = kRamMinMB;
    self.ramSlider.maximumValue = MAX([self maxAllocatableMB], kRamMinMB + kRamStepMB);
    self.ramSlider.minimumTrackTintColor = LauncherTheme.accent;
    [self.ramSlider addTarget:self action:@selector(ramSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.ramSlider addTarget:self action:@selector(ramSliderCommitted:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    self.ramSlider.accessibilityLabel = localize(@"instance.ram", nil);

    self.ramValueLabel = [self labelWithFont:[UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightRegular] color:UIColor.secondaryLabelColor];
    self.ramValueLabel.textAlignment = NSTextAlignmentRight;
    self.ramValueLabel.numberOfLines = 1;
    [self.ramValueLabel.widthAnchor constraintEqualToConstant:100].active = YES;

    [self.ramSlider.widthAnchor constraintGreaterThanOrEqualToConstant:160].active = YES;
    UIStackView *ramTrailing = [self trailingStackWithViews:@[self.ramSlider, self.ramValueLabel]];
    [ramTrailing.widthAnchor constraintLessThanOrEqualToConstant:420].active = YES;
    UIView *ramRow = [self rowWithTitle:localize(@"instance.ram", nil) valueLabel:nil trailing:ramTrailing];

    // Java version dropdown
    self.javaButton = [self dropdownButton];
    UIView *javaRow = [self rowWithTitle:localize(@"instance.java_version", nil) valueLabel:nil trailing:self.javaButton];

    // Java arguments: shows the current value, tapping opens an editor window (empty = global ones from Settings)
    self.javaArgsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.javaArgsButton.tintColor = UIColor.labelColor;
    self.javaArgsButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.javaArgsButton.contentEdgeInsets = UIEdgeInsetsMake(8, 12, 8, 12);
    self.javaArgsButton.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.javaArgsButton.layer.cornerRadius = 10;
    self.javaArgsButton.layer.borderWidth = 1;
    self.javaArgsButton.layer.borderColor = UIColor.separatorColor.CGColor;
    self.javaArgsButton.accessibilityLabel = localize(@"instance.java_args", nil);
    [self.javaArgsButton addTarget:self action:@selector(actionEditJavaArgs) forControlEvents:UIControlEventPrimaryActionTriggered];
    setButtonPointerInteraction(self.javaArgsButton);
    NSLayoutConstraint *argsWidth = [self.javaArgsButton.widthAnchor constraintEqualToConstant:420];
    argsWidth.priority = UILayoutPriorityDefaultHigh;
    argsWidth.active = YES;
    [self.javaArgsButton.widthAnchor constraintGreaterThanOrEqualToConstant:200].active = YES;
    [self.javaArgsButton.heightAnchor constraintGreaterThanOrEqualToConstant:36].active = YES;
    UIView *argsRow = [self rowWithTitle:localize(@"instance.java_args", nil) valueLabel:nil trailing:self.javaArgsButton];

    [self addGroupWithCaption:localize(@"instance.group.dedicated", nil) rows:@[ramRow, javaRow, argsRow]];
}

- (UIButton *)dangerButtonWithTitleKey:(NSString *)key action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:localize(key, nil) forState:UIControlStateNormal];
    button.tintColor = UIColor.systemRedColor;
    button.titleLabel.font = LauncherTheme.buttonFont;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [button addTarget:self action:action forControlEvents:UIControlEventPrimaryActionTriggered];
    setButtonPointerInteraction(button);
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    return button;
}

- (void)buildDangerZone {
    self.deleteFilesButton = [self dangerButtonWithTitleKey:@"instance.delete.files" action:@selector(actionDeleteWithFiles)];
    [self.rightStack addArrangedSubview:self.deleteFilesButton];
}

#pragma mark - Reload

- (void)switchToProfileNamed:(NSString *)name {
    if (!PLProfiles.current.profiles[name]) return;
    self.profileName = name;
    [self reloadFromProfile];
}

- (void)reloadFromProfile {
    if (![self profile]) {
        // Renamed in the editor or deleted: follow whatever is selected now
        NSString *selected = PLProfiles.current.selectedProfileName;
        if (!PLProfiles.current.profiles[selected]) {
            selected = PLProfiles.current.profiles.allKeys.firstObject;
        }
        self.profileName = selected;
    }
    NSMutableDictionary *profile = [self profile];
    if (!profile || !self.isViewLoaded) return;

    self.headerLabel.text = self.profileName;
    self.title = localize(@"instance.dashboard.page", nil);
    self.nameValueLabel.text = self.profileName;

    UIImage *fallbackIcon = DefaultInstanceIcon();
    // An icon key (built-in or the user's own) loads locally; links and data: strings load as before
    [InstanceIcons setIconString:profile[@"icon"] onImageView:self.headerIconView placeholder:fallbackIcon];

    NSString *version = profile[@"lastVersionId"];
    self.versionValueLabel.text = version.length > 0 ? version : @"-";
    NSString *summary = [LauncherHomeViewController versionSummaryForProfile:profile];
    self.heroVersionLabel.text = summary.length > 0 ? [@"Minecraft " stringByAppendingString:summary] : @"-";
    [self updateHeroChips];

    NSString *gameDir = profile[@"gameDir"];
    self.gameDirValueLabel.text = gameDir.length > 0 ? gameDir : @".";
    [self updateFolderButton];

    CGFloat mb = MIN(MAX([self currentAllocationMB], kRamMinMB), self.ramSlider.maximumValue);
    self.ramSlider.value = mb;
    [self updateRamLabel];

    [self updateJavaMenu];
    [self updateGroupMenu];
    [self updateJavaArgsButton];
    BOOL canDelete = PLProfiles.current.profiles.count > 1; // the last instance stays
    self.deleteFilesButton.hidden = !canDelete;
}

- (void)updateRamLabel {
    CGFloat maxGB = ceil([self systemMemoryMB] / 1024.0);
    self.ramValueLabel.text = [NSString stringWithFormat:@"%@ / %dGB",
        [self formatMB:self.ramSlider.value], (int)maxGB];
}

- (void)updateJavaMenu {
    NSString *current = [self profile][@"javaVersion"];
    NSString *defaultTitle = localize(@"instance.java_version.automatic", nil);

    NSMutableArray<NSString *> *versions = [NSMutableArray new];
    for (NSString *key in [getPrefObject(@"java.java_homes") allKeys]) {
        if (![key isEqualToString:@"0"]) [versions addObject:key];
    }
    [versions sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [@(a.integerValue) compare:@(b.integerValue)];
    }];

    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIAction *> *actions = [NSMutableArray new];
    UIAction *auto_ = [UIAction actionWithTitle:defaultTitle image:nil identifier:nil handler:^(UIAction *action) {
        [weakSelf setJavaVersion:nil];
    }];
    auto_.state = current.length == 0 ? UIMenuElementStateOn : UIMenuElementStateOff;
    [actions addObject:auto_];
    for (NSString *version in versions) {
        UIAction *action = [UIAction actionWithTitle:[NSString stringWithFormat:@"Java %@", version]
            image:nil identifier:nil handler:^(UIAction *action) {
                [weakSelf setJavaVersion:version];
            }];
        action.state = [current isEqualToString:version] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    self.javaButton.menu = [UIMenu menuWithTitle:@"" children:actions];

    NSString *title = current.length > 0 ? [NSString stringWithFormat:@"Java %@", current] : defaultTitle;
    [self.javaButton setTitle:title forState:UIControlStateNormal];
}

- (void)updateGroupMenu {
    NSString *current = [InstanceGroups groupOfProfile:[self profile]];
    NSString *name = self.profileName;
    self.groupButton.menu = [UIMenu menuWithTitle:@"" children:[InstanceGroups pickerMenuElementsWithCurrent:current
        presenter:self onPick:^(NSString *group) {
            // The change notification reloads this page
            [InstanceGroups setGroup:group forInstances:@[name]];
        }]];
    [self.groupButton setTitle:(current ?: localize(@"home.group.none", nil)) forState:UIControlStateNormal];
}

- (void)updateFolderButton {
    NSDictionary *apps = @{
        @"shareddocuments": @"Files",
        @"filza": @"Filza",
        @"santander": @"Santander",
    };
    NSMutableArray<UIAction *> *openItems = [NSMutableArray new];
    __weak typeof(self) weakSelf = self;
    for (NSString *scheme in [apps.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if (![UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:[scheme stringByAppendingString:@"://"]]]) continue;
        [openItems addObject:[UIAction actionWithTitle:apps[scheme] image:nil identifier:nil handler:^(UIAction *action) {
            [weakSelf openGameDirInScheme:scheme];
        }]];
    }
    if (openItems.count > 0) {
        self.folderButton.menu = [UIMenu menuWithTitle:@"" children:openItems];
        self.folderButton.showsMenuAsPrimaryAction = YES;
    } else {
        self.folderButton.menu = nil;
        self.folderButton.showsMenuAsPrimaryAction = NO;
    }
    self.heroFolderButton.menu = self.folderButton.menu;
    self.heroFolderButton.showsMenuAsPrimaryAction = self.folderButton.showsMenuAsPrimaryAction;
}

#pragma mark - Actions

- (void)setJavaVersion:(NSString *)version {
    NSMutableDictionary *profile = [self profile];
    if (version.length > 0) {
        profile[@"javaVersion"] = version;
    } else {
        [profile removeObjectForKey:@"javaVersion"];
    }
    [self saveProfile];
    [self updateJavaMenu];
}

#pragma mark - Java arguments

- (void)updateJavaArgsButton {
    NSString *args = [self profile][@"javaArgs"];
    BOOL custom = args.length > 0;
    NSString *global = getPrefObject(@"java.java_args");
    NSString *title = custom ? args : (global.length > 0 ? global : localize(@"instance.java_args.default", nil));
    [self.javaArgsButton setTitle:title forState:UIControlStateNormal];
    // Greyed while the global arguments are in effect
    self.javaArgsButton.tintColor = custom ? UIColor.labelColor : UIColor.secondaryLabelColor;
}

- (void)actionEditJavaArgs {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"instance.java_args", nil)
        message:localize(@"instance.java_args.detail", nil)
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = [self profile][@"javaArgs"];
        NSString *global = getPrefObject(@"java.java_args");
        textField.placeholder = global.length > 0 ? global : localize(@"instance.java_args.default", nil);
        textField.font = LauncherTheme.monoFont;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.spellCheckingType = UITextSpellCheckingTypeNo;
        textField.smartDashesType = UITextSmartDashesTypeNo; // "--" must stay "--"
        textField.smartQuotesType = UITextSmartQuotesTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *args = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSMutableDictionary *profile = [self profile];
        if (args.length > 0) {
            profile[@"javaArgs"] = args;
        } else {
            [profile removeObjectForKey:@"javaArgs"];
        }
        [self saveProfile];
        [self updateJavaArgsButton];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)ramSliderChanged:(UISlider *)sender {
    sender.value = round(sender.value / kRamStepMB) * kRamStepMB;
    [self updateRamLabel];
}

- (void)ramSliderCommitted:(UISlider *)sender {
    CGFloat mb = MAX(round(sender.value / kRamStepMB) * kRamStepMB, kRamMinMB);
    [self profile][@"allocatedMemory"] = [NSString stringWithFormat:@"%d", (int)mb];
    [self saveProfile];
}

- (void)actionOpenProfileEditor {
    LauncherProfileEditorViewController *vc = [LauncherProfileEditorViewController new];
    vc.profile = [self profile].mutableCopy;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)actionBrowseMods {
    ModsManagerViewController *vc = [[ModsManagerViewController alloc]
        initWithVersionId:[self profile][@"lastVersionId"] gameDirPath:[self absoluteGameDirPath]];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)actionBrowseResourcePacks {
    ModsManagerViewController *vc = [[ModsManagerViewController alloc]
        initWithVersionId:[self profile][@"lastVersionId"] gameDirPath:[self absoluteGameDirPath] kind:ModContentKindResourcePacks];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)actionRename {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"instance.rename.title", nil)
        message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = self.profileName;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.autocapitalizationType = UITextAutocapitalizationTypeWords;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *newName = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        [self renameTo:newName];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)actionChangeIcon {
    NSMutableDictionary *profile = [self profile];
    if (!profile) return;
    NSString *current = [profile[@"icon"] isKindOfClass:NSString.class] ? profile[@"icon"] : nil;
    // Only a key can be highlighted in the picker; an instance that uses a download link starts with nothing selected
    LauncherIconPickerViewController *picker = [[LauncherIconPickerViewController alloc]
        initWithSelectedKey:[InstanceIcons isKeyReference:current] ? current : nil];
    __weak typeof(self) weakSelf = self;
    picker.completion = ^(NSString *key) {
        [weakSelf applyIconKey:key];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:picker];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    nav.preferredContentSize = CGSizeMake(720, 660);
    [LauncherTheme applyBarBackground:LauncherTheme.chromeBackground toNavigationController:nav];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)applyIconKey:(NSString *)key {
    NSMutableDictionary *profile = [self profile];
    if (!profile || key.length == 0) return;
    // launcher_profiles.json is edited by hand and by other tools: the old value may be null, a number or a list
    id previous = profile[@"icon"];
    if ([previous isKindOfClass:NSString.class] && [previous isEqualToString:key]) return;
    profile[@"icon"] = key;
    if (![PLProfiles.current save]) {
        if (previous) profile[@"icon"] = previous; else [profile removeObjectForKey:@"icon"];
        return;
    }
    // The dashboard and the instance lists observe this and reload
    [NSNotificationCenter.defaultCenter postNotificationName:PLProfilesDidChangeNotification object:self];
}

- (void)renameTo:(NSString *)newName {
    if (newName.length == 0 || [newName isEqualToString:self.profileName]) return;
    if (PLProfiles.current.profiles[newName]) {
        showDialog(localize(@"Error", nil), localize(@"profile.error.name_exists", nil));
        return;
    }
    NSMutableDictionary *profile = [self profile];
    NSString *oldName = self.profileName;
    BOOL wasSelected = [PLProfiles.current.selectedProfileName isEqualToString:self.profileName];
    [PLProfiles.current.profiles removeObjectForKey:self.profileName];
    profile[@"name"] = newName;
    PLProfiles.current.profiles[newName] = profile;
    self.profileName = newName;
    if (wasSelected) {
        PLProfiles.current.profileDict[@"selectedProfile"] = newName;
    }
    if (![PLProfiles.current save]) {
        [PLProfiles.current.profiles removeObjectForKey:newName];
        profile[@"name"] = oldName;
        PLProfiles.current.profiles[oldName] = profile;
        self.profileName = oldName;
        if (wasSelected) PLProfiles.current.profileDict[@"selectedProfile"] = oldName;
        return;
    }
    [NSNotificationCenter.defaultCenter postNotificationName:PLProfilesDidChangeNotification object:self];
}

- (void)actionEditGameDir {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"instance.game_directory", nil)
        message:localize(@"instance.game_directory.detail", nil)
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = [PLProfiles instanceFolderNameForGameDir:[self profile][@"gameDir"]] ?: [self profile][@"gameDir"];
        textField.placeholder = self.profileName;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *text = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        // A single folder name: every instance stays directly inside the instances folder
        if (text.length == 0 || [text isEqualToString:@"."] || [text containsString:@".."] || [text containsString:@"/"]) {
            showDialog(localize(@"Error", nil), localize(@"instance.game_directory.invalid", nil));
            return;
        }
        NSMutableDictionary *profile = [self profile];
        profile[@"gameDir"] = [PLProfiles isolatedGameDirForName:text];
        [self saveProfile];
        [self reloadFromProfile];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)actionOpenFolderUnavailable {
    // Only reachable when no supported file manager app is installed (otherwise the button shows a menu)
    showDialog(localize(@"Error", nil), localize(@"instance.folder.no_app", nil));
}

- (void)openGameDirInScheme:(NSString *)scheme {
    NSString *path = [self absoluteGameDirPath];
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@", scheme, path]];
    if (!url) {
        // Instance names may contain characters that are not valid in a URL as is
        NSString *escaped = [path stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
        url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@", scheme, escaped]];
    }
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

/// The instance's folder inside Documents/instances, or nil when it must not be deleted: anything that is not
/// exactly one folder directly inside instances (such as the shared game_data folder ".") or a folder another
/// instance also uses. Resolve aliases as well so a legacy/shared folder can't be deleted through another spelling.
- (NSString *)deletableGameDirPath {
    NSString *gameDir = [self profile][@"gameDir"];
    NSString *folderName = [PLProfiles instanceFolderNameForGameDir:gameDir];
    if (!folderName) return nil;
    NSString *path = [[PLProfiles absolutePathForGameDir:gameDir] stringByResolvingSymlinksInPath].precomposedStringWithCanonicalMapping.lowercaseString;
    NSString *instances = [PLProfiles.instancesDirectory stringByResolvingSymlinksInPath].precomposedStringWithCanonicalMapping.lowercaseString;
    NSString *shared = [@(getenv("GAME_DIR")) stringByResolvingSymlinksInPath].precomposedStringWithCanonicalMapping.lowercaseString;
    if (![path.stringByDeletingLastPathComponent isEqualToString:instances] || [path isEqualToString:shared]) return nil;
    for (NSString *name in PLProfiles.current.profiles) {
        if ([name isEqualToString:self.profileName]) continue;
        NSString *other = [[PLProfiles absolutePathForGameDir:PLProfiles.current.profiles[name][@"gameDir"]]
            stringByResolvingSymlinksInPath].precomposedStringWithCanonicalMapping.lowercaseString;
        if ([other isEqualToString:path] || [other hasPrefix:[path stringByAppendingString:@"/"]]) {
            return nil;
        }
    }
    return [[PLProfiles instancesDirectory] stringByAppendingPathComponent:folderName];
}

- (void)actionDeleteWithFiles {
    if (![self deletableGameDirPath]) {
        showDialog(localize(@"Error", nil), localize(@"instance.delete.files.shared", nil));
        return;
    }
    [self confirmDeleteWithMessage:[NSString stringWithFormat:localize(@"instance.delete.files.confirm", nil), self.profileName]
        buttonKey:@"instance.delete.files"];
}

- (void)confirmDeleteWithMessage:(NSString *)message buttonKey:(NSString *)buttonKey {
    NSString *confirmedName = self.profileName;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"preference.title.confirm", nil)
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(buttonKey, nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        if (![self.profileName isEqualToString:confirmedName]) return;
        [self deleteInstanceAndFiles];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)deleteInstanceAndFiles {
    PLProfiles *profiles = PLProfiles.current;
    if (self.profileName.length == 0 || profiles.profiles.count <= 1 || !profiles.profiles[self.profileName]) return;
    // Work out the folder before the profile (and with it, its gameDir) is gone
    NSString *folder = [self deletableGameDirPath];
    if (!folder) return;

    NSString *name = self.profileName;
    NSMutableDictionary *removedProfile = profiles.profiles[name];
    NSString *previousSelection = profiles.selectedProfileName;
    NSString *stagedFolder;
    if (folder && [NSFileManager.defaultManager fileExistsAtPath:folder]) {
        // Detach this directory before releasing its name. Background cleanup must
        // never delete a new instance created at the original path.
        stagedFolder = [[PLProfiles instancesDirectory] stringByAppendingPathComponent:
            [@".deleted-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSError *error;
        if (![NSFileManager.defaultManager moveItemAtPath:folder toPath:stagedFolder error:&error]) {
            showDialog(localize(@"Error", nil), error.localizedDescription);
            return;
        }
    }
    [profiles.profiles removeObjectForKey:name];
    if ([profiles.selectedProfileName isEqualToString:name]) {
        profiles.profileDict[@"selectedProfile"] = profiles.profiles.allKeys.firstObject;
    }
    if (![profiles save]) {
        profiles.profiles[name] = removedProfile;
        profiles.profileDict[@"selectedProfile"] = previousSelection;
        if (stagedFolder) {
            NSError *error;
            if (![NSFileManager.defaultManager moveItemAtPath:stagedFolder toPath:folder error:&error]) {
                showDialog(localize(@"Error", nil), [NSString stringWithFormat:@"Instance files remain at %@: %@", stagedFolder, error.localizedDescription]);
            }
        }
        return;
    }
    self.profileName = profiles.selectedProfileName;
    [NSNotificationCenter.defaultCenter postNotificationName:PLProfilesDidChangeNotification object:self];
    // Opened from the home grid: the deleted instance's page goes away
    if (self.navigationController.viewControllers.count > 1 && self.navigationController.topViewController == self) {
        [self.navigationController popViewControllerAnimated:YES];
    }

    if (stagedFolder) {
        // Worlds and mods can be gigabytes; keep the UI responsive
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSError *error;
            if (![NSFileManager.defaultManager removeItemAtPath:stagedFolder error:&error] && error.code != NSFileNoSuchFileError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    showDialog(localize(@"Error", nil), [NSString stringWithFormat:localize(@"instance.delete.files.failed", nil), error.localizedDescription]);
                });
            }
        });
    }
}

@end
