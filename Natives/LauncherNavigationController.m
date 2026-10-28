#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "authenticator/BaseAuthenticator.h"
#import "AFNetworking.h"
#import "ALTServerConnection.h"
#import "CustomControlsViewController.h"
#import "DownloadProgressViewController.h"
#import "installer/modpack/LWJGL3ifyUtils.h"
#import "installer/modpack/ModLoaderInstaller.h"
#import "JavaGUIViewController.h"
#import "LauncherMenuViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "LauncherTheme.h"
#import "MinecraftResourceDownloadTask.h"
#import "MinecraftResourceUtils.h"
#import "installer/modpack/ModpackUtils.h"
#import "installer/modpack/CurseForgeAPI.h"
#import "PLProfiles.h"
#import "UIKit+AFNetworking.h"
#import "UIKit+hook.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

#import <objc/runtime.h>
#include <sys/time.h>

#define AUTORESIZE_MASKS UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin

static void *ProgressObserverContext = &ProgressObserverContext;

@interface LauncherNavigationController () <UIDocumentPickerDelegate, UIPopoverPresentationControllerDelegate> {
}

@property(nonatomic) MinecraftResourceDownloadTask* task;
@property(nonatomic) UINavigationController* progressVC;
@property(nonatomic) NSArray* globalToolbarItems;
@property(nonatomic) NSLayoutConstraint* progressWidthConstraint;
// What the Play button says besides the instance name: "Play", or "Details" while something is downloading
@property(nonatomic, copy) NSString* playBaseTitle;
// Transfer speed sampling (reset for every download)
@property(nonatomic) CFAbsoluteTime lastSampleTime;
@property(nonatomic) NSInteger lastSampleBytes;
@property(nonatomic) double smoothedThroughput;
// What the transfer status says is being downloaded
@property(nonatomic, copy) NSString* downloadLabel;
@property(nonatomic) UIButton* buttonInstall;
@property(nonatomic) UIBarButtonItem* buttonInstallItem;

@end

// Progress callbacks fire many times a second, so the formatter is created once
static NSByteCountFormatter *FileByteFormatter(void) {
    static NSByteCountFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSByteCountFormatter new];
        formatter.countStyle = NSByteCountFormatterCountStyleFile;
    });
    return formatter;
}

@implementation LauncherNavigationController

