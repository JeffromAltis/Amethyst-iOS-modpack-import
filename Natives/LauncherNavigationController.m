#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "authenticator/BaseAuthenticator.h"
#import "AFNetworking.h"
#import "ALTServerConnection.h"
#import "CustomControlsViewController.h"
#import "DownloadProgressViewController.h"
#import "JavaGUIViewController.h"
#import "LauncherMenuViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceDownloadTask.h"
#import "MinecraftResourceUtils.h"
#import "PLProfiles.h"
#import "UIKit+AFNetworking.h"
#import "UIKit+hook.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

#import <objc/runtime.h>
#include <sys/time.h>

#define AUTORESIZE_MASKS UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin

static void *ProgressObserverContext = &ProgressObserverContext;

/// Small status pill next to the Play button: which instance is going to be launched, and whether it is ready.
@interface LauncherStatusBadgeView : UIView
@property(nonatomic, readonly) UILabel *captionLabel, *statusLabel;
@end

@implementation LauncherStatusBadgeView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    self.backgroundColor = UIColor.tertiarySystemFillColor;
    self.layer.cornerRadius = 10;
    self.clipsToBounds = YES;

    _captionLabel = [UILabel new];
    _captionLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    _captionLabel.textColor = UIColor.labelColor;
    _captionLabel.text = localize(@"launcher.status.current_instance", nil);

    _statusLabel = [UILabel new];
    _statusLabel.font = [UIFont systemFontOfSize:13];
    _statusLabel.textColor = UIColor.systemGreenColor;
    _statusLabel.adjustsFontSizeToFitWidth = YES;
    _statusLabel.minimumScaleFactor = 0.7;
    _statusLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_captionLabel, _statusLabel]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentLeading;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.userInteractionEnabled = NO;
    [self addSubview:stack];
    // Vertically centered, 12pt side padding
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
    return self;
}

@end

@interface LauncherNavigationController () <UIDocumentPickerDelegate, UIPopoverPresentationControllerDelegate> {
}

@property(nonatomic) MinecraftResourceDownloadTask* task;
@property(nonatomic) UINavigationController* progressVC;
@property(nonatomic) NSArray* globalToolbarItems;
@property(nonatomic) LauncherStatusBadgeView* statusBadge;
@property(nonatomic) UIButton* buttonInstall;
@property(nonatomic) UIBarButtonItem* buttonInstallItem;

@end

@implementation LauncherNavigationController

