#import "LauncherInstallPopoverViewController.h"
#import "DownloadProgressViewController.h"
#import "InstanceIcons.h"
#import "LauncherInstallStatus.h"
#import "LauncherTheme.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"
#import "utils.h"

static const CGFloat kPanelWidth = 480;
static const NSUInteger kMaxFilesInFlight = 4;

#pragma mark - Steps row

/// Pack ✓ — Extract ✓ — Files ◉ — Ready ○
@interface LauncherInstallStepsView : UIView
- (void)setPhases:(NSArray<NSNumber *> *)phases current:(LauncherInstallPhase)current kind:(LauncherInstallKind)kind;
@end

@interface LauncherInstallStepsView ()
@property(nonatomic) NSMutableArray<UIView *> *circles, *lines;
@property(nonatomic) NSMutableArray<UILabel *> *labels;
@property(nonatomic) NSMutableArray<UIImageView *> *checks;
@property(nonatomic) NSMutableArray<UIView *> *dots;
@end

@implementation LauncherInstallStepsView

static const CGFloat kStepCircle = 24;

- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric, kStepCircle + 26);
}

- (void)setPhases:(NSArray<NSNumber *> *)phases current:(LauncherInstallPhase)current kind:(LauncherInstallKind)kind {
    if (self.circles.count != phases.count) {
        for (UIView *view in self.subviews.copy) [view removeFromSuperview];
        self.circles = [NSMutableArray new];
        self.lines = [NSMutableArray new];
        self.labels = [NSMutableArray new];
        self.checks = [NSMutableArray new];
        self.dots = [NSMutableArray new];
        for (NSUInteger i = 0; i < phases.count; i++) {
            if (i > 0) {
                UIView *line = [UIView new];
                [self addSubview:line];
                [self.lines addObject:line];
            }
            UIView *circle = [UIView new];
            circle.layer.cornerRadius = kStepCircle / 2;
            circle.layer.borderWidth = 2;
            UIImageView *check = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"
                withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightBold]]];
            check.tintColor = UIColor.whiteColor;
            check.contentMode = UIViewContentModeCenter;
            check.frame = CGRectMake(0, 0, kStepCircle, kStepCircle);
            [circle addSubview:check];
            UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(kStepCircle / 2 - 5, kStepCircle / 2 - 5, 10, 10)];
            dot.layer.cornerRadius = 5;
            [circle addSubview:dot];
            UILabel *label = [UILabel new];
            label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
            label.textAlignment = NSTextAlignmentCenter;
            [self addSubview:circle];
            [self addSubview:label];
            [self.circles addObject:circle];
            [self.checks addObject:check];
            [self.dots addObject:dot];
            [self.labels addObject:label];
        }
    }
    UIColor *accent = LauncherTheme.accentText;
    UIColor *muted = [UIColor colorWithWhite:1 alpha:0.3];
    for (NSUInteger i = 0; i < phases.count; i++) {
        LauncherInstallPhase phase = phases[i].integerValue;
        BOOL done = phase < current, isCurrent = phase == current;
        UIView *circle = self.circles[i];
        circle.backgroundColor = done ? LauncherTheme.accent : UIColor.clearColor;
        circle.layer.borderColor = (done || isCurrent ? accent : muted).CGColor;
        self.checks[i].hidden = !done;
        self.dots[i].hidden = !isCurrent;
        self.dots[i].backgroundColor = accent;
        self.labels[i].text = [LauncherInstallStatus nameOfPhase:phase kind:kind];
        self.labels[i].textColor = isCurrent ? accent : [UIColor colorWithWhite:1 alpha:done ? 0.85 : 0.5];
        if (i > 0) self.lines[i - 1].backgroundColor = phase <= current ? LauncherTheme.accent : muted;
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    NSUInteger count = self.circles.count;
    if (count == 0) return;
    // The outer circles sit far enough in for their labels to fit
    CGFloat inset = 30, width = self.bounds.size.width;
    CGFloat step = count > 1 ? (width - 2 * inset) / (count - 1) : 0;
    for (NSUInteger i = 0; i < count; i++) {
        CGFloat x = count > 1 ? inset + step * i : width / 2;
        self.circles[i].frame = CGRectMake(x - kStepCircle / 2, 0, kStepCircle, kStepCircle);
        self.labels[i].frame = CGRectMake(x - 50, kStepCircle + 6, 100, 20);
        if (i > 0) {
            CGFloat previous = inset + step * (i - 1);
            self.lines[i - 1].frame = CGRectMake(previous + kStepCircle / 2 + 4, kStepCircle / 2 - 1,
                step - kStepCircle - 8, 2);
        }
    }
}

