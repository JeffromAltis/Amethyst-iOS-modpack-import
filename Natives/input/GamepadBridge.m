#import "GamepadBridge.h"
#import "GamepadRumble.h"

#include <os/lock.h>
#include <stdbool.h>
#include <string.h>

#import "../utils.h"
#include "../glfw_keycodes.h"

// Connection events are encoded as (jid | EVENT_CONNECTED_FLAG) or just jid;
// GLFW.dispatchJoystickEvents() decodes them the same way.
#define EVENT_CONNECTED_FLAG 0x100
#define EVENT_QUEUE_SIZE 64

typedef struct {
    bool present;
    char name[128];
    char guid[33];
    unsigned char buttons[GAMEPAD_BRIDGE_BUTTON_COUNT];
    float axes[GAMEPAD_BRIDGE_AXIS_COUNT];
    unsigned char hats[GAMEPAD_BRIDGE_HAT_COUNT];
} GamepadSlot;

static GamepadSlot slots[GAMEPAD_BRIDGE_MAX_JOYSTICKS];
static os_unfair_lock slotLock = OS_UNFAIR_LOCK_INIT;
// Haptics per slot (nil when the controller can't rumble). Guarded by slotLock.
static __strong GamepadRumble *slotRumble[GAMEPAD_BRIDGE_MAX_JOYSTICKS];

// Connection events, drained by GLFW.glfwPollEvents() on the game thread.
static int eventQueue[EVENT_QUEUE_SIZE];
static int eventHead, eventCount;

static inline bool validJid(int jid) {
    return jid >= 0 && jid < GAMEPAD_BRIDGE_MAX_JOYSTICKS;
}

static void queueEventLocked(int jid, bool connected) {
    if (eventCount == EVENT_QUEUE_SIZE) {
        // Drop the oldest event; a full queue means nobody is listening anyway
        eventHead = (eventHead + 1) % EVENT_QUEUE_SIZE;
        eventCount--;
    }
    eventQueue[(eventHead + eventCount) % EVENT_QUEUE_SIZE] = jid | (connected ? EVENT_CONNECTED_FLAG : 0);
    eventCount++;
}

/// Neutral input state: nothing pressed, sticks centred, triggers released.
static void resetSlotState(GamepadSlot *slot) {
    memset(slot->buttons, 0, sizeof(slot->buttons));
    memset(slot->hats, GLFW_HAT_CENTERED, sizeof(slot->hats));
    for (int i = 0; i < GAMEPAD_BRIDGE_AXIS_COUNT; i++) {
        slot->axes[i] = 0.0f;
    }
    // GLFW reports released triggers as -1
    slot->axes[GLFW_GAMEPAD_AXIS_LEFT_TRIGGER] = -1.0f;
    slot->axes[GLFW_GAMEPAD_AXIS_RIGHT_TRIGGER] = -1.0f;
}

/**
 * GameController doesn't expose USB vendor/product IDs, so derive an
 * SDL2-style GUID from the product category. Bus 0x0005 = Bluetooth.
 */
static void makeGUID(GCController *controller, char out[33]) {
    unsigned short vendor = 0, product = 0;
    NSString *category = controller.productCategory;
    if ([category isEqualToString:@"Xbox One"]) {
        vendor = 0x045e; product = 0x02e0;
    } else if ([category isEqualToString:@"DualShock 4"]) {
        vendor = 0x054c; product = 0x09cc;
    } else if ([category isEqualToString:@"DualSense"]) {
        vendor = 0x054c; product = 0x0ce6;
    } else if ([category isEqualToString:@"Switch Pro Controller"]) {
        vendor = 0x057e; product = 0x2009;
    }
    snprintf(out, 33, "05000000%02x%02x0000%02x%02x000001000000",
        vendor & 0xff, vendor >> 8, product & 0xff, product >> 8);
}

int GamepadBridge_connect(GCController *controller) {
    if (!controller.extendedGamepad) {
        return -1;
    }

    NSString *name = controller.vendorName;
    if (name.length == 0) name = controller.productCategory;
    if (name.length == 0) name = @"Gamepad";

    char guid[33];
    makeGUID(controller, guid);
    // Set up haptics first so the slot is complete before the game hears about it
    GamepadRumble *rumble = [GamepadRumble rumbleForController:controller];

    int jid = -1;
    os_unfair_lock_lock(&slotLock);
    for (int i = 0; i < GAMEPAD_BRIDGE_MAX_JOYSTICKS; i++) {
        if (!slots[i].present) {
            jid = i;
            break;
        }
    }
    if (jid != -1) {
        GamepadSlot *slot = &slots[jid];
        strlcpy(slot->name, name.UTF8String, sizeof(slot->name));
        strlcpy(slot->guid, guid, sizeof(slot->guid));
        resetSlotState(slot);
        slot->present = true;
        slotRumble[jid] = rumble;
    }
    os_unfair_lock_unlock(&slotLock);

    if (jid == -1) {
        [rumble invalidate];
        NSLog(@"[GamepadBridge] No free joystick slot for \"%@\"", name);
        return -1;
    }

    // Fill in the initial state, then announce the joystick
    GamepadBridge_updateFromGamepad(jid, controller.extendedGamepad);
    os_unfair_lock_lock(&slotLock);
    queueEventLocked(jid, true);
    os_unfair_lock_unlock(&slotLock);
    NSLog(@"[GamepadBridge] Connected \"%@\" as joystick %d", name, jid);
    return jid;
}