- (void)viewDidLoad
{
    [super viewDidLoad];

    if ([self respondsToSelector:@selector(setNeedsUpdateOfScreenEdgesDeferringSystemGestures)]) {
        [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
    }
    UIToolbar *targetToolbar = self.toolbar;
    BOOL hasLiquidGlass = _UISolariumEnabled && _UISolariumEnabled();

    // Bottom action bar: everything related to launching is grouped flush-right
    // [ ... status badge ][ Play ]
    self.statusBadge = [[LauncherStatusBadgeView alloc] initWithFrame:CGRectMake(0, 0, 280, 36)];
    self.progressViewMain = [[UIProgressView alloc] initWithFrame:CGRectZero];
    self.progressText = [[UILabel alloc] initWithFrame:CGRectZero];

    if(hasLiquidGlass) {
        UIView *badgeContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 280, 36)];
        [badgeContainer.widthAnchor constraintEqualToConstant:280].active = YES;
        [badgeContainer.heightAnchor constraintEqualToConstant:36].active = YES;
        self.statusBadge.frame = badgeContainer.bounds;
        self.statusBadge.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.progressViewMain.frame = CGRectMake(20, -5, 240, 0);
        self.progressText.frame = badgeContainer.bounds;
        [badgeContainer addSubview:self.progressViewMain];
        [badgeContainer addSubview:self.statusBadge];
        [badgeContainer addSubview:self.progressText];

        self.buttonInstallItem = [[UIBarButtonItem alloc] initWithTitle:localize(@"Play", nil)
                                                                  style:UIBarButtonItemStylePlain
                                                                 target:self
                                                                 action:@selector(performInstallOrShowDetails:)];
        self.buttonInstallItem.enabled = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.buttonInstallItem.buttonGlassView.backgroundColor = [UIColor colorWithRed:121/255.0 green:56/255.0 blue:162/255.0 alpha:0.5];
        });
        self.globalToolbarItems = @[
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
            [[UIBarButtonItem alloc] initWithCustomView:badgeContainer],
            self.buttonInstallItem,
        ];
    } else {
        self.buttonInstall = [UIButton buttonWithType:UIButtonTypeSystem];
        setButtonPointerInteraction(self.buttonInstall);
        [self.buttonInstall setTitle:localize(@"Play", nil) forState:UIControlStateNormal];
        self.buttonInstall.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
        self.buttonInstall.backgroundColor = [UIColor colorWithRed:121/255.0 green:56/255.0 blue:162/255.0 alpha:1.0];
        self.buttonInstall.tintColor = UIColor.whiteColor;
        self.buttonInstall.enabled = NO;
        [self.buttonInstall addTarget:self action:@selector(performInstallOrShowDetails:) forControlEvents:UIControlEventPrimaryActionTriggered];
        [targetToolbar addSubview:self.progressViewMain];
        [targetToolbar addSubview:self.statusBadge];
        [targetToolbar addSubview:self.buttonInstall];
        [targetToolbar addSubview:self.progressText];
    }

    self.progressViewMain.hidden = YES;
    self.progressText.adjustsFontSizeToFitWidth = YES;
    self.progressText.font = [self.progressText.font fontWithSize:16];
    self.progressText.textAlignment = NSTextAlignmentCenter;
    self.progressText.userInteractionEnabled = NO;

    [self reloadProfileListNotifying:NO];
    [self layoutLaunchBar];

    [self fetchRemoteVersionList];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(updateStatusBadge)
        name:PLProfilesDidChangeNotification
        object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(receiveNotification:) 
        name:@"InstallModpack"
        object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(receiveNotification:)
        name:@"ImportModpack"
        object:nil];

    if ([BaseAuthenticator.current isKindOfClass:MicrosoftAuthenticator.class]) {
        // Perform token refreshment on startup
        [self setInteractionEnabled:NO forDownloading:NO];
        id callback = ^(id status, BOOL success) {
            status = [status description];
            self.progressText.text = status;
            if (status == nil) {
                [self setInteractionEnabled:YES forDownloading:NO];
            } else if (!success) {
                showDialog(localize(@"Error", nil), status);
            }
        };
        [BaseAuthenticator.current refreshTokenWithCallback:callback];
    }
}

- (void)setViewControllers:(NSArray<UIViewController *> *)viewControllers animated:(BOOL)animated {
    [super setViewControllers:viewControllers animated:animated];
    if (!viewControllers.firstObject.toolbarItems && self.globalToolbarItems) {
        viewControllers.firstObject.toolbarItems = self.globalToolbarItems;
    }
}

- (BOOL)isVersionInstalled:(NSString *)versionId {
    NSString *localPath = [NSString stringWithFormat:@"%s/versions/%@", getenv("GAME_DIR"), versionId];
    BOOL isDirectory;
    [NSFileManager.defaultManager fileExistsAtPath:localPath isDirectory:&isDirectory];
    return isDirectory;
}

- (void)fetchLocalVersionList {
    if (!localVersionList) {
        localVersionList = [NSMutableArray new];
    }
    [localVersionList removeAllObjects];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *versionPath = [NSString stringWithFormat:@"%s/versions/", getenv("GAME_DIR")];
    NSArray *list = [fileManager contentsOfDirectoryAtPath:versionPath error:Nil];
    for (NSString *versionId in list) {
        if (![self isVersionInstalled:versionId]) continue;
        [localVersionList addObject:@{
            @"id": versionId,
            @"type": @"custom"
        }];
    }
}

- (void)fetchRemoteVersionList {
    [(id)(self.buttonInstall ?: self.buttonInstallItem) setEnabled:NO];
    remoteVersionList = @[
        @{@"id": @"latest-release", @"type": @"release"},
        @{@"id": @"latest-snapshot", @"type": @"snapshot"}
    ].mutableCopy;

    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    [manager GET:@"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json" parameters:nil headers:nil progress:^(NSProgress * _Nonnull progress) {
        self.progressViewMain.progress = progress.fractionCompleted;
    } success:^(NSURLSessionTask *task, NSDictionary *responseObject) {
        [remoteVersionList addObjectsFromArray:responseObject[@"versions"]];
        NSDebugLog(@"[VersionList] Got %d versions", remoteVersionList.count);
        setPrefObject(@"internal.latest_version", responseObject[@"latest"]);
        [(id)(self.buttonInstall ?: self.buttonInstallItem) setEnabled:YES];
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        NSDebugLog(@"[VersionList] Warning: Unable to fetch version list: %@", error.localizedDescription);
        [(id)(self.buttonInstall ?: self.buttonInstallItem) setEnabled:YES];
    }];
}