@end

#pragma mark - File row

@interface LauncherInstallFileRow : UIView
@property(nonatomic) UILabel *nameLabel, *percentLabel;
@property(nonatomic) UIProgressView *bar;
@end

@implementation LauncherInstallFileRow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    self.nameLabel = [UILabel new];
    self.nameLabel.font = [UIFont systemFontOfSize:14];
    self.nameLabel.textColor = [UIColor colorWithWhite:1 alpha:0.9];
    self.nameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.percentLabel = [UILabel new];
    self.percentLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.percentLabel.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    self.percentLabel.textAlignment = NSTextAlignmentRight;
    self.bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    self.bar.progressTintColor = [UIColor colorWithWhite:1 alpha:0.75];
    self.bar.trackTintColor = [UIColor colorWithWhite:1 alpha:0.15];
    for (UIView *view in @[self.nameLabel, self.bar, self.percentLabel]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [self.heightAnchor constraintEqualToConstant:30],
        [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.nameLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.bar.leadingAnchor constant:-12],
        [self.bar.widthAnchor constraintEqualToConstant:76],
        [self.bar.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.bar.trailingAnchor constraintEqualToAnchor:self.percentLabel.leadingAnchor constant:-10],
        [self.percentLabel.widthAnchor constraintEqualToConstant:40],
        [self.percentLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.percentLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
    return self;
}

@end

#pragma mark - Panel

@interface LauncherInstallPopoverViewController ()
@property(nonatomic, weak) MinecraftResourceDownloadTask *task;
@property(nonatomic) UIImageView *iconView;
@property(nonatomic, copy) NSString *shownIconString;
@property(nonatomic) UILabel *titleTextLabel, *subtitleLabel, *phaseLabel, *countLabel, *transferLabel, *footnoteLabel;
@property(nonatomic) UIButton *cancelButton, *allFilesButton;
@property(nonatomic) LauncherInstallStepsView *stepsView;
@property(nonatomic) UIProgressView *phaseBar;
@property(nonatomic) UIActivityIndicatorView *spinner;
@property(nonatomic) UIStackView *filesStack;
@property(nonatomic) UIView *filesBox;
@property(nonatomic) NSMutableArray<LauncherInstallFileRow *> *fileRows;
@property(nonatomic) UIStackView *mainStack;
@end

@implementation LauncherInstallPopoverViewController

- (instancetype)initWithTask:(MinecraftResourceDownloadTask *)task {
    self = [super init];
    self.task = task;
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (UILabel *)labelWithFont:(UIFont *)font color:(UIColor *)color {
    UILabel *label = [UILabel new];
    label.font = font;
    label.textColor = color;
    return label;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = LauncherTheme.panelBackground;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    UIColor *secondary = [UIColor colorWithWhite:1 alpha:0.6];

    // Header: icon, name, "v2.9.3 · 1.12.2 · from CurseForge", Cancel
    self.iconView = [UIImageView new];
    self.iconView.contentMode = UIViewContentModeScaleAspectFill;
    self.iconView.clipsToBounds = YES;
    self.iconView.layer.cornerRadius = 12;
    self.iconView.layer.cornerCurve = kCACornerCurveContinuous;
    self.iconView.backgroundColor = LauncherTheme.rowBackground;
    self.iconView.tintColor = secondary;
    [self.iconView.widthAnchor constraintEqualToConstant:52].active = YES;
    [self.iconView.heightAnchor constraintEqualToConstant:52].active = YES;
    self.titleTextLabel = [self labelWithFont:LauncherTheme.sectionTitleFont color:UIColor.whiteColor];
    self.subtitleLabel = [self labelWithFont:LauncherTheme.subtitleFont color:secondary];
    UIStackView *titles = [[UIStackView alloc] initWithArrangedSubviews:@[self.titleTextLabel, self.subtitleLabel]];
    titles.axis = UILayoutConstraintAxisVertical;
    titles.spacing = 2;
    [titles setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    UIButtonConfiguration *cancelConfig = [UIButtonConfiguration filledButtonConfiguration];
    cancelConfig.title = localize(@"Cancel", nil);
    cancelConfig.baseBackgroundColor = [UIColor.systemRedColor colorWithAlphaComponent:0.2];
    cancelConfig.baseForegroundColor = UIColor.systemRedColor;
    cancelConfig.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    cancelConfig.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = attributes.mutableCopy;
        result[NSFontAttributeName] = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        return result;
    };
    self.cancelButton = [UIButton buttonWithConfiguration:cancelConfig primaryAction:nil];
    [self.cancelButton addTarget:self action:@selector(actionCancel) forControlEvents:UIControlEventPrimaryActionTriggered];
    [self.cancelButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.cancelButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[self.iconView, titles, self.cancelButton]];
    header.spacing = 14;
    header.alignment = UIStackViewAlignmentCenter;

    self.stepsView = [LauncherInstallStepsView new];

    // "Downloading files              87 of 187", bar, "120 MB of 290 MB · 8.1 MB/s · 21 sec left"
    self.phaseLabel = [self labelWithFont:[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold] color:UIColor.whiteColor];
    self.phaseLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.phaseLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    self.countLabel = [self labelWithFont:[UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightSemibold]
        color:LauncherTheme.accentText];
    [self.countLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.countLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    self.spinner = [UIActivityIndicatorView new];
    self.spinner.activityIndicatorViewStyle = UIActivityIndicatorViewStyleMedium;
    self.spinner.color = LauncherTheme.accentText;
    self.spinner.hidesWhenStopped = YES;
    UIStackView *phaseRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.phaseLabel, self.spinner, self.countLabel]];
    phaseRow.spacing = 8;
    phaseRow.alignment = UIStackViewAlignmentCenter;

    self.phaseBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    self.phaseBar.progressTintColor = LauncherTheme.accentText;
    self.phaseBar.trackTintColor = [UIColor colorWithWhite:1 alpha:0.15];
    self.phaseBar.layer.cornerRadius = 3;
    self.phaseBar.clipsToBounds = YES;
    [self.phaseBar.heightAnchor constraintEqualToConstant:6].active = YES;

    self.transferLabel = [self labelWithFont:[UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular] color:secondary];

    // Files downloading right now
    self.fileRows = [NSMutableArray new];
    self.filesStack = [UIStackView new];
    self.filesStack.axis = UILayoutConstraintAxisVertical;
    self.filesStack.spacing = 2;
    self.filesStack.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSUInteger i = 0; i < kMaxFilesInFlight; i++) {
        LauncherInstallFileRow *row = [LauncherInstallFileRow new];
        row.hidden = YES;
        [self.fileRows addObject:row];
        [self.filesStack addArrangedSubview:row];
    }
    self.filesBox = [UIView new];
    self.filesBox.backgroundColor = LauncherTheme.rowBackground;
    self.filesBox.layer.cornerRadius = 12;
    self.filesBox.layer.cornerCurve = kCACornerCurveContinuous;
    [self.filesBox addSubview:self.filesStack];
    [NSLayoutConstraint activateConstraints:@[
        [self.filesStack.topAnchor constraintEqualToAnchor:self.filesBox.topAnchor constant:8],
        [self.filesStack.bottomAnchor constraintEqualToAnchor:self.filesBox.bottomAnchor constant:-8],
        [self.filesStack.leadingAnchor constraintEqualToAnchor:self.filesBox.leadingAnchor constant:16],
        [self.filesStack.trailingAnchor constraintEqualToAnchor:self.filesBox.trailingAnchor constant:-16],
    ]];

    UIView *separator = [UIView new];
    separator.backgroundColor = LauncherTheme.separator;
    [separator.heightAnchor constraintEqualToConstant:1].active = YES;

    // "Show all 187 files  ›"
    UIButtonConfiguration *allConfig = [UIButtonConfiguration plainButtonConfiguration];
    allConfig.baseForegroundColor = LauncherTheme.accentText;
    allConfig.contentInsets = NSDirectionalEdgeInsetsZero;
    allConfig.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = attributes.mutableCopy;
        result[NSFontAttributeName] = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        return result;
    };
    self.allFilesButton = [UIButton buttonWithConfiguration:allConfig primaryAction:nil];
    self.allFilesButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [self.allFilesButton addTarget:self action:@selector(actionShowAllFiles) forControlEvents:UIControlEventPrimaryActionTriggered];
    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold]]];
    chevron.tintColor = LauncherTheme.accentText;
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.userInteractionEnabled = NO;
    [self.allFilesButton addSubview:chevron];
    [NSLayoutConstraint activateConstraints:@[
        [chevron.trailingAnchor constraintEqualToAnchor:self.allFilesButton.trailingAnchor],
        [chevron.centerYAnchor constraintEqualToAnchor:self.allFilesButton.centerYAnchor],
        [self.allFilesButton.heightAnchor constraintGreaterThanOrEqualToConstant:32],
    ]];
    setButtonPointerInteraction(self.allFilesButton);

    self.footnoteLabel = [self labelWithFont:[UIFont systemFontOfSize:13] color:[UIColor colorWithWhite:1 alpha:0.5]];
    self.footnoteLabel.numberOfLines = 0;
    self.footnoteLabel.text = @"Keeps going if you close this. Other pages show the pill too.";

    self.mainStack = [[UIStackView alloc] initWithArrangedSubviews:@[header, self.stepsView, phaseRow, self.phaseBar,
        self.transferLabel, self.filesBox, separator, self.allFilesButton, self.footnoteLabel]];
    self.mainStack.axis = UILayoutConstraintAxisVertical;
    self.mainStack.spacing = 12;
    [self.mainStack setCustomSpacing:22 afterView:header];
    [self.mainStack setCustomSpacing:18 afterView:self.stepsView];
    [self.mainStack setCustomSpacing:8 afterView:phaseRow];
    [self.mainStack setCustomSpacing:16 afterView:self.transferLabel];
    [self.mainStack setCustomSpacing:16 afterView:self.filesBox];
    [self.mainStack setCustomSpacing:4 afterView:self.allFilesButton];
    self.mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.mainStack];
    [NSLayoutConstraint activateConstraints:@[
        [self.mainStack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:20],
        [self.mainStack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:22],
        [self.mainStack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-22],
    ]];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh)
        name:LauncherInstallStatusDidChangeNotification object:nil];
    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:YES animated:animated];
    [self refresh];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // The full file list below has a bar with its own Close button
    [self.navigationController setNavigationBarHidden:NO animated:animated];
}

