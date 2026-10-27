#import "LauncherInstanceDashboardViewController.h"
#import "LauncherPreferences.h"
#import "LauncherProfileEditorViewController.h"
#import "PLProfiles.h"
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

@property(nonatomic) UILabel *headerLabel;
@property(nonatomic) UILabel *nameValueLabel;
@property(nonatomic) UILabel *versionValueLabel;
@property(nonatomic) UILabel *gameDirValueLabel;
@property(nonatomic) UIButton *folderButton;

@property(nonatomic) UISlider *ramSlider;
@property(nonatomic) UILabel *ramValueLabel;
@property(nonatomic) UIButton *javaButton;
@property(nonatomic) UISwitch *isolationSwitch;
@property(nonatomic) UIButton *deleteButton;
@end

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
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UIScrollView *scrollView = [UIScrollView new];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = YES;
    scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scrollView];

    self.contentStack = [UIStackView new];
    self.contentStack.axis = UILayoutConstraintAxisVertical;
    self.contentStack.spacing = 8;
    self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:self.contentStack];

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
    [self buildInstanceSettingsGroup];
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

- (BOOL)isIsolated {
    NSString *gameDir = [self profile][@"gameDir"];
    return gameDir.length > 0 && ![gameDir isEqualToString:@"."];
}