// Invoked by: startup, instance change event
- (void)reloadProfileList {
    [self reloadProfileListNotifying:YES];
}

- (void)reloadProfileListNotifying:(BOOL)notify {
    // Reload local version list
    [self fetchLocalVersionList];
    // Reload launcher_profiles.json
    [PLProfiles updateCurrent];
    // 1 profile = 1 instance: the selected profile is what Play launches
    if (!PLProfiles.current.profiles[PLProfiles.current.selectedProfileName] && PLProfiles.current.profiles.count > 0) {
        PLProfiles.current.selectedProfileName = PLProfiles.current.profiles.allKeys.firstObject;
    }
    [self updateStatusBadge];
    if (notify) {
        // Sidebar and dashboard follow along
        [NSNotificationCenter.defaultCenter postNotificationName:PLProfilesDidChangeNotification object:self];
    }
}

- (void)updateStatusBadge {
    NSString *name = PLProfiles.current.selectedProfileName;
    self.statusBadge.statusLabel.text = name.length > 0
        ? [NSString stringWithFormat:localize(@"launcher.status.ready", nil), name]
        : @"-";
}

#pragma mark - Options
- (void)enterCustomControls {
    CustomControlsViewController *vc = [[CustomControlsViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.setDefaultCtrl = ^(NSString *name){
        setPrefObject(@"control.default_ctrl", name);
    };
    vc.getDefaultCtrl = ^{
        return getPrefObject(@"control.default_ctrl");
    };
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)enterModInstaller {
    UIDocumentPickerViewController *documentPicker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[[UTType typeWithMIMEType:@"application/java-archive"]]
        asCopy:YES];
    documentPicker.delegate = self;
    documentPicker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:documentPicker animated:YES completion:nil];
}

- (void)enterModInstallerWithPath:(NSString *)path hitEnterAfterWindowShown:(BOOL)hitEnter {
    JavaGUIViewController *vc = [[JavaGUIViewController alloc] init];
    vc.filepath = path;
    vc.hitEnterAfterWindowShown = hitEnter;
    if (!vc.requiredJavaVersion) {
        return;
    }
    [self invokeAfterJITEnabled:^{
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        NSLog(@"[ModInstaller] launching %@", vc.filepath);
        [self presentViewController:vc animated:YES completion:nil];
    }];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url {
    [self enterModInstallerWithPath:url.path hitEnterAfterWindowShown:NO];
}

- (void)setInteractionEnabled:(BOOL)enabled forDownloading:(BOOL)downloading {
    self.statusBadge.alpha = enabled ? 1 : 0.2;
    self.progressViewMain.hidden = enabled;
    self.progressText.text = nil;
    if (downloading) {
        if(self.buttonInstall) {
            [self.buttonInstall setTitle:localize(enabled ? @"Play" : @"Details", nil) forState:UIControlStateNormal];
            self.buttonInstall.enabled = YES;
        } else {
            self.buttonInstallItem.title = localize(enabled ? @"Play" : @"Details", nil);
            self.buttonInstallItem.enabled = YES;
        }
    } else {
        self.buttonInstall.enabled = enabled;
        self.buttonInstallItem.enabled = enabled;
    }
    UIApplication.sharedApplication.idleTimerDisabled = !enabled;
}

- (void)launchMinecraft:(UIButton *)sender {
    NSString *profileName = PLProfiles.current.selectedProfileName;
    if (!PLProfiles.current.profiles[profileName]) {
        return;
    }

    if (BaseAuthenticator.current == nil) {
        // Present the account selector if none selected
        UIViewController *view = [(UINavigationController *)self.splitViewController.viewControllers[0]
        viewControllers][0];
        [view performSelector:@selector(selectAccount:) withObject:sender];
        return;
    }

    [self setInteractionEnabled:NO forDownloading:YES];

    NSString *versionId = PLProfiles.current.profiles[profileName][@"lastVersionId"];
    NSDictionary *object = [remoteVersionList filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"(id == %@)", versionId]].firstObject;
    if (!object) {
        object = @{
            @"id": versionId,
            @"type": @"custom"
        };
    }

    self.task = [MinecraftResourceDownloadTask new];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __weak LauncherNavigationController *weakSelf = self;
        self.task.handleError = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf setInteractionEnabled:YES forDownloading:YES];
                weakSelf.task = nil;
                weakSelf.progressVC = nil;
            });
        };
        [self.task downloadVersion:object];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.progressViewMain.observedProgress = self.task.progress;
            [self.task.progress addObserver:self
                forKeyPath:@"fractionCompleted"
                options:NSKeyValueObservingOptionInitial
                context:ProgressObserverContext];
        });
    });
}

