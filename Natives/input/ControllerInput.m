#import <objc/runtime.h>

#import "ControllerInput.h"
#import "GamepadBridge.h"
#import "GamepadMap.h"
#import "../PLProfiles.h"
#import "../SurfaceViewController.h"
#import "../utils.h"

#include "../glfw_keycodes.h"

// 8-way stick directions, counter-clockwise from east
#define DIRECTION_NONE -1
#define DIRECTION_EAST 0
#define DIRECTION_NORTH_EAST 1
#define DIRECTION_NORTH 2
#define DIRECTION_NORTH_WEST 3
#define DIRECTION_WEST 4
#define DIRECTION_SOUTH_WEST 5
#define DIRECTION_SOUTH 6
#define DIRECTION_SOUTH_EAST 7
#define STICK_DIRECTION_DEADZONE 0.3
#define MOUSE_MAX_ACCELERATION 2

#define MODE_MENU 0
#define MODE_GAME 1
#define MAX_ENTRIES 32

CFAbsoluteTime lastFrameTime;
CGFloat lastXValue; // lastHorizontalValue
CGFloat lastYValue; // lastVerticalValue
BOOL leftShiftHeld; // read by ControlJoystick (sneak + on-screen joystick)

// Translation state, mirroring Android's GamepadMap/GamepadButton.
// Indexed by [mode][catalog index]. Only touched on the main queue.
static BOOL mapLoaded;
static int entryCount;
static int entryKeycodes[2][MAX_ENTRIES][GAMEPAD_MAP_KEYCODE_COUNT];
static BOOL entryToggleable[2][MAX_ENTRIES];
static BOOL entryDown[2][MAX_ENTRIES];
static BOOL entryToggled[2][MAX_ENTRIES];
static NSDictionary<NSNumber *, NSNumber *> *buttonToIndex; // gamepad_button -> catalog index
static int lastMode = -1;
static int lastStickDirection = DIRECTION_NONE;

@implementation ControllerInput

// Key for the GLFW joystick id assigned to a GCController in passthrough mode
static char kPassthroughJidKey;

+ (BOOL)isPassthroughEnabled {
    static BOOL resolved, enabled;
    if (!resolved) {
        resolved = YES;
        enabled = [[PLProfiles resolveKeyForCurrentProfile:@"gamepadPassthrough"] boolValue];
        NSLog(@"Input: Gamepad passthrough %@", enabled ? @"enabled" : @"disabled");
    }
    return enabled;
}

+ (void)registerPassthroughController:(GCController *)controller {
    if (objc_getAssociatedObject(controller, &kPassthroughJidKey)) {
        // Already registered
        return;
    }
    int jid = GamepadBridge_connect(controller);
    if (jid < 0) {
        return;
    }
    objc_setAssociatedObject(controller, &kPassthroughJidKey, @(jid), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // One handler for every element: snapshot the whole gamepad on any change.
    // Nothing is translated to keyboard/mouse; the game reads it through GLFW.
    controller.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *gamepad, GCControllerElement *element) {
        GamepadBridge_updateFromGamepad(jid, gamepad);
    };
}

