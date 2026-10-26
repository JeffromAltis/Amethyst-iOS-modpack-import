/*
 * Part of Amethyst iOS's SDL3 compatibility layer (see SDLShim). Implements the SDL gamepad API on top of
 * the GLFW joystick bridge, which exposes every GameController-backed pad in GLFW's standard gamepad layout.
 * SDL_JoystickID = GLFW joystick id + 1 (SDL ids are never 0). A gamepad handle is its id.
 */
package org.lwjgl.sdl;

import javax.annotation.*;

import java.nio.*;
import java.util.concurrent.*;

import org.lwjgl.glfw.GLFW;
import org.lwjgl.glfw.GLFWGamepadState;
import org.lwjgl.system.*;

import static org.lwjgl.system.MemoryUtil.*;

public class SDLGamepad {

    public static final int
        SDL_GAMEPAD_TYPE_UNKNOWN                      = 0,
        SDL_GAMEPAD_TYPE_STANDARD                     = 1,
        SDL_GAMEPAD_TYPE_XBOX360                      = 2,
        SDL_GAMEPAD_TYPE_XBOXONE                      = 3,
        SDL_GAMEPAD_TYPE_PS3                          = 4,
        SDL_GAMEPAD_TYPE_PS4                          = 5,
        SDL_GAMEPAD_TYPE_PS5                          = 6,
        SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_PRO          = 7,
        SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_LEFT  = 8,
        SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_RIGHT = 9,
        SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_PAIR  = 10,
        SDL_GAMEPAD_TYPE_GAMECUBE                     = 11,
        SDL_GAMEPAD_TYPE_COUNT                        = 12;

    public static final int
        SDL_GAMEPAD_BUTTON_INVALID        = -1,
        SDL_GAMEPAD_BUTTON_SOUTH          = 0,
        SDL_GAMEPAD_BUTTON_EAST           = 1,
        SDL_GAMEPAD_BUTTON_WEST           = 2,
        SDL_GAMEPAD_BUTTON_NORTH          = 3,
        SDL_GAMEPAD_BUTTON_BACK           = 4,
        SDL_GAMEPAD_BUTTON_GUIDE          = 5,
        SDL_GAMEPAD_BUTTON_START          = 6,
        SDL_GAMEPAD_BUTTON_LEFT_STICK     = 7,
        SDL_GAMEPAD_BUTTON_RIGHT_STICK    = 8,
        SDL_GAMEPAD_BUTTON_LEFT_SHOULDER  = 9,
        SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER = 10,
        SDL_GAMEPAD_BUTTON_DPAD_UP        = 11,
        SDL_GAMEPAD_BUTTON_DPAD_DOWN      = 12,
        SDL_GAMEPAD_BUTTON_DPAD_LEFT      = 13,
        SDL_GAMEPAD_BUTTON_DPAD_RIGHT     = 14,
        SDL_GAMEPAD_BUTTON_MISC1          = 15,
        SDL_GAMEPAD_BUTTON_RIGHT_PADDLE1  = 16,
        SDL_GAMEPAD_BUTTON_LEFT_PADDLE1   = 17,
        SDL_GAMEPAD_BUTTON_RIGHT_PADDLE2  = 18,
        SDL_GAMEPAD_BUTTON_LEFT_PADDLE2   = 19,
        SDL_GAMEPAD_BUTTON_TOUCHPAD       = 20,
        SDL_GAMEPAD_BUTTON_MISC2          = 21,
        SDL_GAMEPAD_BUTTON_MISC3          = 22,
        SDL_GAMEPAD_BUTTON_MISC4          = 23,
        SDL_GAMEPAD_BUTTON_MISC5          = 24,
        SDL_GAMEPAD_BUTTON_MISC6          = 25,
        SDL_GAMEPAD_BUTTON_COUNT          = 26;

    public static final int
        SDL_GAMEPAD_AXIS_INVALID       = -1,
        SDL_GAMEPAD_AXIS_LEFTX         = 0,
        SDL_GAMEPAD_AXIS_LEFTY         = 1,
        SDL_GAMEPAD_AXIS_RIGHTX        = 2,
        SDL_GAMEPAD_AXIS_RIGHTY        = 3,
        SDL_GAMEPAD_AXIS_LEFT_TRIGGER  = 4,
        SDL_GAMEPAD_AXIS_RIGHT_TRIGGER = 5,
        SDL_GAMEPAD_AXIS_COUNT         = 6;