/// The popover is as tall as its contents, which change as rows come and go
- (void)updatePreferredSize {
    CGSize size = [self.mainStack systemLayoutSizeFittingSize:CGSizeMake(kPanelWidth - 44, 0)
        withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    CGSize preferred = CGSizeMake(kPanelWidth, ceil(size.height) + 40);
    if (!CGSizeEqualToSize(preferred, self.preferredContentSize)) {
        self.preferredContentSize = preferred;
        self.navigationController.preferredContentSize = preferred;
    }
}

/// "Extracting files... 412 / 1830" -> ("Extracting files", "412 of 1830")
static void SplitCount(NSString *message, NSString **text, NSString **count) {
    *text = message;
    *count = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^(.*?)[.…]*\\s+(\\d+)\\s*/\\s*(\\d+)$"
        options:0 error:nil];
    NSTextCheckingResult *match = message ? [regex firstMatchInString:message options:0 range:NSMakeRange(0, message.length)] : nil;
    if (match) {
        *text = [message substringWithRange:[match rangeAtIndex:1]];
        *count = [NSString stringWithFormat:@"%@ of %@", [message substringWithRange:[match rangeAtIndex:2]],
            [message substringWithRange:[match rangeAtIndex:3]]];
    }
}

- (void)refresh {
    if (!self.isViewLoaded) return;
    LauncherInstallStatus *status = LauncherInstallStatus.current;
    if (!status.active) {
        // Finished, failed or cancelled: nothing left to show
        if (self.navigationController.presentingViewController && !self.navigationController.isBeingDismissed) {
            [self.navigationController dismissViewControllerAnimated:YES completion:nil];
        }
        return;
    }

    self.titleTextLabel.text = status.title;
    self.subtitleLabel.text = status.subtitle;
    self.subtitleLabel.hidden = status.subtitle.length == 0;
    NSString *icon = status.iconString;
    if (!icon.length && status.profileName) {
        // Imports: the instance's own icon, once it has one
        id profileIcon = PLProfiles.current.profiles[status.profileName][@"icon"];
        icon = [profileIcon isKindOfClass:NSString.class] ? profileIcon : nil;
    }
    icon = icon ?: @"";
    if (![icon isEqualToString:self.shownIconString ?: @"-"]) {
        self.shownIconString = icon;
        // Same fallback as the instance tiles
        [InstanceIcons setIconString:icon.length ? icon : nil onImageView:self.iconView
            placeholder:[UIImage imageNamed:@"DefaultProfile"]];
    }

    [self.stepsView setPhases:status.phases current:status.phase kind:status.kind];

    // The current step: its name or latest message, its own count and bar
    NSString *text, *count;
    double fraction = status.fraction;
    BOOL download = status.phase == LauncherInstallPhaseFiles || (status.kind == LauncherInstallKindStorePack
        && status.phase == LauncherInstallPhasePack && status.message == nil);
    if (download && status.phase == LauncherInstallPhaseFiles && status.filesTotal > 0) {
        text = status.kind == LauncherInstallKindGameFiles ? @"Downloading game files" : @"Downloading files";
        count = [NSString stringWithFormat:@"%lu of %lu", (unsigned long)status.filesDone, (unsigned long)status.filesTotal];
    } else if (download && status.phase == LauncherInstallPhasePack) {
        text = @"Downloading the pack";
        count = fraction >= 0 ? [NSString stringWithFormat:@"%d%%", (int)(fraction * 100)] : nil;
    } else {
        SplitCount(status.message, &text, &count);
        if (!text.length) {
            switch (status.phase) {
                case LauncherInstallPhasePack: text = @"Reading the pack"; break;
                case LauncherInstallPhaseExtract: text = @"Extracting files"; break;
                case LauncherInstallPhaseLoader: text = @"Installing the mod loader"; break;
                case LauncherInstallPhaseFiles: text = @"Preparing downloads"; break;
                case LauncherInstallPhaseReady: text = @"Finishing"; break;
            }
        }
    }
    self.phaseLabel.text = text;
    self.countLabel.text = count;
    self.countLabel.hidden = count.length == 0;
    if (fraction < 0) {
        [self.spinner startAnimating];
        self.phaseBar.progress = 0;
    } else {
        [self.spinner stopAnimating];
        self.phaseBar.progress = MIN(fraction, 1);
    }

    // "120 MB of 290 MB · 8.1 MB/s · 21 sec left", only while the step is the download
    NSMutableArray<NSString *> *transfer = [NSMutableArray new];
    if (download && status.bytesText.length) [transfer addObject:status.bytesText];
    if (status.detail.length) [transfer addObject:status.detail];
    self.transferLabel.text = [transfer componentsJoinedByString:@" · "];
    self.transferLabel.hidden = transfer.count == 0;

    [self refreshFiles];
    [self updatePreferredSize];
}

