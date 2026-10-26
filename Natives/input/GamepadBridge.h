#pragma once

#import <GameController/GameController.h>

/*
 * Gamepad passthrough bridge.
 *
 * When passthrough is enabled, physical controllers are not translated into
 * keyboard/mouse events. Instead their raw state is exposed to Java through
 * the GLFW joystick/gamepad API (glfwJoystickPresent, glfwGetGamepadState,
 * glfwSetJoystickCallback, ...), the same way desktop GLFW would. Mods that
 * read controllers through GLFW (e.g. Controlify's GLFW fallback driver) then
 * see a real, standard-layout gamepad.
 *
 * Writers: GameController handlers (main queue).
 * Readers: the game thread, via the JNI functions in GamepadBridge.m.
 * All slot access is guarded by a single lock.
 */

// Matches GLFW_JOYSTICK_LAST + 1
#define GAMEPAD_BRIDGE_MAX_JOYSTICKS 16
#define GAMEPAD_BRIDGE_BUTTON_COUNT 15 // GLFW_GAMEPAD_BUTTON_LAST + 1
#define GAMEPAD_BRIDGE_AXIS_COUNT 6    // GLFW_GAMEPAD_AXIS_LAST + 1
#define GAMEPAD_BRIDGE_HAT_COUNT 1

/// Allocate a joystick slot for a newly connected controller and queue a
/// GLFW_CONNECTED event. Returns the jid, or -1 if every slot is in use.
int GamepadBridge_connect(GCController *controller);

/// Free the slot and queue a GLFW_DISCONNECTED event.
void GamepadBridge_disconnect(int jid);

/// Copy the full current state of `gamepad` into slot `jid`.
void GamepadBridge_updateFromGamepad(int jid, GCExtendedGamepad *gamepad);
