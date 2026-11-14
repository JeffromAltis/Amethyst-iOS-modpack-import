#import "LauncherInstallStatus.h"
#import "LauncherNavigationController.h"
#import "LauncherTheme.h"
#import "utils.h"

NSNotificationName const LauncherInstallStatusDidChangeNotification = @"LauncherInstallStatusDidChangeNotification";

@interface LauncherInstallStatus ()
@property(nonatomic, readwrite) BOOL active;
@property(nonatomic, readwrite) LauncherInstallKind kind;
@property(nonatomic, copy, readwrite) NSString *title, *subtitle, *iconString, *profileName, *message, *bytesText;
@property(nonatomic, copy, readwrite) NSArray<NSNumber *> *phases;
@property(nonatomic, readwrite) LauncherInstallPhase phase;
@property(nonatomic, readwrite) double phaseFraction;
@property(nonatomic, readwrite) NSUInteger filesDone, filesTotal;
/// "8.1 MB/s · 21 sec left" of the downloads, whatever the step
@property(nonatomic, copy) NSString *transfer;
/// Fraction of all bytes queued so far
@property(nonatomic) double downloadFraction;
@property(nonatomic) BOOL postPending;
@end

@implementation LauncherInstallStatus

+ (LauncherInstallStatus *)current {
    static LauncherInstallStatus *status;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ status = [LauncherInstallStatus new]; });
    return status;
}

+ (NSString *)nameOfPhase:(LauncherInstallPhase)phase kind:(LauncherInstallKind)kind {
    switch (phase) {
        case LauncherInstallPhasePack: return kind == LauncherInstallKindImport ? @"Check file" : @"Pack";
        case LauncherInstallPhaseExtract: return @"Extract";
        case LauncherInstallPhaseLoader: return @"Loader";
        case LauncherInstallPhaseFiles: return @"Files";
        case LauncherInstallPhaseReady: return @"Ready";
    }
    return @"";
}

- (void)postNow {
    [NSNotificationCenter.defaultCenter postNotificationName:LauncherInstallStatusDidChangeNotification object:self];
}

/// Progress arrives many times a second; pages only need a few updates a second
- (void)postSoon {
    if (self.postPending) return;
    self.postPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.postPending = NO;
        [self postNow];
    });
}

- (void)beginWithKind:(LauncherInstallKind)kind title:(NSString *)title subtitle:(NSString *)subtitle
    iconString:(NSString *)iconString profileName:(NSString *)profileName {
    self.active = YES;
    self.kind = kind;
    self.title = title.length ? title : localize(@"Downloading", nil);
    self.subtitle = subtitle;
    self.iconString = iconString;
    self.profileName = profileName;
    if (kind == LauncherInstallKindGameFiles) {
        self.phases = @[@(LauncherInstallPhaseFiles), @(LauncherInstallPhaseReady)];
        self.phase = LauncherInstallPhaseFiles;
    } else {
        self.phases = @[@(LauncherInstallPhasePack), @(LauncherInstallPhaseExtract), @(LauncherInstallPhaseLoader),
            @(LauncherInstallPhaseFiles), @(LauncherInstallPhaseReady)];
        self.phase = LauncherInstallPhasePack;
    }
    self.message = nil;
    self.phaseFraction = -1;
    self.filesDone = self.filesTotal = 0;
    self.bytesText = nil;
    self.transfer = nil;
    self.downloadFraction = -1;
    [self postNow];
}

- (void)setShowsLoaderPhase:(BOOL)shows {
    if (!self.active || self.kind != LauncherInstallKindGameFiles) return;
    if (shows) {
        self.phases = @[@(LauncherInstallPhaseLoader), @(LauncherInstallPhaseFiles), @(LauncherInstallPhaseReady)];
        self.phase = LauncherInstallPhaseLoader;
    } else {
        self.phases = @[@(LauncherInstallPhaseFiles), @(LauncherInstallPhaseReady)];
        self.phase = LauncherInstallPhaseFiles;
    }
    [self postNow];
}

+ (void)enterPhase:(LauncherInstallPhase)phase {
    void (^apply)(void) = ^{
        LauncherInstallStatus *status = LauncherInstallStatus.current;
        if (!status.active || phase <= status.phase) return;
        status.phase = phase;
        status.message = nil;
        status.phaseFraction = -1;
        [status postNow];
    };
    // Always queued, even from the main thread, so it keeps its place among status messages sent before it
    dispatch_async(dispatch_get_main_queue(), apply);
}

- (void)updateMessage:(NSString *)message fraction:(double)fraction {
    if (!self.active) return;
    if ((message == self.message || [message isEqualToString:self.message]) && fraction == self.phaseFraction) return;
    self.message = message;
    self.phaseFraction = fraction;
    [self postSoon];
}