void GamepadBridge_disconnect(int jid) {
    if (!validJid(jid)) return;
    GamepadRumble *rumble;
    os_unfair_lock_lock(&slotLock);
    BOOL wasPresent = slots[jid].present;
    if (wasPresent) {
        slots[jid].present = false;
        resetSlotState(&slots[jid]);
        queueEventLocked(jid, false);
    }
    rumble = slotRumble[jid];
    slotRumble[jid] = nil;
    os_unfair_lock_unlock(&slotLock);

    [rumble invalidate];
    if (wasPresent) {
        NSLog(@"[GamepadBridge] Disconnected joystick %d", jid);
    }
}

static inline unsigned char pressed(GCControllerButtonInput *button) {
    return (button && button.isPressed) ? 1 : 0;
}

void GamepadBridge_updateFromGamepad(int jid, GCExtendedGamepad *gamepad) {
    if (!validJid(jid) || !gamepad) return;

    // Read everything from GameController outside the lock
    unsigned char buttons[GAMEPAD_BRIDGE_BUTTON_COUNT] = {0};
    buttons[GLFW_GAMEPAD_BUTTON_A] = pressed(gamepad.buttonA);
    buttons[GLFW_GAMEPAD_BUTTON_B] = pressed(gamepad.buttonB);
    buttons[GLFW_GAMEPAD_BUTTON_X] = pressed(gamepad.buttonX);
    buttons[GLFW_GAMEPAD_BUTTON_Y] = pressed(gamepad.buttonY);
    buttons[GLFW_GAMEPAD_BUTTON_LEFT_BUMPER] = pressed(gamepad.leftShoulder);
    buttons[GLFW_GAMEPAD_BUTTON_RIGHT_BUMPER] = pressed(gamepad.rightShoulder);
    buttons[GLFW_GAMEPAD_BUTTON_BACK] = pressed(gamepad.buttonOptions);
    buttons[GLFW_GAMEPAD_BUTTON_START] = pressed(gamepad.buttonMenu);
    buttons[GLFW_GAMEPAD_BUTTON_GUIDE] = pressed(gamepad.buttonHome);
    buttons[GLFW_GAMEPAD_BUTTON_LEFT_THUMB] = pressed(gamepad.leftThumbstickButton);
    buttons[GLFW_GAMEPAD_BUTTON_RIGHT_THUMB] = pressed(gamepad.rightThumbstickButton);
    buttons[GLFW_GAMEPAD_BUTTON_DPAD_UP] = pressed(gamepad.dpad.up);
    buttons[GLFW_GAMEPAD_BUTTON_DPAD_RIGHT] = pressed(gamepad.dpad.right);
    buttons[GLFW_GAMEPAD_BUTTON_DPAD_DOWN] = pressed(gamepad.dpad.down);
    buttons[GLFW_GAMEPAD_BUTTON_DPAD_LEFT] = pressed(gamepad.dpad.left);

    float axes[GAMEPAD_BRIDGE_AXIS_COUNT];
    // GameController: up is +1. GLFW: up is -1.
    axes[GLFW_GAMEPAD_AXIS_LEFT_X] = gamepad.leftThumbstick.xAxis.value;
    axes[GLFW_GAMEPAD_AXIS_LEFT_Y] = -gamepad.leftThumbstick.yAxis.value;
    axes[GLFW_GAMEPAD_AXIS_RIGHT_X] = gamepad.rightThumbstick.xAxis.value;
    axes[GLFW_GAMEPAD_AXIS_RIGHT_Y] = -gamepad.rightThumbstick.yAxis.value;
    // GameController: 0..1. GLFW: -1 (released) .. 1 (fully pressed).
    axes[GLFW_GAMEPAD_AXIS_LEFT_TRIGGER] = gamepad.leftTrigger.value * 2.0f - 1.0f;
    axes[GLFW_GAMEPAD_AXIS_RIGHT_TRIGGER] = gamepad.rightTrigger.value * 2.0f - 1.0f;

    unsigned char hat = GLFW_HAT_CENTERED;
    if (buttons[GLFW_GAMEPAD_BUTTON_DPAD_UP]) hat |= GLFW_HAT_UP;
    if (buttons[GLFW_GAMEPAD_BUTTON_DPAD_RIGHT]) hat |= GLFW_HAT_RIGHT;
    if (buttons[GLFW_GAMEPAD_BUTTON_DPAD_DOWN]) hat |= GLFW_HAT_DOWN;
    if (buttons[GLFW_GAMEPAD_BUTTON_DPAD_LEFT]) hat |= GLFW_HAT_LEFT;

    os_unfair_lock_lock(&slotLock);
    GamepadSlot *slot = &slots[jid];
    if (slot->present) {
        memcpy(slot->buttons, buttons, sizeof(buttons));
        memcpy(slot->axes, axes, sizeof(axes));
        slot->hats[0] = hat;
    }
    os_unfair_lock_unlock(&slotLock);
}

