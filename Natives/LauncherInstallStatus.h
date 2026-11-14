#import <UIKit/UIKit.h>

/// Posted on the main thread when the install status changes (at most a few times a second while downloading).
extern NSNotificationName const LauncherInstallStatusDidChangeNotification;

/// What the launcher is installing right now (a modpack, an import, or a version's game files), in a form every page
/// can show: the toolbar pill, the instance tile's caption and the line under the instance page's Play button.
/// Main thread only.
@interface LauncherInstallStatus : NSObject

@property(class, nonatomic, readonly) LauncherInstallStatus *current;

@property(nonatomic, readonly) BOOL active;
/// What is being installed, e.g. "RLCraft" or an instance name.
@property(nonatomic, copy, readonly) NSString *title;
/// Short stage text, e.g. "Files 87/187", "Extracting files... 412 / 1830", "Preparing modpack...".
@property(nonatomic, copy, readonly) NSString *stage;
/// Transfer details for the current stage, e.g. "8.1 MB/s · 21 sec left"; nil when there are none.
@property(nonatomic, copy, readonly) NSString *detail;
/// 0...1, or < 0 when unknown.
@property(nonatomic, readonly) double fraction;
/// The instance (profile) being installed; nil until it is known (a modpack's instance is created part way through).
@property(nonatomic, copy, readonly) NSString *profileName;

- (void)beginWithTitle:(NSString *)title profileName:(NSString *)profileName;
- (void)updateStage:(NSString *)stage detail:(NSString *)detail fraction:(double)fraction;
/// Called when a modpack's instance has been created: the tile and title follow it from then on.
- (void)setInstanceProfileName:(NSString *)profileName;
- (void)end;

@end

/// Toolbar pill that shows the current install ("RLCraft · Files 87/187" with a progress ring) and hides itself when
/// nothing installs. Tapping it opens the download details. Each page adds its own item.
@interface LauncherInstallPill : UIButton
+ (UIBarButtonItem *)barButtonItem;
@end
