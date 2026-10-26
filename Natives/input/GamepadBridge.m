#import "GamepadBridge.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <os/lock.h>
#include <stdbool.h>
#include <string.h>

#import "../utils.h"
#include "../glfw_keycodes.h"

#define GLFW_CONNECTED_EVENT    0x40001
#define GLFW_DISCONNECTED_EVENT 0x40002

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

// Connection events, drained by GLFW.glfwPollEvents() on the game thread.
// Encoded as (jid | (connected ? 0x100 : 0)).
static int eventQueue[EVENT_QUEUE_SIZE];
static int eventHead, eventCount;

static void queueEventLocked(int jid, bool connected) {
    if (eventCount == EVENT_QUEUE_SIZE) {
        // Drop the oldest event; a full queue means nobody is listening anyway
        eventHead = (eventHead + 1) % EVENT_QUEUE_SIZE;
        eventCount--;
    }
    eventQueue[(eventHead + eventCount) % EVENT_QUEUE_SIZE] = jid | (connected ? 0x100 : 0);
    eventCount++;
}

static void resetSlotStateLocked(GamepadSlot *slot) {
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
        resetSlotStateLocked(slot);
        slot->present = true;
        queueEventLocked(jid, true);
    }
    os_unfair_lock_unlock(&slotLock);

    if (jid != -1) {
        // Fill in the initial state so the first poll isn't all zeroes
        GamepadBridge_updateFromGamepad(jid, controller.extendedGamepad);
        NSLog(@"[GamepadBridge] Connected \"%@\" as joystick %d", name, jid);
    } else {
        NSLog(@"[GamepadBridge] No free joystick slot for \"%@\"", name);
    }
    return jid;
}

void GamepadBridge_disconnect(int jid) {
    if (jid < 0 || jid >= GAMEPAD_BRIDGE_MAX_JOYSTICKS) return;
    os_unfair_lock_lock(&slotLock);
    if (slots[jid].present) {
        slots[jid].present = false;
        resetSlotStateLocked(&slots[jid]);
        queueEventLocked(jid, false);
    }
    os_unfair_lock_unlock(&slotLock);
    NSLog(@"[GamepadBridge] Disconnected joystick %d", jid);
}

static inline unsigned char pressed(GCControllerButtonInput *button) {
    return (button && button.isPressed) ? 1 : 0;
}

void GamepadBridge_updateFromGamepad(int jid, GCExtendedGamepad *gamepad) {
    if (jid < 0 || jid >= GAMEPAD_BRIDGE_MAX_JOYSTICKS || !gamepad) return;

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

#pragma mark - SDL3 for Controlify

static char *preparedSDLPath;

// SDL3 constants (SDL_init.h / SDL_log.h), so we don't need SDL headers here
#define AME_SDL_INIT_JOYSTICK 0x00000200u
#define AME_SDL_INIT_GAMEPAD  0x00002000u
#define AME_SDL_INIT_EVENTS   0x00004000u
#define AME_SDL_LOG_PRIORITY_DEBUG 2

/// SDL logs to the Apple system log by default; send it to stderr instead so it
/// lands in Amethyst's latestlog.txt, tagged with the calling thread.
static void sdlLogToStderr(void *userdata, int category, int priority, const char *message) {
    fprintf(stderr, "[SDL3] [%s] %s\n", pthread_main_np() ? "main" : "bg", message);
    fflush(stderr);
}

void GamepadBridge_prepareSDL(void) {
    static BOOL attempted;
    if (attempted) return;
    attempted = YES;

    NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/libSDL3.dylib"];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        NSLog(@"[GamepadBridge] SDL3 not bundled, controller mods will use GLFW");
        return;
    }

    // Kept loaded for the process lifetime; JNA's later dlopen of the same path
    // returns this image, so everything set up here is what Controlify sees.
    void *handle = dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (!handle) {
        NSLog(@"[GamepadBridge] Failed to load SDL3: %s", dlerror());
        return;
    }
    void (*SDL_SetMainReady)(void) = dlsym(handle, "SDL_SetMainReady");
    bool (*SDL_SetHint)(const char *, const char *) = dlsym(handle, "SDL_SetHint");
    bool (*SDL_Init)(uint32_t) = dlsym(handle, "SDL_Init");
    const char *(*SDL_GetError)(void) = dlsym(handle, "SDL_GetError");
    void (*SDL_SetLogPriorities)(int) = dlsym(handle, "SDL_SetLogPriorities");
    void (*SDL_SetLogOutputFunction)(void *, void *) = dlsym(handle, "SDL_SetLogOutputFunction");
    if (!SDL_SetMainReady || !SDL_SetHint || !SDL_Init || !SDL_GetError) {
        NSLog(@"[GamepadBridge] SDL3 is missing expected symbols, not using it");
        return;
    }

    if (SDL_SetLogOutputFunction && SDL_SetLogPriorities) {
        SDL_SetLogOutputFunction((void *)sdlLogToStderr, NULL);
        SDL_SetLogPriorities(AME_SDL_LOG_PRIORITY_DEBUG);
    }

    // We're on the UIKit main thread: this is SDL's main thread from now on.
    SDL_SetMainReady();

    // The JVM owns SIGINT/SIGTERM; don't let SDL replace those handlers.
    SDL_SetHint("SDL_NO_SIGNAL_HANDLERS", "1");
    // Same hints Controlify sets, applied before init so they take effect here
    SDL_SetHint("SDL_JOYSTICK_ENHANCED_REPORTS", "1");
    SDL_SetHint("SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS", "1");

    // Start SDL's joystick layer here, on the main thread. Doing it from the game's
    // render thread (where Controlify calls SDL_Init) hung on iOS: SDL enumerates
    // GCControllers and registers GameController observers during init, which
    // GameController expects on the main thread. Controlify's own SDL_Init then
    // only bumps the reference counts of subsystems that are already running.
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    if (!SDL_Init(AME_SDL_INIT_JOYSTICK | AME_SDL_INIT_GAMEPAD | AME_SDL_INIT_EVENTS)) {
        NSLog(@"[GamepadBridge] SDL_Init failed: %s; controller mods will use GLFW", SDL_GetError());
        return;
    }
    NSLog(@"[GamepadBridge] SDL3 initialized on main thread in %.0f ms",
        (CFAbsoluteTimeGetCurrent() - start) * 1000.0);

    preparedSDLPath = strdup(path.UTF8String);
    NSLog(@"[GamepadBridge] Prepared SDL3 at %s", preparedSDLPath);
}

const char *GamepadBridge_SDLPath(void) {
    return preparedSDLPath;
}

#pragma mark - JNI (org.lwjgl.glfw.GLFW)

static inline bool validJid(jint jid) {
    return jid >= 0 && jid < GAMEPAD_BRIDGE_MAX_JOYSTICKS;
}

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
        resetSlotStateLocked(&copy);
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