    public static final int
        SDL_GAMEPAD_BINDTYPE_NONE   = 0,
        SDL_GAMEPAD_BINDTYPE_BUTTON = 1,
        SDL_GAMEPAD_BINDTYPE_AXIS   = 2,
        SDL_GAMEPAD_BINDTYPE_HAT    = 3;

    private static final int JOYSTICK_COUNT = 16;

    /** SDL button index to GLFW gamepad button index, -1 where the bridge's standard layout has no such button. */
    private static final int[] SDL_TO_GLFW_BUTTON = new int[SDL_GAMEPAD_BUTTON_COUNT];
    private static final String[] BUTTON_NAMES = {
        "a", "b", "x", "y", "back", "guide", "start", "leftstick", "rightstick", "leftshoulder", "rightshoulder",
        "dpup", "dpdown", "dpleft", "dpright", "misc1", "paddle1", "paddle2", "paddle3", "paddle4", "touchpad",
        "misc2", "misc3", "misc4", "misc5", "misc6"
    };
    private static final String[] AXIS_NAMES = {"leftx", "lefty", "rightx", "righty", "lefttrigger", "righttrigger"};

    static {
        java.util.Arrays.fill(SDL_TO_GLFW_BUTTON, -1);
        SDL_TO_GLFW_BUTTON[SDL_GAMEPAD_BUTTON_SOUTH] = GLFW.GLFW_GAMEPAD_BUTTON_A;
        SDL_TO_GLFW_BUTTON[SDL_GAMEPAD_BUTTON_EAST] = GLFW.GLFW_GAMEPAD_BUTTON_B;
        SDL_TO_GLFW_BUTTON[SDL_GAMEPAD_BUTTON_WEST] = GLFW.GLFW_GAMEPAD_BUTTON_X;
        SDL_TO_GLFW_BUTTON[SDL_GAMEPAD_BUTTON_NORTH] = GLFW.GLFW_GAMEPAD_BUTTON_Y;
        SDL_TO_GLFW_BUTTON[SDL_GAMEPAD_BUTTON_BACK] = GLFW.GLFW_GAMEPAD_BUTTON_BACK;
        SDL_TO_GLFW_BUTTON[SDL_GAMEPAD_BUTTON_GUIDE] = GLFW.GLFW_GAMEPAD_BUTTON_GUIDE;
        SDL_TO_GLFW_BUTTON[SDL_GAMEPAD_BUTTON_START] = GLFW.GLFW_GAMEPAD_BUTTON_START;
        SDL_TO_GLFW_BUTTON[SDL_GAMEPAD_BUTTON_LEFT_STICK] = GLFW.GLFW_GAMEPAD_BUTTON_LEFT_THUMB;
        SDL_TO_GLFW_BUTTON[SDL_GAMEPAD_BUTTON_RIGHT_STICK] = GLFW.GLFW_GAMEPAD_BUTTON_RIGHT_THUMB;
        SDL_TO_GLFW_BUTTON[SDL_GAMEPAD_BUTTON_LEFT_SHOULDER] = GLFW.GLFW_GAMEPAD_BUTTON_LEFT_BUMPER;
        SDL_TO_GLFW_BUTTON[SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER] = GLFW.GLFW_GAMEPAD_BUTTON_RIGHT_BUMPER;
        SDL_TO_GLFW_BUTTON[SDL_GAMEPAD_BUTTON_DPAD_UP] = GLFW.GLFW_GAMEPAD_BUTTON_DPAD_UP;
        SDL_TO_GLFW_BUTTON[SDL_GAMEPAD_BUTTON_DPAD_DOWN] = GLFW.GLFW_GAMEPAD_BUTTON_DPAD_DOWN;
        SDL_TO_GLFW_BUTTON[SDL_GAMEPAD_BUTTON_DPAD_LEFT] = GLFW.GLFW_GAMEPAD_BUTTON_DPAD_LEFT;
        SDL_TO_GLFW_BUTTON[SDL_GAMEPAD_BUTTON_DPAD_RIGHT] = GLFW.GLFW_GAMEPAD_BUTTON_DPAD_RIGHT;
    }