- (void)performInstallOrShowDetails:(id)sender {
    BOOL usesBarButtonItem = [sender isKindOfClass:UIBarButtonItem.class];
    if (self.task) {
        if (!self.progressVC) {
            UIViewController *vc = [[DownloadProgressViewController alloc] initWithTask:self.task];
            self.progressVC = [[UINavigationController alloc] initWithRootViewController:vc];
            self.progressVC.modalPresentationStyle = UIModalPresentationPopover;
        } else if (self.progressVC.popoverPresentationController._isDismissing) {
            // FIXME: stock bug? it crashes when users dismisses and presents this vc too fast
            // "UIPopoverPresentationController () should have a non-nil sourceView or barButtonItem set before the presentation occurs."
            return;
        }
        
        if (usesBarButtonItem) {
            self.progressVC.popoverPresentationController.barButtonItem = sender;
        } else {
            self.progressVC.popoverPresentationController.sourceView = sender;
        }
        [self presentViewController:self.progressVC animated:YES completion:nil];
    } else {
        if (usesBarButtonItem) {
            sender = ((UIBarButtonItem *)sender).buttonGlassView;
        }
        [self launchMinecraft:sender];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != ProgressObserverContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }

    // Calculate download speed and ETA
    static CGFloat lastMsTime;
    static NSUInteger lastSecTime, lastCompletedUnitCount;
    NSProgress *progress = self.task.textProgress;
    struct timeval tv;
    gettimeofday(&tv, NULL); 
    NSInteger completedUnitCount = self.task.progress.totalUnitCount * self.task.progress.fractionCompleted;
    progress.completedUnitCount = completedUnitCount;
    if (lastSecTime < tv.tv_sec) {
        CGFloat currentTime = tv.tv_sec + tv.tv_usec / 1000000.0;
        NSInteger throughput = (completedUnitCount - lastCompletedUnitCount) / (currentTime - lastMsTime);
        progress.throughput = @(throughput);
        progress.estimatedTimeRemaining = @((progress.totalUnitCount - completedUnitCount) / throughput);
        lastCompletedUnitCount = completedUnitCount;
        lastSecTime = tv.tv_sec;
        lastMsTime = currentTime;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        self.progressText.text = progress.localizedAdditionalDescription;

        if (!progress.finished) return;
        [self.progressVC dismissModalViewControllerAnimated:NO];

        self.progressViewMain.observedProgress = nil;
        if (self.task.metadata) {
            __block NSDictionary *metadata = self.task.metadata;
            [self invokeAfterJITEnabled:^{
                UIKit_launchMinecraftSurfaceVC(self.view.window, metadata);
            }];
        } else {
            [self reloadProfileList];
        }
        self.task = nil;
        [self setInteractionEnabled:YES forDownloading:YES];
    });
}

- (void)receiveNotification:(NSNotification *)notification {
    BOOL isImport = [notification.name isEqualToString:@"ImportModpack"];
    if (!isImport && ![notification.name isEqualToString:@"InstallModpack"]) {
        return;
    }
    [self setInteractionEnabled:NO forDownloading:YES];
    self.task = [MinecraftResourceDownloadTask new];
    NSDictionary *userInfo = notification.userInfo;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __weak LauncherNavigationController *weakSelf = self;
        self.task.handleError = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf setInteractionEnabled:YES forDownloading:YES];
                weakSelf.task = nil;
                weakSelf.progressVC = nil;
            });
        };
        if (isImport) {
            [self.task importModpackFromPath:userInfo[@"path"]];
        } else {
            [self.task downloadModpackFromAPI:notification.object detail:userInfo[@"detail"] atIndex:[userInfo[@"index"] unsignedLongValue]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.progressViewMain.observedProgress = self.task.progress;
            [self.task.progress addObserver:self
                forKeyPath:@"fractionCompleted"
                options:NSKeyValueObservingOptionInitial
                context:ProgressObserverContext];
        });
    });
}

