#import <UIKit/UIKit.h>

NSMutableArray<NSDictionary *> *localVersionList, *remoteVersionList;

@interface LauncherNavigationController : UINavigationController

@property(nonatomic) UIProgressView *progressViewMain, *progressViewSub;
@property(nonatomic) UILabel* progressText;

- (void)enterModInstallerWithPath:(NSString *)path hitEnterAfterWindowShown:(BOOL)hitEnter;
- (void)fetchLocalVersionList;
- (void)setInteractionEnabled:(BOOL)enable forDownloading:(BOOL)downloading;
/// While something installs: shows the download details anchored to `sender` (a view or bar item); otherwise plays.
- (void)performInstallOrShowDetails:(id)sender;
/// The install pill / tile badge: the running install's panel, the failed install's panel, or clears "Ready".
- (void)showInstallStatus:(id)sender;

@end