    protected SDLGamepad() {
        throw new UnsupportedOperationException();
    }

    // ---------------------------------------------------------------------------------------------
    // Ids and state

    private static int jidOf(int id) {
        int jid = id - 1;
        return jid >= 0 && jid < JOYSTICK_COUNT ? jid : -1;
    }

    private static boolean present(int id) {
        int jid = jidOf(id);
        return jid >= 0 && GLFW.glfwJoystickPresent(jid);
    }

    private static final ConcurrentHashMap<Integer, Boolean> OPEN = new ConcurrentHashMap<Integer, Boolean>();
    private static volatile boolean eventsEnabled = true;

    /** Reads a pad's state into a fresh snapshot, or null if it is gone. */
    @Nullable
    private static GLFWGamepadState readState(int id, GLFWGamepadState scratch) {
        int jid = jidOf(id);
        return jid >= 0 && GLFW.glfwGetGamepadState(jid, scratch) ? scratch : null;
    }

    private static short axisValue(GLFWGamepadState state, int sdlAxis) {
        if (sdlAxis < 0 || sdlAxis >= SDL_GAMEPAD_AXIS_COUNT) {
            return 0;
        }
        float value = state.axes(sdlAxis); // SDL and GLFW order the six axes identically
        if (sdlAxis >= SDL_GAMEPAD_AXIS_LEFT_TRIGGER) {
            value = (value + 1f) * 0.5f; // GLFW triggers rest at -1, SDL's at 0
            return (short) Math.round(Math.max(0f, Math.min(1f, value)) * 32767f);
        }
        return (short) Math.round(Math.max(-1f, Math.min(1f, value)) * 32767f);
    }

    private static boolean buttonValue(GLFWGamepadState state, int sdlButton) {
        if (sdlButton < 0 || sdlButton >= SDL_GAMEPAD_BUTTON_COUNT) {
            return false;
        }
        int glfwButton = SDL_TO_GLFW_BUTTON[sdlButton];
        if (glfwButton >= 0) {
            return state.buttons(glfwButton) != 0;
        }
        return false;
    }

    // ---------------------------------------------------------------------------------------------
    // Enumeration

    @NativeType("bool")
    public static boolean SDL_HasGamepad() {
        for (int jid = 0; jid < JOYSTICK_COUNT; jid++) {
            if (GLFW.glfwJoystickPresent(jid)) {
                return true;
            }
        }
        return false;
    }

    /** The ids of the connected gamepads. Release the result with {@link SDLStdinc#SDL_free(Buffer)}. */
    @Nullable
    @NativeType("SDL_JoystickID *")
    public static IntBuffer SDL_GetGamepads() {
        int[] ids = new int[JOYSTICK_COUNT];
        int count = 0;
        for (int jid = 0; jid < JOYSTICK_COUNT; jid++) {
            if (GLFW.glfwJoystickPresent(jid)) {
                ids[count++] = jid + 1;
            }
        }
        IntBuffer result = memAllocInt(count + 1); // zero-terminated, like SDL's array
        for (int i = 0; i < count; i++) {
            result.put(i, ids[i]);
        }
        result.put(count, 0);
        result.limit(count);
        return result;
    }

    @Nullable
    @NativeType("SDL_JoystickID *")
    public static IntBuffer SDL_GetGamepads(@Nullable @NativeType("int *") IntBuffer count) {
        IntBuffer ids = SDL_GetGamepads();
        if (count != null) {
            count.put(count.position(), ids.remaining());
        }
        return ids;
    }

    @NativeType("bool")
    public static boolean SDL_IsGamepad(@NativeType("SDL_JoystickID") int instance_id) {
        return present(instance_id);
    }

    // ---------------------------------------------------------------------------------------------
    // Open / close