/// The files downloading right now (also during Extract and Loader: they start as soon as they are queued)
- (void)refreshFiles {
    MinecraftResourceDownloadTask *task = self.task;
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    NSMutableArray<NSNumber *> *fractions = [NSMutableArray new];
    NSUInteger total = 0;
    if (task) {
        @synchronized (task.fileList) {
            total = MIN(task.fileList.count, task.progressList.count);
            for (NSUInteger i = 0; i < total && names.count < kMaxFilesInFlight; i++) {
                NSProgress *progress = task.progressList[i];
                if (progress.finished || progress.completedUnitCount <= 0 || progress.totalUnitCount <= 1) continue;
                [names addObject:task.fileList[i]];
                [fractions addObject:@(progress.fractionCompleted)];
            }
        }
    }
    for (NSUInteger i = 0; i < kMaxFilesInFlight; i++) {
        LauncherInstallFileRow *row = self.fileRows[i];
        BOOL show = i < names.count;
        if (row.hidden == show) row.hidden = !show;
        if (!show) continue;
        double fraction = MIN(MAX(fractions[i].doubleValue, 0), 1);
        row.nameLabel.text = names[i].lastPathComponent;
        row.bar.progress = fraction;
        row.percentLabel.text = [NSString stringWithFormat:@"%d%%", (int)(fraction * 100)];
    }
    self.filesBox.hidden = names.count == 0;

    self.allFilesButton.hidden = total == 0;
    UIButtonConfiguration *config = self.allFilesButton.configuration;
    NSString *title = total == 1 ? @"Show the download" : [NSString stringWithFormat:@"Show all %lu files", (unsigned long)total];
    if (![config.title isEqualToString:title]) {
        config.title = title;
        self.allFilesButton.configuration = config;
    }
}

- (void)actionShowAllFiles {
    MinecraftResourceDownloadTask *task = self.task;
    if (!task) return;
    DownloadProgressViewController *vc = [[DownloadProgressViewController alloc] initWithTask:task];
    vc.title = self.titleTextLabel.text;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)actionCancel {
    LauncherInstallStatus *status = LauncherInstallStatus.current;
    NSString *message = status.kind == LauncherInstallKindGameFiles
        ? @"The game won't start. Files that are already downloaded are kept for next time."
        : @"No instance is made. Files that are already downloaded or extracted stay in the instance folder and are reused if you install it again.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:
        [NSString stringWithFormat:@"Stop installing %@?", status.title ?: @""]
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Keep installing" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Stop" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        if (self.cancelHandler) self.cancelHandler();
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
