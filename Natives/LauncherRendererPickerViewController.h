#import <UIKit/UIKit.h>

/// Called with the picked preference value when a picker closes
typedef void (^PrefPickerDone)(NSString *key);
/// A pick field's custom picker: shown instead of the pop-up menu. `current` is the stored value.
typedef void (^PrefPickerOpener)(UIViewController *host, NSString *current, PrefPickerDone done);

/// Opener for a renderer pick field. `versionProvider` returns the Minecraft version id the choice is for (nil, or
/// returning nil, shows every renderer, as the global default has no version). `includeDefault` adds a "Launcher
/// default" row for per-instance settings.
PrefPickerOpener RendererPickerOpener(NSString *(^versionProvider)(void), BOOL includeDefault);

/// Renderer picker page: recommended choice first, the renderers that suit the version next, the rest behind
/// "Show all renderers".
@interface LauncherRendererPickerViewController : UITableViewController
- (instancetype)initWithSelectedKey:(NSString *)key versionId:(NSString *)versionId includeDefault:(BOOL)includeDefault done:(PrefPickerDone)done;
@end
