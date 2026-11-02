#import <UIKit/UIKit.h>

/// "Pick icon" sheet, modelled on Prism Launcher's icon picker: category filter, search, an icon grid, and
/// Add Icon / Remove Icon / Open Folder. Present it inside a UINavigationController as a form sheet.
/// Tap selects, double-tap (or OK) picks. The current icon is highlighted and scrolled into view.
@interface LauncherIconPickerViewController : UIViewController

/// Called after the sheet has been dismissed with OK or a double-tap. Not called on Cancel.
@property(nonatomic, copy) void (^completion)(NSString *iconKey);

/// selectedKey: the instance's current icon key, or nil if it has none (or uses a download link).
- (instancetype)initWithSelectedKey:(NSString *)selectedKey;

@end