    @NativeType("SDL_Gamepad *")
    public static long SDL_OpenGamepad(@NativeType("SDL_JoystickID") int instance_id) {
        if (!present(instance_id)) {
            SDLShim.fail("Gamepad " + instance_id + " is not connected");
            return NULL;
        }
        OPEN.put(instance_id, Boolean.TRUE);
        return instance_id;
    }

    public static void SDL_CloseGamepad(@NativeType("SDL_Gamepad *") long gamepad) {
        OPEN.remove((int) gamepad);
        stopRumble((int) gamepad);
    }

    @NativeType("SDL_Gamepad *")
    public static long SDL_GetGamepadFromID(@NativeType("SDL_JoystickID") int instance_id) {
        return OPEN.containsKey(instance_id) ? instance_id : NULL;
    }

    @NativeType("SDL_Gamepad *")
    public static long SDL_GetGamepadFromPlayerIndex(int player_index) {
        int id = player_index + 1;
        return OPEN.containsKey(id) ? id : NULL;
    }

    @NativeType("SDL_JoystickID")
    public static int SDL_GetGamepadID(@NativeType("SDL_Gamepad *") long gamepad) {
        return (int) gamepad;
    }

    @NativeType("bool")
    public static boolean SDL_GamepadConnected(@NativeType("SDL_Gamepad *") long gamepad) {
        return present((int) gamepad);
    }

    /** The joystick behind a gamepad; the joystick API is not provided, so this is the same handle. */
    @NativeType("SDL_Joystick *")
    public static long SDL_GetGamepadJoystick(@NativeType("SDL_Gamepad *") long gamepad) {
        return gamepad;
    }

    // ---------------------------------------------------------------------------------------------
    // Properties

    @Nullable
    @NativeType("char const *")
    public static String SDL_GetGamepadNameForID(@NativeType("SDL_JoystickID") int instance_id) {
        int jid = jidOf(instance_id);
        return jid >= 0 ? GLFW.glfwGetGamepadName(jid) : null;
    }

    @Nullable
    @NativeType("char const *")
    public static String SDL_GetGamepadName(@NativeType("SDL_Gamepad *") long gamepad) {
        return SDL_GetGamepadNameForID((int) gamepad);
    }

    @Nullable
    @NativeType("char const *")
    public static String SDL_GetGamepadPath(@NativeType("SDL_Gamepad *") long gamepad) {
        return null;
    }

    @NativeType("SDL_GamepadType")
    public static int SDL_GetGamepadTypeForID(@NativeType("SDL_JoystickID") int instance_id) {
        String name = SDL_GetGamepadNameForID(instance_id);
        if (name == null) {
            return SDL_GAMEPAD_TYPE_UNKNOWN;
        }
        String lower = name.toLowerCase(java.util.Locale.ROOT);
        if (lower.contains("dualsense")) return SDL_GAMEPAD_TYPE_PS5;
        if (lower.contains("dualshock") || lower.contains("ps4")) return SDL_GAMEPAD_TYPE_PS4;
        if (lower.contains("xbox")) return SDL_GAMEPAD_TYPE_XBOXONE;
        if (lower.contains("switch") || lower.contains("pro controller")) return SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_PRO;
        return SDL_GAMEPAD_TYPE_STANDARD;
    }

    @NativeType("SDL_GamepadType")
    public static int SDL_GetGamepadType(@NativeType("SDL_Gamepad *") long gamepad) {
        return SDL_GetGamepadTypeForID((int) gamepad);
    }

    @NativeType("SDL_GamepadType")
    public static int SDL_GetRealGamepadType(@NativeType("SDL_Gamepad *") long gamepad) {
        return SDL_GetGamepadTypeForID((int) gamepad);
    }

    @NativeType("SDL_GamepadType")
    public static int SDL_GetRealGamepadTypeForID(@NativeType("SDL_JoystickID") int instance_id) {
        return SDL_GetGamepadTypeForID(instance_id);
    }

    @NativeType("Uint16")
    public static short SDL_GetGamepadVendor(@NativeType("SDL_Gamepad *") long gamepad) {
        return 0;
    }

    @NativeType("Uint16")
    public static short SDL_GetGamepadProduct(@NativeType("SDL_Gamepad *") long gamepad) {
        return 0;
    }