- (void)updateFilesDone:(NSUInteger)done total:(NSUInteger)total bytes:(NSString *)bytes
    transfer:(NSString *)transfer fraction:(double)fraction {
    if (!self.active) return;
    self.filesDone = done;
    self.filesTotal = total;
    if (bytes) self.bytesText = bytes;
    self.transfer = transfer;
    self.downloadFraction = fraction;
    [self postSoon];
}

/// The store pack file is downloading (nothing else is known yet)
- (BOOL)downloadingPackFile {
    return self.kind == LauncherInstallKindStorePack && self.phase == LauncherInstallPhasePack && self.message == nil;
}

/// Steps whose progress is the download
- (BOOL)phaseIsDownload {
    return self.phase == LauncherInstallPhaseFiles || self.downloadingPackFile;
}

- (NSString *)stage {
    if (!self.active) return nil;
    if (self.phase == LauncherInstallPhaseFiles) {
        if (self.message && self.kind == LauncherInstallKindGameFiles && self.filesTotal == 0) return self.message;
        return self.filesTotal > 0 ? [NSString stringWithFormat:@"Files %lu/%lu", (unsigned long)self.filesDone,
            (unsigned long)self.filesTotal] : @"Downloading...";
    }
    if (self.downloadingPackFile) {
        return self.downloadFraction >= 0 ? [NSString stringWithFormat:@"Pack %d%%", (int)(self.downloadFraction * 100)]
            : @"Downloading pack...";
    }
    return self.message ?: [[LauncherInstallStatus nameOfPhase:self.phase kind:self.kind] stringByAppendingString:@"..."];
}

- (NSString *)detail {
    return self.phaseIsDownload ? self.transfer : nil;
}

- (double)fraction {
    return self.phaseIsDownload ? self.downloadFraction : self.phaseFraction;
}

- (void)setInstanceProfileName:(NSString *)profileName {
    if (!self.active || profileName.length == 0) return;
    self.profileName = profileName;
    self.title = profileName;
    [self postNow];
}

- (void)end {
    if (!self.active) return;
    self.active = NO;
    self.profileName = nil;
    self.message = nil;
    self.transfer = nil;
    self.bytesText = nil;
    self.phaseFraction = self.downloadFraction = -1;
    self.filesDone = self.filesTotal = 0;
    [self postNow];
}

@end

#pragma mark - Pill

@interface LauncherInstallPill ()
@property(nonatomic, weak) UIBarButtonItem *item;
/// The name is cut short when space runs out; the stage ("· Files 87/187") always shows in full
@property(nonatomic) UILabel *nameLabel, *stageLabel;
@property(nonatomic) CAShapeLayer *trackLayer, *ringLayer;
@property(nonatomic) UIView *ringView;
/// The pill sets its own width (from its text): a size left to the bar fought the search field, which fills
/// all free space, and squeezed the pill to its ring.
@property(nonatomic) NSLayoutConstraint *widthConstraint;
@property(nonatomic) BOOL shown;
@end

@implementation LauncherInstallPill

static const CGFloat kRingSize = 20;

+ (LauncherInstallPill *)pill {
    LauncherInstallPill *pill = [LauncherInstallPill buttonWithType:UIButtonTypeCustom];
    pill.shown = !LauncherInstallStatus.current.active;
    [pill refresh];
    return pill;
}