- (void)viewDidLoad
{
    [super viewDidLoad];

    if ([self respondsToSelector:@selector(setNeedsUpdateOfScreenEdgesDeferringSystemGestures)]) {
        [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
    }
    UIToolbar *targetToolbar = self.toolbar;
    BOOL hasLiquidGlass = _UISolariumEnabled && _UISolariumEnabled();
    if (!hasLiquidGlass) {
        // Content area is near black, the bottom bar matches the sidebar's gray
        [LauncherTheme applyBarBackground:LauncherTheme.contentBackground toNavigationController:self];
    }
    self.view.backgroundColor = LauncherTheme.contentBackground;

    // Bottom action bar: transfer status on the left (starting where the progress bar starts),
    // a full-height "Play (instance)" button flush right
    self.playBaseTitle = localize(@"Play", nil);
    self.progressViewMain = [[UIProgressView alloc] initWithFrame:CGRectZero];
    self.progressText = [[UILabel alloc] initWithFrame:CGRectZero];

    if(hasLiquidGlass) {
        UIView *progressContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 36)];
        progressContainer.translatesAutoresizingMaskIntoConstraints = NO;
        self.progressWidthConstraint = [progressContainer.widthAnchor constraintEqualToConstant:300];
        self.progressWidthConstraint.active = YES;
        [progressContainer.heightAnchor constraintEqualToConstant:36].active = YES;
        self.progressViewMain.frame = CGRectMake(0, -5, 300, 0);
        self.progressViewMain.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        self.progressText.frame = progressContainer.bounds;
        self.progressText.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [progressContainer addSubview:self.progressViewMain];
        [progressContainer addSubview:self.progressText];

        self.buttonInstallItem = [[UIBarButtonItem alloc] initWithTitle:localize(@"Play", nil)
                                                                  style:UIBarButtonItemStylePlain
                                                                 target:self
                                                                 action:@selector(performInstallOrShowDetails:)];
        self.buttonInstallItem.enabled = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.buttonInstallItem.buttonGlassView.backgroundColor = [LauncherTheme.accent colorWithAlphaComponent:0.5];
        });
        self.globalToolbarItems = @[
            [[UIBarButtonItem alloc] initWithCustomView:progressContainer],
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
            self.buttonInstallItem,
        ];
    } else {
        self.buttonInstall = [UIButton buttonWithType:UIButtonTypeSystem];
        setButtonPointerInteraction(self.buttonInstall);
        self.buttonInstall.backgroundColor = LauncherTheme.accent;
        self.buttonInstall.tintColor = UIColor.whiteColor;
        // "Play" hugs the left edge so the instance name after it gets the room
        self.buttonInstall.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        self.buttonInstall.contentEdgeInsets = UIEdgeInsetsMake(0, 16, 0, 12);
        self.buttonInstall.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        self.buttonInstall.enabled = NO;
        [self.buttonInstall addTarget:self action:@selector(performInstallOrShowDetails:) forControlEvents:UIControlEventPrimaryActionTriggered];
        [targetToolbar addSubview:self.progressViewMain];
        [targetToolbar addSubview:self.buttonInstall];
        [targetToolbar addSubview:self.progressText];
    }

    self.progressViewMain.hidden = YES;
    // Fixed size, left aligned (long text is truncated rather than shrunk)
    self.progressText.adjustsFontSizeToFitWidth = NO;
    self.progressText.font = [UIFont systemFontOfSize:14];
    self.progressText.textAlignment = NSTextAlignmentLeft;
    self.progressText.lineBreakMode = NSLineBreakByTruncatingTail;
    self.progressText.userInteractionEnabled = NO;

    [self reloadProfileListNotifying:NO];
    [self layoutLaunchBar];

    [self fetchRemoteVersionList];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(showBlockedMods:)
        name:CurseForgeBlockedModsNotification
        object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(updatePlayButton)
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
    if (notify) {
        // Sidebar and dashboard follow along, and so does the Play button (it observes this notification)
        [NSNotificationCenter.defaultCenter postNotificationName:PLProfilesDidChangeNotification object:self];
    } else {
        [self updatePlayButton];
    }
}

- (void)updatePlayButton {
    NSString *name = PLProfiles.current.selectedProfileName;
    BOOL showName = name.length > 0 && [self.playBaseTitle isEqualToString:localize(@"Play", nil)];

    if (self.buttonInstall) {
        UIFont *boldFont = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
        NSMutableAttributedString *title = [[NSMutableAttributedString alloc] initWithString:self.playBaseTitle
            attributes:@{NSFontAttributeName: boldFont, NSForegroundColorAttributeName: UIColor.whiteColor}];
        if (showName) {
            [title appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"  (%@)", name]
                attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:15 weight:UIFontWeightRegular],
                             NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.85]}]];
        }
        [self.buttonInstall setAttributedTitle:title forState:UIControlStateNormal];
        [self.buttonInstall setAttributedTitle:title forState:UIControlStateDisabled];
    } else {
        self.buttonInstallItem.title = showName ? [NSString stringWithFormat:@"%@ (%@)", self.playBaseTitle, name] : self.playBaseTitle;
    }
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
    self.progressViewMain.hidden = enabled;
    self.progressText.text = nil;
    if (downloading) {
        self.playBaseTitle = localize(enabled ? @"Play" : @"Details", nil);
        [self updatePlayButton];
        self.buttonInstall.enabled = YES;
        self.buttonInstallItem.enabled = YES;
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

    // Instances that carry lwjgl3ify (e.g. GT New Horizons Mobile) must start through its own
    // launch profile; keep the profile in sync with the jar, as Amethyst Android does at launch
    NSString *profileGameDir = PLProfiles.current.profiles[profileName][@"gameDir"];
    if (profileGameDir.length > 0) {
        NSString *instanceDir = [@(getenv("GAME_DIR")) stringByAppendingPathComponent:profileGameDir].stringByStandardizingPath;
        NSError *lwjgl3ifyError;
        NSString *lwjgl3ifyVersion = [LWJGL3ifyUtils versionIdForGameDirectory:instanceDir currentVersionId:versionId error:&lwjgl3ifyError];
        if (!lwjgl3ifyVersion) {
            showDialog(localize(@"Error", nil), lwjgl3ifyError.localizedDescription);
            [self setInteractionEnabled:YES forDownloading:YES];
            return;
        }
        if (![lwjgl3ifyVersion isEqualToString:versionId]) {
            NSLog(@"[LWJGL3ify] Switching profile %@ from %@ to %@", profileName, versionId, lwjgl3ifyVersion);
            PLProfiles.current.profiles[profileName][@"lastVersionId"] = lwjgl3ifyVersion;
            [PLProfiles.current save];
            versionId = lwjgl3ifyVersion;
        }
    }

    NSDictionary *object = [remoteVersionList filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"(id == %@)", versionId]].firstObject;
    if (!object) {
        object = @{
            @"id": versionId,
            @"type": @"custom"
        };
    }

    // A modpack's Forge/NeoForge that couldn't be installed during the import is installed now
    BOOL needsLoader = [ModLoaderInstaller needsInstallForVersionId:versionId];
    if (needsLoader) {
        self.progressText.text = [NSString stringWithFormat:@"Installing %@...", versionId];
    }
    self.downloadLabel = [NSString stringWithFormat:@"Downloading game files for %@", versionId];
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
        NSDictionary *launchVersion = object;
        if (needsLoader) {
            NSError *loaderError;
            NSString *installedVersion = [ModLoaderInstaller installLoaderForVersionId:versionId downloader:nil error:&loaderError];
            if (!installedVersion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    showDialog(localize(@"Error", nil), [NSString stringWithFormat:@"Could not install %@: %@",
                        versionId, loaderError.localizedDescription]);
                });
                self.task.handleError();
                return;
            }
            if (![installedVersion isEqualToString:versionId]) {
                // Older Forge names its version differently from the id the pack asked for
                dispatch_sync(dispatch_get_main_queue(), ^{
                    PLProfiles.current.profiles[profileName][@"lastVersionId"] = installedVersion;
                    [PLProfiles.current save];
                });
            }
            launchVersion = @{@"id": installedVersion, @"type": @"custom"};
        }
        [self.task downloadVersion:launchVersion];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.progressViewMain.observedProgress = self.task.progress;
            [self resetSpeedSampling];
            [self.task.progress addObserver:self
                forKeyPath:@"fractionCompleted"
                options:NSKeyValueObservingOptionInitial
                context:ProgressObserverContext];
        });
    });
}