+ (void)unregisterPassthroughController:(GCController *)controller {
    NSNumber *jid = objc_getAssociatedObject(controller, &kPassthroughJidKey);
    if (!jid) {
        return;
    }
    controller.extendedGamepad.valueChangedHandler = nil;
    GamepadBridge_disconnect(jid.intValue);
    objc_setAssociatedObject(controller, &kPassthroughJidKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Keyboard/mouse translation

+ (void)initKeycodeTable {
    if (mapLoaded) {
        return;
    }
    mapLoaded = YES;

    NSString *controlFile = [PLProfiles resolveKeyForCurrentProfile:@"defaultGamepadCtrl"];
    NSString *gamepadPath = [NSString stringWithFormat:@"%s/controlmap/gamepads/%@", getenv("AME_HOME"), controlFile];
    NSMutableDictionary *map = GamepadMap_loadFile(gamepadPath);
    if (!map) {
        NSLog(@"Input: Could not read gamepad mapping %@, using an empty one", controlFile);
        map = [NSMutableDictionary dictionary];
        GamepadMap_normalize(map);
    }

    NSArray *catalog = GamepadMap_catalog();
    entryCount = (int)MIN(catalog.count, MAX_ENTRIES);
    NSMutableDictionary *indices = [NSMutableDictionary dictionary];
    for (int i = 0; i < entryCount; i++) {
        indices[catalog[i][@"button"]] = @(i);
    }
    buttonToIndex = indices;

    NSArray *lists[2] = {map[@"mMenuMappingList"], map[@"mGameMappingList"]};
    for (int mode = 0; mode < 2; mode++) {
        // Lists are normalized to catalog order
        for (int i = 0; i < entryCount; i++) {
            NSDictionary *entry = lists[mode][i];
            for (int k = 0; k < GAMEPAD_MAP_KEYCODE_COUNT; k++) {
                entryKeycodes[mode][i][k] = [entry[@"keycodes"][k] intValue];
            }
            entryToggleable[mode][i] = [entry[@"toggleable"] boolValue];
        }
    }
}

static void sendInput(const int *keycodes, BOOL isDown) {
    for (int k = 0; k < GAMEPAD_MAP_KEYCODE_COUNT; k++) {
        int keycode = keycodes[k];
        switch (keycode) {
            case 0:
                break;
            case SPECIALBTN_SCROLLUP:
                if (isDown) CallbackBridge_nativeSendScroll(0, 1);
                break;
            case SPECIALBTN_SCROLLDOWN:
                if (isDown) CallbackBridge_nativeSendScroll(0, -1);
                break;
            case SPECIALBTN_MOUSEPRI:
                CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, isDown, 0);
                break;
            case SPECIALBTN_MOUSESEC:
                CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_RIGHT, isDown, 0);
                break;
            case SPECIALBTN_MOUSEMID:
                CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_MIDDLE, isDown, 0);
                break;
            default:
                if (keycode > 0) {
                    if (keycode == GLFW_KEY_LEFT_SHIFT) leftShiftHeld = isDown;
                    CallbackBridge_nativeSendKey(keycode, 0, isDown, 0);
                }
                break;
        }
    }
}

static int currentMode(void) {
    return isGrabbing ? MODE_GAME : MODE_MENU;
}

/// Release everything held or toggled in a mode (Android's resetPressedState)
static void resetMode(int mode) {
    for (int i = 0; i < entryCount; i++) {
        if (entryDown[mode][i] || entryToggled[mode][i]) {
            sendInput(entryKeycodes[mode][i], NO);
        }
        entryDown[mode][i] = NO;
        entryToggled[mode][i] = NO;
    }
}

static void syncMode(void) {
    int mode = currentMode();
    if (lastMode != -1 && lastMode != mode) {
        resetMode(lastMode);
        lastStickDirection = DIRECTION_NONE;
    }
    lastMode = mode;
}

/// Android's GamepadEmulatedButton/GamepadButton update()
static void updateEntry(int index, BOOL isDown) {
    if (index < 0 || index >= entryCount) return;
    syncMode();
    int mode = currentMode();
    if (entryDown[mode][index] == isDown) return;
    entryDown[mode][index] = isDown;

    if (entryToggleable[mode][index]) {
        if (!isDown) return;
        entryToggled[mode][index] = !entryToggled[mode][index];
        sendInput(entryKeycodes[mode][index], entryToggled[mode][index]);
        return;
    }
    sendInput(entryKeycodes[mode][index], isDown);
}

static void updateButton(int gamepadButton, BOOL isDown) {
    NSNumber *index = buttonToIndex[@(gamepadButton)];
    if (index) updateEntry(index.intValue, isDown);
}

