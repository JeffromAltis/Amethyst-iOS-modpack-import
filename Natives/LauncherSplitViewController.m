#import "LauncherSplitViewController.h"
#import "LauncherInstanceDashboardViewController.h"
#import "LauncherMenuViewController.h"
#import "LauncherTheme.h"
#import "PLProfiles.h"
#import "LauncherProfilesViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "utils.h"

extern NSMutableDictionary *prefDict;

@interface LauncherSplitViewController ()<UISplitViewControllerDelegate>{
}
@end

@implementation LauncherSplitViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = LauncherTheme.contentBackground;
    if ([getPrefObject(@"control.control_safe_area") length] == 0) {
        setPrefObject(@"control.control_safe_area", NSStringFromUIEdgeInsets(getDefaultSafeArea()));
    }

    self.delegate = self;

    UINavigationController *masterVc = [[UINavigationController alloc] initWithRootViewController:[[LauncherMenuViewController alloc] init]];
    LauncherNavigationController *detailVc = [[LauncherNavigationController alloc] initWithRootViewController:[[LauncherInstanceDashboardViewController alloc] initWithProfileName:PLProfiles.current.selectedProfileName]];
    detailVc.toolbarHidden = NO;

    self.viewControllers = @[masterVc, detailVc];
    [self changeDisplayModeForSize:self.view.frame.size];
    
    self.maximumPrimaryColumnWidth = self.view.bounds.size.width * 0.95;
}

- (void)splitViewController:(UISplitViewController *)svc willChangeToDisplayMode:(UISplitViewControllerDisplayMode)displayMode {
    if (self.preferredDisplayMode != displayMode && self.displayMode != UISplitViewControllerDisplayModeSecondaryOnly) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.preferredDisplayMode = UISplitViewControllerDisplayModeSecondaryOnly;
        });
    }
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [self changeDisplayModeForSize:size];
}

- (void)changeDisplayModeForSize:(CGSize)size {
    BOOL isPortrait = size.height > size.width;
    if (self.preferredDisplayMode == 0 || self.displayMode != UISplitViewControllerDisplayModeSecondaryOnly) {
        if(!getPrefBool(@"general.hidden_sidebar")) {
            self.preferredDisplayMode = isPortrait ?
                UISplitViewControllerDisplayModeOneOverSecondary :
                UISplitViewControllerDisplayModeOneBesideSecondary;
        } else {
            self.preferredDisplayMode = UISplitViewControllerDisplayModeSecondaryOnly;
        }
    }
    self.preferredSplitBehavior = isPortrait ?
        UISplitViewControllerSplitBehaviorOverlay :
        UISplitViewControllerSplitBehaviorTile;
}

- (void)dismissViewController {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
