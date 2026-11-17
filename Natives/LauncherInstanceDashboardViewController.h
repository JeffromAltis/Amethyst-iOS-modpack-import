#import <UIKit/UIKit.h>

/**
 * Dashboard for a single game instance.
 *
 * "1 profile, 1 instance": an instance is exactly one entry of launcher_profiles.json and runs
 * out of its own game directory. This screen is what opens when an instance is picked in the
 * sidebar, and it owns every per-instance setting (version, directory, RAM, Java, isolation).
 */
@interface LauncherInstanceDashboardViewController : UIViewController

- (instancetype)initWithProfileName:(NSString *)profileName;

/** Show another instance in this same dashboard. Does nothing if no profile has that name. */
- (void)switchToProfileNamed:(NSString *)name;

/** Re-read the profile from disk-backed PLProfiles and redraw every row. */
- (void)reloadFromProfile;

/** NO for the last remaining instance, or a name with no profile. */
+ (BOOL)canDeleteInstanceNamed:(NSString *)name;

/** Asks for confirmation, then deletes the instance with its folder (same as the page's Delete Instance button).
 *  A shared or out-of-place folder is refused with an error. `completion` runs only after a successful delete. */
+ (void)confirmDeleteInstanceNamed:(NSString *)name from:(UIViewController *)presenter completion:(void (^)(void))completion;

@end