+ (UIBarButtonItem *)barButtonItem {
    LauncherInstallPill *pill = [LauncherInstallPill buttonWithType:UIButtonTypeCustom];
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithCustomView:pill];
    pill.item = item;
    // Opposite of the current state, so the first refresh applies it (hides the item when nothing installs)
    pill.shown = !LauncherInstallStatus.current.active;
    [pill refresh];
    return item;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.backgroundColor = [LauncherTheme.accent colorWithAlphaComponent:0.32];
    self.layer.cornerRadius = 18;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.clipsToBounds = YES;
    setButtonPointerInteraction(self);

    self.ringView = [UIView new];
    self.ringView.userInteractionEnabled = NO;
    self.ringView.translatesAutoresizingMaskIntoConstraints = NO;
    UIBezierPath *path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(kRingSize / 2, kRingSize / 2) radius:kRingSize / 2 - 1.5
        startAngle:-M_PI_2 endAngle:M_PI * 1.5 clockwise:YES];
    self.trackLayer = [CAShapeLayer layer];
    self.trackLayer.path = path.CGPath;
    self.trackLayer.fillColor = UIColor.clearColor.CGColor;
    self.trackLayer.strokeColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    self.trackLayer.lineWidth = 3;
    self.ringLayer = [CAShapeLayer layer];
    self.ringLayer.path = path.CGPath;
    self.ringLayer.fillColor = UIColor.clearColor.CGColor;
    self.ringLayer.strokeColor = UIColor.whiteColor.CGColor;
    self.ringLayer.lineWidth = 3;
    self.ringLayer.lineCap = kCALineCapRound;
    [self.ringView.layer addSublayer:self.trackLayer];
    [self.ringView.layer addSublayer:self.ringLayer];
    UIImageView *arrow = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.down"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:9 weight:UIImageSymbolWeightBold]]];
    arrow.tintColor = UIColor.whiteColor;
    arrow.translatesAutoresizingMaskIntoConstraints = NO;
    [self.ringView addSubview:arrow];

    self.nameLabel = [UILabel new];
    self.nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.nameLabel.textColor = UIColor.whiteColor;
    self.nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.nameLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [self.nameLabel setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    self.stageLabel = [UILabel new];
    self.stageLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightMedium];
    self.stageLabel.textColor = [UIColor colorWithWhite:1 alpha:0.78];
    [self.stageLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.stageLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    for (UILabel *label in @[self.nameLabel, self.stageLabel]) {
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.userInteractionEnabled = NO;
        [self addSubview:label];
    }
    [self addSubview:self.ringView];
    self.maxWidth = 300;

    self.widthConstraint = [self.widthAnchor constraintEqualToConstant:0];
    self.hidden = YES;
    [NSLayoutConstraint activateConstraints:@[
        self.widthConstraint,
        [self.heightAnchor constraintEqualToConstant:36],
        [self.ringView.widthAnchor constraintEqualToConstant:kRingSize],
        [self.ringView.heightAnchor constraintEqualToConstant:kRingSize],
        [self.ringView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
        [self.ringView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [arrow.centerXAnchor constraintEqualToAnchor:self.ringView.centerXAnchor],
        [arrow.centerYAnchor constraintEqualToAnchor:self.ringView.centerYAnchor],
        [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.ringView.trailingAnchor constant:8],
        [self.nameLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.stageLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.trailingAnchor constant:6],
        [self.stageLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14],
        [self.stageLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];

    [self addTarget:self action:@selector(actionShowDetails) forControlEvents:UIControlEventPrimaryActionTriggered];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh)
        name:LauncherInstallStatusDidChangeNotification object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)refresh {
    LauncherInstallStatus *status = LauncherInstallStatus.current;
    BOOL show = status.active;
    // Touch the bar only when something changed: every change makes it lay out all its items again
    if (show != self.shown) {
        self.shown = show;
        if (@available(iOS 16.0, *)) {
            self.item.hidden = !show;
        }
        // Before iOS 16 a bar item can't be hidden: collapse the pill instead
        self.hidden = !show;
        if (!show) {
            self.widthConstraint.constant = 0;
            self.nameLabel.text = nil;
            self.stageLabel.text = nil;
        }
    }
    if (!show) return;

    NSString *title = status.title ?: @"";
    NSString *stage = status.stage.length ? [@"·  " stringByAppendingString:status.stage] : @"";
    if (![title isEqualToString:self.nameLabel.text] || ![stage isEqualToString:self.stageLabel.text]) {
        self.nameLabel.text = title;
        self.stageLabel.text = stage;
        self.accessibilityLabel = [NSString stringWithFormat:@"%@ %@", title, status.stage ?: @""];
        // Grows in 16 pt steps and never shrinks during one install, so a count going from 9 to 10 doesn't
        // make the whole bar jump; a long name is cut short at maxWidth
        CGFloat needed = 10 + kRingSize + 8 + ceil([self.nameLabel intrinsicContentSize].width) + 6
            + ceil([self.stageLabel intrinsicContentSize].width) + 14;
        CGFloat width = MIN(self.maxWidth, ceil(needed / 16) * 16);
        if (width > self.widthConstraint.constant) {
            self.widthConstraint.constant = width;
        }
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // Unknown progress (reading or extracting a pack before the downloads are known): a short arc
    self.ringLayer.strokeEnd = status.fraction < 0 ? 0.15 : MAX(0.02, MIN(status.fraction, 1));
    [CATransaction commit];
}

- (void)actionShowDetails {
    UIResponder *responder = self.nextResponder;
    while (responder && ![responder isKindOfClass:UIViewController.class]) responder = responder.nextResponder;
    UINavigationController *nav = [(UIViewController *)responder navigationController];
    if ([nav isKindOfClass:LauncherNavigationController.class]) {
        [(LauncherNavigationController *)nav performInstallOrShowDetails:self];
    }
}

@end
