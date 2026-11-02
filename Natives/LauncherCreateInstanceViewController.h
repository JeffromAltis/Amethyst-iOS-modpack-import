#import <UIKit/UIKit.h>

/**
 * "New Instance" window, organised like Prism Launcher's: a list of sources on the left and the
 * matching page on the right. It only exposes what the launcher can already do:
 *   Custom     vanilla instance of any Minecraft version
 *   Fabric/Quilt, Forge   the existing loader installers
 *   Modrinth   the existing modpack browser
 *   Import     a modpack file (.mrpack, CurseForge .zip, Prism/MultiMC instance .zip)
 *
 * Present it inside a UINavigationController.
 */
@interface LauncherCreateInstanceViewController : UIViewController

/// Called on the main queue after the window is dismissed because an instance was created
/// (or an installer changed the profile list), with the name of the selected instance.
/// Open on the Import page instead of Custom (the home screen's "Import Modpack" button)
@property(nonatomic) BOOL startOnImport;
@property(nonatomic, copy) void (^onFinished)(NSString *selectedInstanceName);

@end