#pragma mark - JNI (org.lwjgl.glfw.GLFW)

JNIEXPORT jboolean JNICALL
Java_org_lwjgl_glfw_GLFW_nglfwBridgeJoystickPresent(JNIEnv *env, jclass clazz, jint jid) {
    if (!validJid(jid)) return JNI_FALSE;
    os_unfair_lock_lock(&slotLock);
    bool present = slots[jid].present;
    os_unfair_lock_unlock(&slotLock);
    return present ? JNI_TRUE : JNI_FALSE;
}

static jstring copySlotString(JNIEnv *env, jint jid, bool wantGUID) {
    if (!validJid(jid)) return NULL;
    char buffer[128];
    os_unfair_lock_lock(&slotLock);
    bool present = slots[jid].present;
    if (present) {
        strlcpy(buffer, wantGUID ? slots[jid].guid : slots[jid].name, sizeof(buffer));
    }
    os_unfair_lock_unlock(&slotLock);
    return present ? (*env)->NewStringUTF(env, buffer) : NULL;
}

JNIEXPORT jstring JNICALL
Java_org_lwjgl_glfw_GLFW_nglfwBridgeGetJoystickName(JNIEnv *env, jclass clazz, jint jid) {
    return copySlotString(env, jid, false);
}

JNIEXPORT jstring JNICALL
Java_org_lwjgl_glfw_GLFW_nglfwBridgeGetJoystickGUID(JNIEnv *env, jclass clazz, jint jid) {
    return copySlotString(env, jid, true);
}

/**
 * Copy slot state into native memory owned by Java (direct buffers or a
 * GLFWGamepadState struct). Any address may be 0 to skip it.
 * When the joystick is absent, a neutral state is written and false returned.
 */
JNIEXPORT jboolean JNICALL
Java_org_lwjgl_glfw_GLFW_nglfwBridgeGetJoystickState(JNIEnv *env, jclass clazz, jint jid,
                                                     jlong buttonsAddr, jlong axesAddr, jlong hatsAddr) {
    GamepadSlot copy = {0};
    bool present = false;
    if (validJid(jid)) {
        os_unfair_lock_lock(&slotLock);
        copy = slots[jid];
        os_unfair_lock_unlock(&slotLock);
        present = copy.present;
    }
    if (!present) {
        resetSlotState(&copy);
    }

    if (buttonsAddr) memcpy((void *)(uintptr_t)buttonsAddr, copy.buttons, sizeof(copy.buttons));
    if (axesAddr) memcpy((void *)(uintptr_t)axesAddr, copy.axes, sizeof(copy.axes));
    if (hatsAddr) memcpy((void *)(uintptr_t)hatsAddr, copy.hats, sizeof(copy.hats));
    return present ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jint JNICALL
Java_org_lwjgl_glfw_GLFW_nglfwBridgePollJoystickEvent(JNIEnv *env, jclass clazz) {
    int event = -1;
    os_unfair_lock_lock(&slotLock);
    if (eventCount > 0) {
        event = eventQueue[eventHead];
        eventHead = (eventHead + 1) % EVENT_QUEUE_SIZE;
        eventCount--;
    }
    os_unfair_lock_unlock(&slotLock);
    return event;
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_GLFW_nglfwBridgeClearJoystickEvents(JNIEnv *env, jclass clazz) {
    os_unfair_lock_lock(&slotLock);
    eventHead = eventCount = 0;
    os_unfair_lock_unlock(&slotLock);
}

JNIEXPORT jboolean JNICALL
Java_org_lwjgl_glfw_GLFW_nglfwBridgeHasRumble(JNIEnv *env, jclass clazz, jint jid) {
    if (!validJid(jid)) return JNI_FALSE;
    os_unfair_lock_lock(&slotLock);
    BOOL hasRumble = slots[jid].present && slotRumble[jid] != nil;
    os_unfair_lock_unlock(&slotLock);
    return hasRumble ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_GLFW_nglfwBridgeSetRumble(JNIEnv *env, jclass clazz, jint jid, jfloat strong, jfloat weak) {
    if (!validJid(jid)) return;
    os_unfair_lock_lock(&slotLock);
    GamepadRumble *rumble = slots[jid].present ? slotRumble[jid] : nil;
    os_unfair_lock_unlock(&slotLock);
    [rumble setStrong:strong weak:weak]; // asynchronous, safe from the game thread
}
