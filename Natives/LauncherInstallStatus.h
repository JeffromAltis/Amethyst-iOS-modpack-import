#import <UIKit/UIKit.h>

/// Posted on the main thread when the install status changes (at most a few times a second while downloading).
extern NSNotificationName const LauncherInstallStatusDidChangeNotification;

typedef NS_ENUM(NSInteger, LauncherInstallKind) {
    /// A modpack from the CurseForge/Modrinth list: its pack file is downloaded first
    LauncherInstallKindStorePack,
    /// A modpack file the user picked: it is read and checked first
    LauncherInstallKindImport,
    /// A version's game files, before playing
    LauncherInstallKindGameFiles,
};

/// The steps an install goes through, in order. Files are queued while the pack is extracted and its loader installed,
/// so they download in the background during those steps; the Files step is the wait for the last of them.
typedef NS_ENUM(NSInteger, LauncherInstallPhase) {
    LauncherInstallPhasePack,     // store: pack file download; import: reading and checking the file
    LauncherInstallPhaseExtract,  // configs and other files inside the pack
    LauncherInstallPhaseLoader,   // Forge/NeoForge installer
    LauncherInstallPhaseFiles,    // mods and game files
    LauncherInstallPhaseReady,
};

/// What the launcher is installing right now (a modpack, an import, or a version's game files), in a form every page
/// can show: the toolbar pill and its popover, the instance tile's caption and the line under the instance page's
/// Play button. Main thread only, except +enterPhase:.
@interface LauncherInstallStatus : NSObject

@property(class, nonatomic, readonly) LauncherInstallStatus *current;

@property(nonatomic, readonly) BOOL active;
@property(nonatomic, readonly) LauncherInstallKind kind;
/// What is being installed, e.g. "RLCraft" or an instance name.
@property(nonatomic, copy, readonly) NSString *title;
/// e.g. "v2.9.3 · 1.12.2 · from CurseForge"; nil when unknown.
@property(nonatomic, copy, readonly) NSString *subtitle;
/// Icon to show: an InstanceIcons key / URL / data string (see InstanceIcons +setIconString:...); nil for none.
@property(nonatomic, copy, readonly) NSString *iconString;
/// The instance (profile) being installed; nil until it is known (a modpack's instance is created part way through).
@property(nonatomic, copy, readonly) NSString *profileName;

/// The steps this install shows (game-file downloads skip the pack steps, and the loader step when none is needed).
@property(nonatomic, copy, readonly) NSArray<NSNumber *> *phases;
@property(nonatomic, readonly) LauncherInstallPhase phase;
/// The latest message of the current step, e.g. "Extracting files... 412 / 1830"; nil when there is none.
@property(nonatomic, copy, readonly) NSString *message;
/// The current step's own progress (0...1), or < 0 when unknown.
@property(nonatomic, readonly) double phaseFraction;

/// Downloads queued so far (the pack file is one during the Pack step).
@property(nonatomic, readonly) NSUInteger filesDone, filesTotal;
/// "120 MB of 290 MB"; nil before anything is known.
@property(nonatomic, copy, readonly) NSString *bytesText;

/// Short stage text for the pill and tile, e.g. "Files 87/187", "Extracting files... 412 / 1830".
@property(nonatomic, copy, readonly) NSString *stage;
/// Transfer details, e.g. "8.1 MB/s · 21 sec left"; nil when there are none.
@property(nonatomic, copy, readonly) NSString *detail;
/// Progress for the ring: the current step's (0...1), or < 0 when unknown.
@property(nonatomic, readonly) double fraction;

+ (NSString *)nameOfPhase:(LauncherInstallPhase)phase kind:(LauncherInstallKind)kind;

- (void)beginWithKind:(LauncherInstallKind)kind title:(NSString *)title subtitle:(NSString *)subtitle
    iconString:(NSString *)iconString profileName:(NSString *)profileName;
/// Game-file downloads: whether the loader step is shown (it is only when the loader still has to be installed).
- (void)setShowsLoaderPhase:(BOOL)shows;
/// Moves to a later step (never back). Any thread: it is applied on the main queue, in order with the
/// ModpackUtils status messages sent before it.
+ (void)enterPhase:(LauncherInstallPhase)phase;
/// A message of the current step, e.g. "Extracting files... 412 / 1830". fraction < 0 = unknown.
- (void)updateMessage:(NSString *)message fraction:(double)fraction;
/// Download progress. fraction is over all bytes queued so far, < 0 when unknown.
- (void)updateFilesDone:(NSUInteger)done total:(NSUInteger)total bytes:(NSString *)bytes
    transfer:(NSString *)transfer fraction:(double)fraction;
/// Called when a modpack's instance has been created: the tile and title follow it from then on.
- (void)setInstanceProfileName:(NSString *)profileName;
- (void)end;

@end

/// Toolbar pill that shows the current install ("RLCraft · Files 87/187" with a progress ring) and hides itself when
/// nothing installs. Tapping it opens the install popover. Each page adds its own item.
@interface LauncherInstallPill : UIButton
+ (UIBarButtonItem *)barButtonItem;
/// A pill to place in a view of your own (the home screen puts it next to its search field, which then shrinks).
/// It hides itself when nothing installs, so a stack view gives its space back.
+ (instancetype)pill;
/// Longest the pill grows (the name is cut short beyond it). Default 300.
@property(nonatomic) CGFloat maxWidth;
@end
