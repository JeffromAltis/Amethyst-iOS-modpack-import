#import "LauncherInstallStatus.h"
#import "LauncherNavigationController.h"
#import "LauncherTheme.h"
#import "utils.h"

NSNotificationName const LauncherInstallStatusDidChangeNotification = @"LauncherInstallStatusDidChangeNotification";

@interface LauncherInstallStatus ()
@property(nonatomic, readwrite) BOOL active;
@property(nonatomic, copy, readwrite) NSString *title, *stage, *detail, *profileName;
@property(nonatomic, readwrite) double fraction;
@property(nonatomic) BOOL postPending;
@end

@implementation LauncherInstallStatus

+ (LauncherInstallStatus *)current {
    static LauncherInstallStatus *status;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ status = [LauncherInstallStatus new]; });
    return status;
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

- (void)beginWithTitle:(NSString *)title profileName:(NSString *)profileName {
    self.active = YES;
    self.title = title.length ? title : localize(@"Downloading", nil);
    self.profileName = profileName;
    self.stage = nil;
    self.detail = nil;
    self.fraction = -1;
    [self postNow];
}

- (void)updateStage:(NSString *)stage detail:(NSString *)detail fraction:(double)fraction {
    if (!self.active) return;
    if ([stage isEqualToString:self.stage] && (detail == self.detail || [detail isEqualToString:self.detail])
        && fraction == self.fraction) {
        return;
    }
    self.stage = stage;
    self.detail = detail;
    self.fraction = fraction;
    [self postSoon];
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
    self.stage = nil;
    self.detail = nil;
    self.fraction = -1;
    [self postNow];
}

@end

#pragma mark - Pill

@interface LauncherInstallPill ()
@property(nonatomic, weak) UIBarButtonItem *item;
/// The name is cut short when space runs out; the stage ("· Files 87/187") always shows in full
@property(nonatomic) UILabel *titleLabel, *stageLabel;
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

    self.titleLabel = [UILabel new];
    self.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.titleLabel.textColor = UIColor.whiteColor;
    self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.titleLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [self.titleLabel setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    self.stageLabel = [UILabel new];
    self.stageLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightMedium];
    self.stageLabel.textColor = [UIColor colorWithWhite:1 alpha:0.78];
    [self.stageLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.stageLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    for (UILabel *label in @[self.titleLabel, self.stageLabel]) {
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
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.ringView.trailingAnchor constant:8],
        [self.titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.stageLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor constant:6],
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
            self.titleLabel.text = nil;
            self.stageLabel.text = nil;
        }
    }
    if (!show) return;

    NSString *title = status.title ?: @"";
    NSString *stage = status.stage.length ? [@"·  " stringByAppendingString:status.stage] : @"";
    if (![title isEqualToString:self.titleLabel.text] || ![stage isEqualToString:self.stageLabel.text]) {
        self.titleLabel.text = title;
        self.stageLabel.text = stage;
        self.accessibilityLabel = [NSString stringWithFormat:@"%@ %@", title, status.stage ?: @""];
        // Grows in 16 pt steps and never shrinks during one install, so a count going from 9 to 10 doesn't
        // make the whole bar jump; a long name is cut short at maxWidth
        CGFloat needed = 10 + kRingSize + 8 + ceil([self.titleLabel intrinsicContentSize].width) + 6
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