static int stickDirection(float x, float y) {
    if (x * x + y * y < STICK_DIRECTION_DEADZONE * STICK_DIRECTION_DEADZONE) {
        return DIRECTION_NONE;
    }
    float degree = atan2f(y, x) * (180.0 / M_PI);
    if (degree < 0) degree += 360;
    return (int)((degree + 22.5) / 45.0) % 8;
}

/// Press/release the four direction entries for an 8-way stick direction
static void updateDirections(int direction) {
    if (direction == lastStickDirection) return;
    lastStickDirection = direction;
    BOOL forward = direction == DIRECTION_NORTH_WEST || direction == DIRECTION_NORTH || direction == DIRECTION_NORTH_EAST;
    BOOL backward = direction == DIRECTION_SOUTH_WEST || direction == DIRECTION_SOUTH || direction == DIRECTION_SOUTH_EAST;
    BOOL right = direction == DIRECTION_NORTH_EAST || direction == DIRECTION_EAST || direction == DIRECTION_SOUTH_EAST;
    BOOL left = direction == DIRECTION_NORTH_WEST || direction == DIRECTION_WEST || direction == DIRECTION_SOUTH_WEST;
    updateButton(GAMEPAD_DIRECTION_FORWARD, forward);
    updateButton(GAMEPAD_DIRECTION_BACKWARD, backward);
    updateButton(GAMEPAD_DIRECTION_RIGHT, right);
    updateButton(GAMEPAD_DIRECTION_LEFT, left);
}

+ (void)grabStateChanged {
    if (!mapLoaded || self.isPassthroughEnabled) return;
    syncMode();
}

+ (void)registerControllerCallbacks:(GCController *)controller {
    if (self.isPassthroughEnabled) {
        [self registerPassthroughController:controller];
        return;
    }
    [self initKeycodeTable];

    GCExtendedGamepad *gamepad = controller.extendedGamepad;

#define BIND_BUTTON(ELEMENT, GLFW_BUTTON) \
    gamepad.ELEMENT.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) { \
        updateButton(GLFW_BUTTON, pressed); \
    };
    BIND_BUTTON(leftShoulder, GLFW_GAMEPAD_BUTTON_LEFT_BUMPER)
    BIND_BUTTON(rightShoulder, GLFW_GAMEPAD_BUTTON_RIGHT_BUMPER)
    BIND_BUTTON(leftTrigger, GLFW_GAMEPAD_BUTTON_LEFT_TRIGGER)
    BIND_BUTTON(rightTrigger, GLFW_GAMEPAD_BUTTON_RIGHT_TRIGGER)
    BIND_BUTTON(buttonOptions, GLFW_GAMEPAD_BUTTON_BACK)
    BIND_BUTTON(buttonMenu, GLFW_GAMEPAD_BUTTON_START)
    BIND_BUTTON(buttonA, GLFW_GAMEPAD_BUTTON_A)
    BIND_BUTTON(buttonB, GLFW_GAMEPAD_BUTTON_B)
    BIND_BUTTON(buttonX, GLFW_GAMEPAD_BUTTON_X)
    BIND_BUTTON(buttonY, GLFW_GAMEPAD_BUTTON_Y)
    BIND_BUTTON(dpad.up, GLFW_GAMEPAD_BUTTON_DPAD_UP)
    BIND_BUTTON(dpad.down, GLFW_GAMEPAD_BUTTON_DPAD_DOWN)
    BIND_BUTTON(dpad.left, GLFW_GAMEPAD_BUTTON_DPAD_LEFT)
    BIND_BUTTON(dpad.right, GLFW_GAMEPAD_BUTTON_DPAD_RIGHT)
    BIND_BUTTON(leftThumbstickButton, GLFW_GAMEPAD_BUTTON_LEFT_THUMB)
    BIND_BUTTON(rightThumbstickButton, GLFW_GAMEPAD_BUTTON_RIGHT_THUMB)
