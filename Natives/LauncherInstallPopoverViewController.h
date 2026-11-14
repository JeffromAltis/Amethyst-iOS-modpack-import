#import <UIKit/UIKit.h>

@class MinecraftResourceDownloadTask;

/// The panel the install pill opens: what is installing, its steps (Pack · Extract · Loader · Files · Ready), the
/// current step's progress, size / speed / time left, the files downloading right now, Cancel, and the full file list.
/// Shows LauncherInstallStatus.current and closes itself when the install ends.
@interface LauncherInstallPopoverViewController : UIViewController

- (instancetype)initWithTask:(MinecraftResourceDownloadTask *)task;

/// Called after the user confirmed Cancel.
@property(nonatomic, copy) void (^cancelHandler)(void);

@end
