#import "LauncherInstanceDashboardViewController.h"
#import "LauncherPreferences.h"
#import "LauncherTheme.h"
#import "LauncherProfileEditorViewController.h"
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
@property(nonatomic) UIButton *javaArgsButton;
@property(nonatomic) UIButton *deleteKeepButton, *deleteFilesButton;
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
    [self buildPanel];
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

/// One large rounded panel holds all settings groups, like the design concept
- (void)buildPanel {
    UIView *panel = [UIView new];
    panel.backgroundColor = LauncherTheme.panelBackground;
    panel.layer.cornerRadius = 18;
    panel.layer.borderWidth = 1;
    panel.layer.borderColor = LauncherTheme.separator.CGColor;

    self.panelStack = [UIStackView new];
    self.panelStack.axis = UILayoutConstraintAxisVertical;
    self.panelStack.spacing = 8;
    self.panelStack.layoutMarginsRelativeArrangement = YES;
    self.panelStack.layoutMargins = UIEdgeInsetsMake(16, 12, 16, 12);
    self.panelStack.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:self.panelStack];
    [NSLayoutConstraint activateConstraints:@[
        [self.panelStack.topAnchor constraintEqualToAnchor:panel.topAnchor],
        [self.panelStack.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor],
        [self.panelStack.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor],
        [self.panelStack.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],
    ]];
    [self.contentStack addArrangedSubview:panel];
    [self.contentStack setCustomSpacing:28 afterView:panel];
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
    self.headerLabel = [self labelWithFont:[UIFont systemFontOfSize:34 weight:UIFontWeightBold] color:UIColor.labelColor];
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
    self.headerIconView.layer.cornerRadius = 8;
    self.headerIconView.clipsToBounds = YES;
    self.headerIconView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.headerIconView setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.headerIconView setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [NSLayoutConstraint activateConstraints:@[
        [self.headerIconView.widthAnchor constraintEqualToConstant:44],
        [self.headerIconView.heightAnchor constraintEqualToConstant:44],
    ]];

    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[self.headerIconView, self.headerLabel, edit, spacer]];
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
    button.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [button addTarget:self action:action forControlEvents:UIControlEventPrimaryActionTriggered];
    setButtonPointerInteraction(button);
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    return button;
}

- (void)buildDangerZone {
    self.deleteKeepButton = [self dangerButtonWithTitleKey:@"instance.delete.keep" action:@selector(actionDeleteKeepFiles)];
    self.deleteFilesButton = [self dangerButtonWithTitleKey:@"instance.delete.files" action:@selector(actionDeleteWithFiles)];
    [self.contentStack addArrangedSubview:self.deleteKeepButton];
    [self.contentStack addArrangedSubview:self.deleteFilesButton];
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

    UIImage *fallbackIcon = DefaultInstanceIcon();
    NSString *iconString = profile[@"icon"];
    NSURL *iconURL = [iconString isKindOfClass:NSString.class] ? [NSURL URLWithString:iconString] : nil;
    self.headerIconView.image = fallbackIcon;
    if (iconURL) {
        [self.headerIconView setImageWithURL:iconURL placeholderImage:fallbackIcon];
    }

    NSString *version = profile[@"lastVersionId"];
    self.versionValueLabel.text = version.length > 0 ? version : @"-";

    NSString *gameDir = profile[@"gameDir"];
    self.gameDirValueLabel.text = gameDir.length > 0 ? gameDir : @".";
    [self updateFolderButton];

    CGFloat mb = MIN(MAX([self currentAllocationMB], kRamMinMB), self.ramSlider.maximumValue);
    self.ramSlider.value = mb;
    [self updateRamLabel];

    [self updateJavaMenu];
    BOOL canDelete = PLProfiles.current.profiles.count > 1; // the last instance stays
    self.deleteKeepButton.hidden = self.deleteFilesButton.hidden = !canDelete;
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
        textField.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
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
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
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

/// The instance's folder inside ./custom_gamedir/ (e.g. "./custom_gamedir/Fabric 26.3"), or nil when it must not be
/// deleted: anything that is not exactly one folder directly inside custom_gamedir (such as the shared default
/// folder ".") or a folder another instance also uses. Plain string checks on purpose; the folder may not exist yet.
- (NSString *)deletableGameDirPath {
    static NSString * const prefix = @"./custom_gamedir/";
    NSString *gameDir = [self profile][@"gameDir"];
    if (![gameDir hasPrefix:prefix]) return nil;
    NSString *folderName = [gameDir substringFromIndex:prefix.length];
    if (folderName.length == 0 || [folderName isEqualToString:@"."] || [folderName isEqualToString:@".."] ||
        [folderName containsString:@"/"]) {
        return nil;
    }
    for (NSString *name in PLProfiles.current.profiles) {
        if (![name isEqualToString:self.profileName] &&
            [PLProfiles.current.profiles[name][@"gameDir"] isEqualToString:gameDir]) {
            return nil;
        }
    }
    NSString *root = [NSString stringWithFormat:@"%s/instances/%@", getenv("AME_HOME"), getPrefObject(@"general.game_directory")];
    return [[root stringByAppendingPathComponent:@"custom_gamedir"] stringByAppendingPathComponent:folderName];
}

- (void)actionDeleteKeepFiles {
    [self confirmDeleteWithMessage:[NSString stringWithFormat:localize(@"instance.delete.keep.confirm", nil), self.profileName]
        buttonKey:@"instance.delete.keep" deleteFiles:NO];
}

- (void)actionDeleteWithFiles {
    if (![self deletableGameDirPath]) {
        showDialog(localize(@"Error", nil), localize(@"instance.delete.files.shared", nil));
        return;
    }
    [self confirmDeleteWithMessage:[NSString stringWithFormat:localize(@"instance.delete.files.confirm", nil), self.profileName]
        buttonKey:@"instance.delete.files" deleteFiles:YES];
}

- (void)confirmDeleteWithMessage:(NSString *)message buttonKey:(NSString *)buttonKey deleteFiles:(BOOL)deleteFiles {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"preference.title.confirm", nil)
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(buttonKey, nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self deleteInstanceDeletingFiles:deleteFiles];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)deleteInstanceDeletingFiles:(BOOL)deleteFiles {
    PLProfiles *profiles = PLProfiles.current;
    if (profiles.profiles.count <= 1) return;
    // Work out the folder before the profile (and with it, its gameDir) is gone
    NSString *folder = deleteFiles ? [self deletableGameDirPath] : nil;
    if (deleteFiles && !folder) return;

    NSString *name = self.profileName;
    [profiles.profiles removeObjectForKey:name];
    if ([profiles.selectedProfileName isEqualToString:name]) {
        profiles.selectedProfileName = profiles.profiles.allKeys.firstObject; // saves
    } else {
        [profiles save];
    }
    self.profileName = profiles.selectedProfileName;
    [NSNotificationCenter.defaultCenter postNotificationName:PLProfilesDidChangeNotification object:self];

    if (folder) {
        // Worlds and mods can be gigabytes; keep the UI responsive
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSError *error;
            if (![NSFileManager.defaultManager removeItemAtPath:folder error:&error] && error.code != NSFileNoSuchFileError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    showDialog(localize(@"Error", nil), [NSString stringWithFormat:localize(@"instance.delete.files.failed", nil), error.localizedDescription]);
                });
            }
        });
    }
}

@end