    @NativeType("Uint16")
    public static short SDL_GetGamepadProductVersion(@NativeType("SDL_Gamepad *") long gamepad) {
        return 0;
    }

    public static int SDL_GetGamepadPlayerIndex(@NativeType("SDL_Gamepad *") long gamepad) {
        return (int) gamepad - 1;
    }

    public static int SDL_GetGamepadPlayerIndexForID(@NativeType("SDL_JoystickID") int instance_id) {
        return instance_id - 1;
    }

    @NativeType("bool")
    public static boolean SDL_SetGamepadPlayerIndex(@NativeType("SDL_Gamepad *") long gamepad, int player_index) {
        return true;
    }

    @Nullable
    @NativeType("char *")
    public static String SDL_GetGamepadMappingForID(@NativeType("SDL_JoystickID") int instance_id) {
        return null;
    }

    @Nullable
    @NativeType("char *")
    public static String SDL_GetGamepadMapping(@NativeType("SDL_Gamepad *") long gamepad) {
        return null;
    }

    /** Controllers are mapped natively by GameController, so added mappings are accepted and ignored. */
    public static int SDL_AddGamepadMapping(@NativeType("char const *") CharSequence mapping) {
        return 0;
    }

    public static int SDL_AddGamepadMappingsFromFile(@NativeType("char const *") CharSequence file) {
        return 0;
    }

    public static int SDL_ReloadGamepadMappings() {
        return 0;
    }

    @NativeType("SDL_JoystickConnectionState")
    public static int SDL_GetGamepadConnectionState(@NativeType("SDL_Gamepad *") long gamepad) {
        return present((int) gamepad) ? 2 /* SDL_JOYSTICK_CONNECTION_WIRELESS */ : 0;
    }

    @NativeType("SDL_PowerState")
    public static int SDL_GetGamepadPowerInfo(@NativeType("SDL_Gamepad *") long gamepad, @Nullable @NativeType("int *") IntBuffer percent) {
        if (percent != null) {
            percent.put(percent.position(), -1);
        }
        return 0; // SDL_POWERSTATE_UNKNOWN
    }

    // ---------------------------------------------------------------------------------------------
    // Input

    public static void SDL_UpdateGamepads() {
        pollEvents();
    }

    public static void SDL_SetGamepadEventsEnabled(@NativeType("bool") boolean enabled) {
        eventsEnabled = enabled;
    }

    @NativeType("bool")
    public static boolean SDL_GamepadEventsEnabled() {
        return eventsEnabled;
    }

    @NativeType("bool")
    public static boolean SDL_GamepadHasButton(@NativeType("SDL_Gamepad *") long gamepad, @NativeType("SDL_GamepadButton") int button) {
        return button >= 0 && button < SDL_GAMEPAD_BUTTON_COUNT && SDL_TO_GLFW_BUTTON[button] >= 0;
    }

    @NativeType("bool")
    public static boolean SDL_GamepadHasAxis(@NativeType("SDL_Gamepad *") long gamepad, @NativeType("SDL_GamepadAxis") int axis) {
        return axis >= 0 && axis < SDL_GAMEPAD_AXIS_COUNT;
    }

    @NativeType("bool")
    public static boolean SDL_GetGamepadButton(@NativeType("SDL_Gamepad *") long gamepad, @NativeType("SDL_GamepadButton") int button) {
        GLFWGamepadState state = GLFWGamepadState.malloc();
        try {
            return readState((int) gamepad, state) != null && buttonValue(state, button);
        } finally {
            state.free();
        }
    }

