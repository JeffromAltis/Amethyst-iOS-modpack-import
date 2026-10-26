#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

@interface ControllerInput : NSObject

/// YES when controllers should be passed to the game as raw GLFW gamepads
/// instead of being translated into keyboard/mouse input.
/// Resolved once per game session from the current profile (falls back to the
/// global "control.gamepad_passthrough" preference).
+ (BOOL)isPassthroughEnabled;

+ (void)initKeycodeTable;
+ (void)registerControllerCallbacks:(GCController *)controller;
+ (void)unregisterControllerCallbacks:(GCController *)controller;
+ (void)tick;
/// Call when the game grabs or releases the mouse, to release keys held by the
/// previous mode's mappings.
+ (void)grabStateChanged;

@end