#undef BIND_BUTTON

    // As on Android: in game the left stick moves (direction mappings) and the
    // right stick looks; in menus the left stick drives the cursor and the
    // right stick uses the direction mappings (scrolling by default).
    gamepad.leftThumbstick.valueChangedHandler = ^(GCControllerDirectionPad *dpad, float xValue, float yValue) {
        if (isGrabbing) {
            updateDirections(stickDirection(xValue, yValue));
        } else {
            lastXValue = xValue;
            lastYValue = yValue;
        }
    };
    gamepad.rightThumbstick.valueChangedHandler = ^(GCControllerDirectionPad *dpad, float xValue, float yValue) {
        if (isGrabbing) {
            lastXValue = xValue;
            lastYValue = yValue;
        } else {
            updateDirections(stickDirection(xValue, yValue));
        }
    };
}

/**
 * Send the new mouse position, computing the delta
 */
+ (void)tick {
    if (self.isPassthroughEnabled) {
        // The game drives its own camera/cursor from the raw gamepad state
        return;
    }
    // There isn't a convenient way to get ns, use ms at this point
    CGFloat frameTime = CACurrentMediaTime();
    // GameController automatically performs deadzone calculations
    // so we just take the raw input
    if (lastFrameTime != 0 && (lastXValue != 0 || lastYValue != 0)) {
        CGFloat acceleration = pow(MathUtils_dist(0, 0, lastXValue, lastYValue), MOUSE_MAX_ACCELERATION); // magnitude
        if (acceleration > 1) acceleration = 1;

        // Compute delta since last tick time
        CGFloat deltaX = lastXValue * acceleration * 18;
        CGFloat deltaY = -lastYValue * acceleration * 18;
        CGFloat deltaTimeScale = (frameTime - lastFrameTime) / (1.0/60.0); // Scale of 1 = 60Hz
        deltaX *= deltaTimeScale;
        deltaY *= deltaTimeScale;

        SurfaceViewController *vc = (id)UIWindow.mainWindow.rootViewController;
        [vc sendTouchPoint:CGPointMake(deltaX, deltaY) withEvent:ACTION_MOVE_MOTION];
    }
    lastFrameTime = frameTime;
}

+ (void)unregisterControllerCallbacks:(GCController *)controller {
    if (self.isPassthroughEnabled) {
        [self unregisterPassthroughController:controller];
        return;
    }

    GCExtendedGamepad *gamepad = controller.extendedGamepad;
    gamepad.leftShoulder.pressedChangedHandler = nil;
    gamepad.rightShoulder.pressedChangedHandler = nil;
    gamepad.leftTrigger.pressedChangedHandler = nil;
    gamepad.rightTrigger.pressedChangedHandler = nil;
    gamepad.buttonOptions.pressedChangedHandler = nil;
    gamepad.buttonMenu.pressedChangedHandler = nil;
    gamepad.buttonHome.pressedChangedHandler = nil;
    gamepad.buttonA.pressedChangedHandler = nil;
    gamepad.buttonB.pressedChangedHandler = nil;
    gamepad.buttonX.pressedChangedHandler = nil;
    gamepad.buttonY.pressedChangedHandler = nil;
    gamepad.dpad.up.pressedChangedHandler = nil;
    gamepad.dpad.down.pressedChangedHandler = nil;
    gamepad.dpad.left.pressedChangedHandler = nil;
    gamepad.dpad.right.pressedChangedHandler = nil;
    gamepad.leftThumbstick.valueChangedHandler = nil;
    gamepad.rightThumbstick.valueChangedHandler = nil;
    gamepad.leftThumbstickButton.pressedChangedHandler = nil;
    gamepad.rightThumbstickButton.pressedChangedHandler = nil;

    // Don't leave keys stuck down
    if (mapLoaded) {
        resetMode(MODE_MENU);
        resetMode(MODE_GAME);
        lastStickDirection = DIRECTION_NONE;
        lastXValue = lastYValue = 0;
    }
}

@end