    @NativeType("Sint16")
    public static short SDL_GetGamepadAxis(@NativeType("SDL_Gamepad *") long gamepad, @NativeType("SDL_GamepadAxis") int axis) {
        GLFWGamepadState state = GLFWGamepadState.malloc();
        try {
            return readState((int) gamepad, state) != null ? axisValue(state, axis) : 0;
        } finally {
            state.free();
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Output (rumble only; LEDs, sensors, touchpads and trigger motors are not available)

    private static final ScheduledExecutorService RUMBLE_TIMER = Executors.newSingleThreadScheduledExecutor(new ThreadFactory() {
        @Override
        public Thread newThread(Runnable runnable) {
            Thread thread = new Thread(runnable, "SDLGamepad rumble");
            thread.setDaemon(true);
            return thread;
        }
    });
    private static final ConcurrentHashMap<Integer, ScheduledFuture<?>> RUMBLE_STOPS = new ConcurrentHashMap<Integer, ScheduledFuture<?>>();

    private static void stopRumble(final int id) {
        ScheduledFuture<?> pending = RUMBLE_STOPS.remove(id);
        if (pending != null) {
            pending.cancel(false);
        }
        int jid = jidOf(id);
        if (jid >= 0 && GLFW.amethystJoystickHasRumble(jid)) {
            GLFW.amethystSetJoystickRumble(jid, 0f, 0f);
        }
    }

    @NativeType("bool")
    public static boolean SDL_RumbleGamepad(@NativeType("SDL_Gamepad *") long gamepad, @NativeType("Uint16") short low_frequency_rumble, @NativeType("Uint16") short high_frequency_rumble, @NativeType("Uint32") int duration_ms) {
        final int id = (int) gamepad;
        int jid = jidOf(id);
        if (jid < 0 || !GLFW.amethystJoystickHasRumble(jid)) {
            return SDLShim.fail("That operation is not supported");
        }
        float strong = (low_frequency_rumble & 0xFFFF) / 65535f;
        float weak = (high_frequency_rumble & 0xFFFF) / 65535f;
        ScheduledFuture<?> pending = RUMBLE_STOPS.remove(id);
        if (pending != null) {
            pending.cancel(false);
        }
        if (strong == 0f && weak == 0f || duration_ms == 0) {
            GLFW.amethystSetJoystickRumble(jid, 0f, 0f);
            return true;
        }
        GLFW.amethystSetJoystickRumble(jid, strong, weak);
        // The bridge rumbles until told otherwise (or a few seconds), so end the effect when SDL's duration is up
        RUMBLE_STOPS.put(id, RUMBLE_TIMER.schedule(new Runnable() {
            @Override
            public void run() {
                RUMBLE_STOPS.remove(id);
                int pad = jidOf(id);
                if (pad >= 0) {
                    GLFW.amethystSetJoystickRumble(pad, 0f, 0f);
                }
            }
        }, duration_ms & 0xFFFFFFFFL, TimeUnit.MILLISECONDS));
        return true;
    }

    @NativeType("bool")
    public static boolean SDL_RumbleGamepadTriggers(@NativeType("SDL_Gamepad *") long gamepad, @NativeType("Uint16") short left_rumble, @NativeType("Uint16") short right_rumble, @NativeType("Uint32") int duration_ms) {
        return SDLShim.fail("That operation is not supported");
    }

    @NativeType("bool")
    public static boolean SDL_SetGamepadLED(@NativeType("SDL_Gamepad *") long gamepad, @NativeType("Uint8") byte red, @NativeType("Uint8") byte green, @NativeType("Uint8") byte blue) {
        return SDLShim.fail("That operation is not supported");
    }

    @NativeType("bool")
    public static boolean SDL_GamepadHasSensor(@NativeType("SDL_Gamepad *") long gamepad, @NativeType("SDL_SensorType") int type) {
        return false;
    }

    @NativeType("bool")
    public static boolean SDL_SetGamepadSensorEnabled(@NativeType("SDL_Gamepad *") long gamepad, @NativeType("SDL_SensorType") int type, @NativeType("bool") boolean enabled) {
        return SDLShim.fail("That operation is not supported");
    }

    @NativeType("bool")
    public static boolean SDL_GamepadSensorEnabled(@NativeType("SDL_Gamepad *") long gamepad, @NativeType("SDL_SensorType") int type) {
        return false;
    }

    public static int SDL_GetNumGamepadTouchpads(@NativeType("SDL_Gamepad *") long gamepad) {
        return 0;
    }

    // ---------------------------------------------------------------------------------------------
    // Names

    @NativeType("SDL_GamepadButton")
    public static int SDL_GetGamepadButtonFromString(@NativeType("char const *") CharSequence str) {
        String name = str.toString();
        for (int i = 0; i < BUTTON_NAMES.length; i++) {
            if (BUTTON_NAMES[i].equals(name)) {
                return i;
            }
        }
        return SDL_GAMEPAD_BUTTON_INVALID;
    }

    @Nullable
    @NativeType("char const *")
    public static String SDL_GetGamepadStringForButton(@NativeType("SDL_GamepadButton") int button) {
        return button >= 0 && button < BUTTON_NAMES.length ? BUTTON_NAMES[button] : null;
    }

    @NativeType("SDL_GamepadAxis")
    public static int SDL_GetGamepadAxisFromString(@NativeType("char const *") CharSequence str) {
        String name = str.toString();
        for (int i = 0; i < AXIS_NAMES.length; i++) {
            if (AXIS_NAMES[i].equals(name)) {
                return i;
            }
        }
        return SDL_GAMEPAD_AXIS_INVALID;
    }

    @Nullable
    @NativeType("char const *")
    public static String SDL_GetGamepadStringForAxis(@NativeType("SDL_GamepadAxis") int axis) {
        return axis >= 0 && axis < AXIS_NAMES.length ? AXIS_NAMES[axis] : null;
    }

    @NativeType("SDL_GamepadButtonLabel")
    public static int SDL_GetGamepadButtonLabel(@NativeType("SDL_Gamepad *") long gamepad, @NativeType("SDL_GamepadButton") int button) {
        return 0; // SDL_GAMEPAD_BUTTON_LABEL_UNKNOWN
    }

    // ---------------------------------------------------------------------------------------------
    // Events: connection changes and input changes are diffed once per event pump

    private static final boolean[] WAS_PRESENT = new boolean[JOYSTICK_COUNT];
    private static final short[][] LAST_AXES = new short[JOYSTICK_COUNT][SDL_GAMEPAD_AXIS_COUNT];
    private static final boolean[][] LAST_BUTTONS = new boolean[JOYSTICK_COUNT][SDL_GAMEPAD_BUTTON_COUNT];
    private static GLFWGamepadState pollState;

    /** Queues SDL gamepad events for whatever changed since the last pump. Called from SDLShim.pumpEvents. */
    static synchronized void pollEvents() {
        for (int jid = 0; jid < JOYSTICK_COUNT; jid++) {
            boolean isPresent = GLFW.glfwJoystickPresent(jid);
            int id = jid + 1;
            if (isPresent != WAS_PRESENT[jid]) {
                WAS_PRESENT[jid] = isPresent;
                java.util.Arrays.fill(LAST_AXES[jid], (short) 0);
                java.util.Arrays.fill(LAST_BUTTONS[jid], false);
                if (eventsEnabled) {
                    SDLShim.queueGamepadDeviceEvent(isPresent ? SDLEvents.SDL_EVENT_GAMEPAD_ADDED : SDLEvents.SDL_EVENT_GAMEPAD_REMOVED, id);
                }
                if (!isPresent) {
                    OPEN.remove(id);
                }
            }
            if (!isPresent || !eventsEnabled || !OPEN.containsKey(id)) {
                continue;
            }
            if (pollState == null) {
                pollState = GLFWGamepadState.calloc();
            }
            if (readState(id, pollState) == null) {
                continue;
            }
            for (int axis = 0; axis < SDL_GAMEPAD_AXIS_COUNT; axis++) {
                short value = axisValue(pollState, axis);
                if (value != LAST_AXES[jid][axis]) {
                    LAST_AXES[jid][axis] = value;
                    SDLShim.queueGamepadAxisEvent(id, axis, value);
                }
            }
            for (int button = 0; button < SDL_GAMEPAD_BUTTON_COUNT; button++) {
                if (SDL_TO_GLFW_BUTTON[button] < 0) {
                    continue;
                }
                boolean down = buttonValue(pollState, button);
                if (down != LAST_BUTTONS[jid][button]) {
                    LAST_BUTTONS[jid][button] = down;
                    SDLShim.queueGamepadButtonEvent(id, button, down);
                }
            }
        }
    }
}