/// Mods whose authors forbid downloads by other apps can't be installed here; say which ones and where to put them
- (void)showBlockedMods:(NSNotification *)notification {
    NSArray<NSDictionary *> *mods = notification.userInfo[@"mods"];
    if (mods.count == 0) return;

    NSMutableString *list = [NSMutableString new];
    NSUInteger shown = MIN(mods.count, 12);
    for (NSUInteger i = 0; i < shown; i++) {
        [list appendFormat:@"\n• %@", mods[i][@"name"]];
    }
    if (mods.count > shown) {
        [list appendFormat:@"\n… and %lu more", (unsigned long)(mods.count - shown)];
    }
    NSString *message = [NSString stringWithFormat:localize(@"modpack.blocked.message", nil),
        (unsigned long)mods.count, notification.userInfo[@"pack"], notification.userInfo[@"folder"], list];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"modpack.blocked.title", nil)
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"modpack.blocked.copy", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        // Every file name with its CurseForge page, for opening in a browser
        NSMutableArray<NSString *> *lines = [NSMutableArray new];
        for (NSDictionary *mod in mods) {
            [lines addObject:[NSString stringWithFormat:@"%@  %@", mod[@"name"], mod[@"url"]]];
        }
        UIPasteboard.generalPasteboard.string = [lines componentsJoinedByString:@"\n"];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *presenter = self.splitViewController ?: self;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)resetSpeedSampling {
    @synchronized (self) {
        self.lastSampleTime = 0;
        self.lastSampleBytes = 0;
        self.smoothedThroughput = 0;
    }
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

    // Calculate download speed and ETA. Progress changes arrive from several download threads at once, so the
    // sampling is serialized and only measures over spans of at least a second (a span of a few
    // microseconds turned into an absurd speed), then smoothed.
    NSProgress *progress = self.task.textProgress;
    NSInteger totalUnitCount = self.task.progress.totalUnitCount;
    NSInteger completedUnitCount = totalUnitCount * self.task.progress.fractionCompleted;
    progress.completedUnitCount = completedUnitCount;
    double speed = 0;
    @synchronized (self) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (self.lastSampleTime == 0) {
            self.lastSampleTime = now;
            self.lastSampleBytes = completedUnitCount;
        } else if (now - self.lastSampleTime >= 1.0) {
            double instant = MAX(completedUnitCount - self.lastSampleBytes, 0) / (now - self.lastSampleTime);
            self.smoothedThroughput = self.smoothedThroughput == 0 ? instant : self.smoothedThroughput * 0.6 + instant * 0.4;
            progress.throughput = @((NSInteger)self.smoothedThroughput);
            if (self.smoothedThroughput > 0) {
                progress.estimatedTimeRemaining = @(MAX(progress.totalUnitCount - completedUnitCount, 0) / self.smoothedThroughput);
            }
            self.lastSampleTime = now;
            self.lastSampleBytes = completedUnitCount;
        }
        speed = self.smoothedThroughput;
    }

    // "Downloading Fabric Loader: 7% · 42 KB of 572 KB · 1.2 MB/s · 5 sec left"
    NSString *label = self.downloadLabel ?: @"Downloading";
    NSString *statusText;
    if (totalUnitCount <= 1) {
        statusText = [label stringByAppendingString:@"..."];
    } else {
        NSByteCountFormatter *bytes = FileByteFormatter();
        NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObjects:
            [NSString stringWithFormat:@"%d%%", (int)(100.0 * completedUnitCount / totalUnitCount)],
            [NSString stringWithFormat:@"%@ of %@", [bytes stringFromByteCount:completedUnitCount], [bytes stringFromByteCount:totalUnitCount]], nil];
        if (speed > 0) {
            [parts addObject:[NSString stringWithFormat:@"%@/s", [bytes stringFromByteCount:(long long)speed]]];
            NSInteger seconds = (NSInteger)ceil(MAX(totalUnitCount - completedUnitCount, 0) / speed);
            [parts addObject:seconds >= 60
                ? [NSString stringWithFormat:@"%ld min %ld sec left", (long)(seconds / 60), (long)(seconds % 60)]
                : [NSString stringWithFormat:@"%ld sec left", (long)seconds]];
        }
        statusText = [NSString stringWithFormat:@"%@: %@", label, [parts componentsJoinedByString:@" · "]];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        self.progressText.text = statusText;

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
    // Importing spends a long time before anything is downloaded (reading, hashing and extracting the
    // pack), so show what is going on instead of an empty bar
    self.progressText.text = isImport ? @"Preparing import..." : @"Preparing modpack...";
    self.progressViewMain.progress = 0;
    __weak LauncherNavigationController *statusSelf = self;
    ModpackUtils.statusHandler = ^(NSString *status, double fraction) {
        statusSelf.progressText.text = status;
        if (fraction >= 0) {
            statusSelf.progressViewMain.progress = fraction;
        }
    };
    self.downloadLabel = isImport ? @"Downloading modpack files"
        : [NSString stringWithFormat:@"Downloading %@", notification.userInfo[@"detail"][@"title"] ?: @"modpack"];
    self.task = [MinecraftResourceDownloadTask new];
    NSDictionary *userInfo = notification.userInfo;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __weak LauncherNavigationController *weakSelf = self;
        self.task.handleError = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                ModpackUtils.statusHandler = nil;
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
            ModpackUtils.statusHandler = nil;
            self.progressViewMain.observedProgress = self.task.progress;
            [self resetSpeedSampling];
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

/// Non-glass toolbars are laid out by hand: Play is full height and flush right, the transfer status fills
/// the space to its left and starts exactly where the progress bar starts.
- (void)layoutLaunchBar {
    CGFloat width = self.toolbar.bounds.size.width;
    if (!self.buttonInstall) {
        // iOS 26: UIKit places the items, only the status area needs a width
        self.progressWidthConstraint.constant = MAX(width - 260, 120);
        return;
    }
    CGFloat height = MAX(self.toolbar.bounds.size.height - self.toolbar.safeAreaInsets.bottom, 0);
    CGFloat playWidth = MAX(200, MIN(340, width * 0.4));

    self.buttonInstall.frame = CGRectMake(width - playWidth, 0, playWidth, height);
    self.progressText.frame = CGRectMake(0, 0, MAX(width - playWidth - 12, 0), height);
    // Ends where the Play button begins, so no part of the bar is hidden behind it
    self.progressViewMain.frame = CGRectMake(0, 0, MAX(width - playWidth - 12, 0), 0);
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