- (NSString *)isolatedGameDirForName:(NSString *)name {
    NSMutableCharacterSet *bad = [NSMutableCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|"];
    [bad formUnionWithCharacterSet:NSCharacterSet.controlCharacterSet];
    NSString *safe = [[name componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"-"];
    safe = [safe stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while ([safe hasPrefix:@"."]) {
        safe = [safe substringFromIndex:1];
    }
    if (safe.length == 0) {
        safe = @"instance";
    }
    return [NSString stringWithFormat:@"./custom_gamedir/%@", safe];
}

- (NSString *)absoluteGameDirPath {
    NSString *gameDir = [self profile][@"gameDir"];
    if (gameDir.length == 0) gameDir = @".";
    return [NSString stringWithFormat:@"%s/instances/%@/%@",
        getenv("AME_HOME"), getPrefObject(@"general.game_directory"), gameDir]
        .stringByStandardizingPath;
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
    UILabel *label = [self labelWithFont:[UIFont systemFontOfSize:13 weight:UIFontWeightMedium] color:UIColor.secondaryLabelColor];
    label.text = text.uppercaseString;
    return label;
}

/// Rounded container that stacks rows with hairline separators between them.
- (UIView *)cardWithRows:(NSArray<UIView *> *)rows {
    UIView *card = [UIView new];
    card.backgroundColor = UIColor.secondarySystemBackgroundColor;
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
            separator.backgroundColor = UIColor.separatorColor;
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

    UILabel *titleLabel = [self labelWithFont:[UIFont systemFontOfSize:17] color:UIColor.labelColor];
    titleLabel.text = title;

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel]];
    if (valueLabel) {
        valueLabel.font = [UIFont systemFontOfSize:16];
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

- (UIStackView *)trailingStackWithViews:(NSArray<UIView *> *)views {
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:views];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 10;
    return stack;
}

- (void)addGroupWithCaption:(NSString *)caption rows:(NSArray<UIView *> *)rows {
    UILabel *captionLabel = [self sectionCaption:caption];
    [self.contentStack addArrangedSubview:captionLabel];
    [self.contentStack setCustomSpacing:8 afterView:captionLabel];
    UIView *card = [self cardWithRows:rows];
    [self.contentStack addArrangedSubview:card];
    [self.contentStack setCustomSpacing:28 afterView:card];
}

- (void)buildHeader {
    self.headerLabel = [self labelWithFont:[UIFont systemFontOfSize:34 weight:UIFontWeightBold] color:UIColor.labelColor];
    self.headerLabel.numberOfLines = 2;
    self.headerLabel.adjustsFontSizeToFitWidth = YES;
    self.headerLabel.minimumScaleFactor = 0.6;

    UIButton *edit = [self iconButtonWithSystemName:@"pencil" action:@selector(actionRename)];
    edit.accessibilityLabel = localize(@"Rename", nil);
    [edit setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIView *spacer = [UIView new];
    [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow - 1 forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[self.headerLabel, edit, spacer]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 8;
    [self.contentStack addArrangedSubview:header];
    [self.contentStack setCustomSpacing:20 afterView:header];
}

- (void)buildInstanceSettingsGroup {
    // Instance name
    self.nameValueLabel = [UILabel new];
    UIView *nameRow = [self rowWithTitle:localize(@"instance.name", nil)
        valueLabel:self.nameValueLabel
        trailing:[self iconButtonWithSystemName:@"pencil" action:@selector(actionRename)]];

    // Game version: gear opens the full profile editor, Update lets the user pick another version
    self.versionValueLabel = [UILabel new];
    UIButton *gear = [self iconButtonWithSystemName:@"gearshape" action:@selector(actionOpenProfileEditor)];
    gear.accessibilityLabel = localize(@"instance.version.settings", nil);

    UIButton *update = [UIButton buttonWithType:UIButtonTypeSystem];
    [update setTitle:localize(@"instance.version.update", nil) forState:UIControlStateNormal];
    update.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
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

    [self addGroupWithCaption:localize(@"instance.group.instance", nil) rows:@[nameRow, versionRow, dirRow]];
}

- (void)buildDedicatedSettingsGroup {
    // RAM allocation
    self.ramSlider = [UISlider new];
    self.ramSlider.minimumValue = kRamMinMB;
    self.ramSlider.maximumValue = MAX([self maxAllocatableMB], kRamMinMB + kRamStepMB);
    self.ramSlider.minimumTrackTintColor = [UIColor colorWithRed:121/255.0 green:56/255.0 blue:162/255.0 alpha:1.0];
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
    self.javaButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.javaButton.showsMenuAsPrimaryAction = YES;
    self.javaButton.tintColor = UIColor.labelColor;
    self.javaButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.javaButton.contentEdgeInsets = UIEdgeInsetsMake(8, 12, 8, 36);
    self.javaButton.layer.cornerRadius = 10;
    self.javaButton.layer.borderWidth = 1;
    self.javaButton.layer.borderColor = UIColor.separatorColor.CGColor;
    [self.javaButton.widthAnchor constraintEqualToConstant:260].active = YES;
    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.down"]];
    chevron.tintColor = UIColor.secondaryLabelColor;
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.userInteractionEnabled = NO;
    [self.javaButton addSubview:chevron];
    [NSLayoutConstraint activateConstraints:@[
        [chevron.trailingAnchor constraintEqualToAnchor:self.javaButton.trailingAnchor constant:-12],
        [chevron.centerYAnchor constraintEqualToAnchor:self.javaButton.centerYAnchor],
    ]];
    UIView *javaRow = [self rowWithTitle:localize(@"instance.java_version", nil) valueLabel:nil trailing:self.javaButton];

    // Instance isolation: switch shares a line with the title, explanation sits underneath
    UIView *isolationRow = [self isolationRow];

    [self addGroupWithCaption:localize(@"instance.group.dedicated", nil) rows:@[ramRow, javaRow, isolationRow]];
}

- (UIView *)isolationRow {
    UIView *row = [UIView new];
    [row.heightAnchor constraintGreaterThanOrEqualToConstant:kRowMinHeight].active = YES;

    UILabel *title = [self labelWithFont:[UIFont systemFontOfSize:17] color:UIColor.labelColor];
    title.text = localize(@"instance.isolation", nil);
    UILabel *detail = [self labelWithFont:[UIFont systemFontOfSize:13] color:UIColor.secondaryLabelColor];
    detail.text = localize(@"instance.isolation.detail", nil);

    self.isolationSwitch = [UISwitch new];
    [self.isolationSwitch addTarget:self action:@selector(isolationToggled:) forControlEvents:UIControlEventValueChanged];
    self.isolationSwitch.accessibilityLabel = title.text;

    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[title, self.isolationSwitch]];
    top.axis = UILayoutConstraintAxisHorizontal;
    top.alignment = UIStackViewAlignmentCenter;
    top.spacing = 12;
    [self.isolationSwitch setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[top, detail]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 4;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:row.topAnchor constant:12],
        [stack.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-12],
        [stack.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:kRowInset],
        [stack.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-kRowInset],
    ]];
    return row;
}

- (void)buildDangerZone {
    self.deleteButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.deleteButton setTitle:localize(@"instance.delete", nil) forState:UIControlStateNormal];
    self.deleteButton.tintColor = UIColor.systemRedColor;
    self.deleteButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    self.deleteButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [self.deleteButton addTarget:self action:@selector(actionDelete) forControlEvents:UIControlEventPrimaryActionTriggered];
    setButtonPointerInteraction(self.deleteButton);
    [self.contentStack addArrangedSubview:self.deleteButton];
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

    self.headerLabel.text = [NSString stringWithFormat:localize(@"instance.dashboard.title", nil), self.profileName];
    self.nameValueLabel.text = self.profileName;

    NSString *version = profile[@"lastVersionId"];
    self.versionValueLabel.text = version.length > 0 ? version : @"-";

    NSString *gameDir = profile[@"gameDir"];
    self.gameDirValueLabel.text = gameDir.length > 0 ? gameDir : @".";
    [self updateFolderButton];

    CGFloat mb = MIN(MAX([self currentAllocationMB], kRamMinMB), self.ramSlider.maximumValue);
    self.ramSlider.value = mb;
    [self updateRamLabel];

    [self.isolationSwitch setOn:[self isIsolated] animated:NO];
    [self updateJavaMenu];
    self.deleteButton.hidden = PLProfiles.current.profiles.count <= 1;
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

- (void)ramSliderChanged:(UISlider *)sender {
    sender.value = round(sender.value / kRamStepMB) * kRamStepMB;
    [self updateRamLabel];
}

- (void)ramSliderCommitted:(UISlider *)sender {
    CGFloat mb = MAX(round(sender.value / kRamStepMB) * kRamStepMB, kRamMinMB);
    [self profile][@"allocatedMemory"] = [NSString stringWithFormat:@"%d", (int)mb];
    [self saveProfile];
}

- (void)isolationToggled:(UISwitch *)sender {
    NSMutableDictionary *profile = [self profile];
    if (sender.isOn) {
        profile[@"gameDir"] = [self isolatedGameDirForName:self.profileName];
    } else {
        [profile removeObjectForKey:@"gameDir"];
    }
    [self saveProfile];
    self.gameDirValueLabel.text = profile[@"gameDir"] ?: @".";
}

- (void)actionOpenProfileEditor {
    LauncherProfileEditorViewController *vc = [LauncherProfileEditorViewController new];
    vc.profile = [self profile].mutableCopy;
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
        textField.autocapitalizationType = UIAutocapitalizationTypeWords;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *newName = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        [self renameTo:newName];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)renameTo:(NSString *)newName {
    if (newName.length == 0 || [newName isEqualToString:self.profileName]) return;
    if (PLProfiles.current.profiles[newName]) {
        showDialog(localize(@"Error", nil), localize(@"profile.error.name_exists", nil));
        return;
    }
    NSMutableDictionary *profile = [self profile];
    BOOL wasSelected = [PLProfiles.current.selectedProfileName isEqualToString:self.profileName];
    [PLProfiles.current.profiles removeObjectForKey:self.profileName];
    profile[@"name"] = newName;
    PLProfiles.current.profiles[newName] = profile;
    self.profileName = newName;
    if (wasSelected) {
        PLProfiles.current.selectedProfileName = newName; // saves
    } else {
        [self saveProfile];
    }
    [NSNotificationCenter.defaultCenter postNotificationName:PLProfilesDidChangeNotification object:self];
}

- (void)actionEditGameDir {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"instance.game_directory", nil)
        message:localize(@"instance.game_directory.detail", nil)
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = [self profile][@"gameDir"] ?: @".";
        textField.placeholder = @".";
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.autocapitalizationType = UIAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *text = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([text containsString:@".."] || [text hasPrefix:@"/"]) {
            // Keep every instance inside the instances folder
            showDialog(localize(@"Error", nil), localize(@"instance.game_directory.invalid", nil));
            return;
        }
        NSMutableDictionary *profile = [self profile];
        if (text.length == 0 || [text isEqualToString:@"."]) {
            [profile removeObjectForKey:@"gameDir"];
        } else {
            profile[@"gameDir"] = text;
        }
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

- (void)actionDelete {
    NSString *name = self.profileName;
    NSString *message = [NSString stringWithFormat:localize(@"instance.delete.confirm", nil), name];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"preference.title.confirm", nil)
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"instance.delete", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        PLProfiles *profiles = PLProfiles.current;
        if (profiles.profiles.count <= 1) return;
        [profiles.profiles removeObjectForKey:name];
        if ([profiles.selectedProfileName isEqualToString:name]) {
            profiles.selectedProfileName = profiles.profiles.allKeys.firstObject; // saves
        } else {
            [profiles save];
        }
        self.profileName = profiles.selectedProfileName;
        [NSNotificationCenter.defaultCenter postNotificationName:PLProfilesDidChangeNotification object:self];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