- (void)invokeAfterJITEnabled:(void(^)(void))handler {
    localVersionList = remoteVersionList = nil;
    BOOL hasTrollStoreJIT = getEntitlementValue(@"jb.pmap_cs.custom_trust");
    BOOL isLiveContainer = getenv("LC_HOME_PATH") != NULL;

    if (isJITEnabled(false)) {
        [ALTServerManager.sharedManager stopDiscovering];
        handler();
        return;
    } else if (hasTrollStoreJIT) {
        NSURL *jitURL = [NSURL URLWithString:[NSString stringWithFormat:@"apple-magnifier://enable-jit?bundle-id=%@", NSBundle.mainBundle.bundleIdentifier]];
        [UIApplication.sharedApplication openURL:jitURL options:@{} completionHandler:nil];
        // Do not return, wait for TrollStore to enable JIT and jump back
    } else if (getPrefBool(@"debug.debug_skip_wait_jit")) {
        NSLog(@"Debug option skipped waiting for JIT. Java might not work.");
        handler();
        return;
    } else if (@available(iOS 17.4, *)) {
        NSString *scriptDataString = @"";
        if(DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM)) {
            NSData *scriptData = [NSData dataWithContentsOfFile:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
            scriptDataString = [@"&script-data=" stringByAppendingString:[scriptData base64EncodedStringWithOptions:0]];
        }
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:[NSString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@&pid=%d%@", NSBundle.mainBundle.bundleIdentifier, getpid(), scriptDataString]] options:@{} completionHandler:nil];
    } else {
        // Assuming 16.7-17.3.1. SideStore still lacks this URL scheme at the time of writing, so it only jumps to SideStore.
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:[NSString stringWithFormat:@"sidestore://sidejit-enable?pid=%d", getpid()]] options:@{} completionHandler:nil];
    }

    self.progressText.text = localize(@"launcher.wait_jit.title", nil);

    UIAlertController* alert = [UIAlertController alertControllerWithTitle:localize(@"launcher.wait_jit.title", nil)
        message:hasTrollStoreJIT ? localize(@"launcher.wait_jit_trollstore.message", nil) : localize(@"launcher.wait_jit.message", nil)
        preferredStyle:UIAlertControllerStyleAlert];
/* TODO:
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:^{
        
    }];
    [alert addAction:cancel];
*/
    [self presentViewController:alert animated:YES completion:nil];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (!isJITEnabled(false)) {
            // Perform check for every 200ms
            usleep(1000*200);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:handler];
        });
    });
}

#pragma mark - UIPopoverPresentationControllerDelegate
- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller traitCollection:(UITraitCollection *)traitCollection {
    return UIModalPresentationNone;
}

#pragma mark - View controller UI mode

- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

/// Non-glass toolbars are laid out by hand: Play is full height and flush right, the badge sits right next to it.
- (void)layoutLaunchBar {
    if (!self.buttonInstall) return; // iOS 26 toolbar items are laid out by UIKit
    CGRect bounds = self.toolbar.bounds;
    CGFloat width = bounds.size.width;
    CGFloat height = MAX(bounds.size.height - self.toolbar.safeAreaInsets.bottom, 0);
    CGFloat playWidth = MAX(120, MIN(180, width * 0.22));
    CGFloat badgeWidth = MAX(MIN(320, width - playWidth - 24), 0);

    self.buttonInstall.frame = CGRectMake(width - playWidth, 0, playWidth, height);
    self.statusBadge.frame = CGRectMake(width - playWidth - 8 - badgeWidth, 4, badgeWidth, MAX(height - 8, 0));
    self.progressText.frame = self.statusBadge.frame;
    self.progressViewMain.frame = CGRectMake(0, 0, width, 0);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [sidebarViewController updateAccountInfo];
    if (self.globalToolbarItems) {
        if (!self.viewControllers.firstObject.toolbarItems) {
            self.viewControllers.firstObject.toolbarItems = self.globalToolbarItems;
        }
    }
    [self layoutLaunchBar];
}

@end
