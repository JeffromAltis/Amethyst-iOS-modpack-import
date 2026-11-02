#import <UIKit/UIKit.h>

#define sidebarNavController ((UINavigationController *)self.splitViewController.viewControllers[0])
#define sidebarViewController ((LauncherMenuViewController *)sidebarNavController.viewControllers[0])

@interface LauncherMenuCustomItem : NSObject
@property(nonatomic) NSString *title, *imageName;
@property(nonatomic, copy) void (^action)(void);
@property(nonatomic) NSArray<UIViewController *> *vcArray;
@end

@interface LauncherMenuViewController : UITableViewController

@property NSString* listPath;
@property(nonatomic) UIButton *accountButton;
@property(nonatomic) UIBarButtonItem *accountBtnItem;
@property(nonatomic) BOOL isInitialVc;

/// Former sidebar tools (custom controls, execute .jar, send logs); the home screen shows them in a menu.
@property(nonatomic, readonly) NSMutableArray<LauncherMenuCustomItem*> *toolItems;
/// Where tool popovers (send logs) anchor; the sidebar itself is no longer shown.
@property(nonatomic, weak) UIBarButtonItem *popoverAnchorItem;
/// "JIT Enabled" / "JIT Disabled" / "Checking JIT...", or nil before the first check.
@property(nonatomic, readonly) NSString *jitStatusText;

- (void)presentCreateInstanceWindow;
- (void)restoreHighlightedSelection;
/// Opens the dashboard of the given instance (profile) in the content area and selects it in the sidebar.
- (void)openDashboardForProfile:(NSString *)name;
- (void)selectAccount:(UIButton *)sender;
- (void)updateAccountInfo;
- (UIBarButtonItem *)drawAccountButton;

@end
