package org.lwjgl.sdl;

import java.nio.ByteBuffer;
import java.util.HashMap;
import java.util.Map;

import static org.lwjgl.glfw.GLFW.*;
import static org.lwjgl.sdl.SDLKeycode.*;
import static org.lwjgl.sdl.SDLScancode.*;
import static org.lwjgl.system.MemoryUtil.*;

/**
 * Keyboard tables for the SDL3 compatibility layer (see {@link SDLShim}): GLFW key codes from the
 * Amethyst bridge to SDL scancodes, and SDL keycodes/names for a US layout (the layout the bridge
 * itself assumes when it turns on-screen and hardware keys into GLFW keys).
 */
final class SDLKeys {

    private SDLKeys() {}

    private static final int[] GLFW_TO_SCANCODE = new int[GLFW_KEY_LAST + 1];
    /** Unshifted / shifted characters produced by a scancode on a US layout. */
    private static final char[] PLAIN = new char[SDL_SCANCODE_COUNT];
    private static final char[] SHIFTED = new char[SDL_SCANCODE_COUNT];
    private static final String[] NAMES = new String[SDL_SCANCODE_COUNT];
    private static final Map<Integer, ByteBuffer> NAME_BUFFERS = new HashMap<Integer, ByteBuffer>();

    private static void key(int glfw, int scancode, char plain, char shifted, String name) {
        if (glfw >= 0) {
            GLFW_TO_SCANCODE[glfw] = scancode;
        }
        PLAIN[scancode] = plain;
        SHIFTED[scancode] = shifted;
        NAMES[scancode] = name;
    }

    private static void key(int glfw, int scancode, String name) {
        key(glfw, scancode, '\0', '\0', name);
    }

    static {
        for (int i = 0; i < 26; i++) {
            char c = (char) ('a' + i);
            key(GLFW_KEY_A + i, SDL_SCANCODE_A + i, c, Character.toUpperCase(c), String.valueOf(Character.toUpperCase(c)));
        }
        String digitsShifted = ")!@#$%^&*(";
        for (int i = 1; i <= 9; i++) {
            key(GLFW_KEY_0 + i, SDL_SCANCODE_1 + i - 1, (char) ('0' + i), digitsShifted.charAt(i), String.valueOf(i));
        }
        key(GLFW_KEY_0, SDL_SCANCODE_0, '0', ')', "0");

        key(GLFW_KEY_ENTER, SDL_SCANCODE_RETURN, '\r', '\r', "Return");
        key(GLFW_KEY_ESCAPE, SDL_SCANCODE_ESCAPE, (char) 0x1B, (char) 0x1B, "Escape");
        key(GLFW_KEY_BACKSPACE, SDL_SCANCODE_BACKSPACE, '\b', '\b', "Backspace");
        key(GLFW_KEY_TAB, SDL_SCANCODE_TAB, '\t', '\t', "Tab");
        key(GLFW_KEY_SPACE, SDL_SCANCODE_SPACE, ' ', ' ', "Space");
        key(GLFW_KEY_MINUS, SDL_SCANCODE_MINUS, '-', '_', "-");
        key(GLFW_KEY_EQUAL, SDL_SCANCODE_EQUALS, '=', '+', "=");
        key(GLFW_KEY_LEFT_BRACKET, SDL_SCANCODE_LEFTBRACKET, '[', '{', "[");
        key(GLFW_KEY_RIGHT_BRACKET, SDL_SCANCODE_RIGHTBRACKET, ']', '}', "]");
        key(GLFW_KEY_BACKSLASH, SDL_SCANCODE_BACKSLASH, '\\', '|', "\\");
        key(GLFW_KEY_SEMICOLON, SDL_SCANCODE_SEMICOLON, ';', ':', ";");
        key(GLFW_KEY_APOSTROPHE, SDL_SCANCODE_APOSTROPHE, '\'', '"', "'");
        key(GLFW_KEY_GRAVE_ACCENT, SDL_SCANCODE_GRAVE, '`', '~', "`");
        key(GLFW_KEY_COMMA, SDL_SCANCODE_COMMA, ',', '<', ",");
        key(GLFW_KEY_PERIOD, SDL_SCANCODE_PERIOD, '.', '>', ".");
        key(GLFW_KEY_SLASH, SDL_SCANCODE_SLASH, '/', '?', "/");
        key(GLFW_KEY_WORLD_1, SDL_SCANCODE_NONUSBACKSLASH, '\\', '|', "\\");
        key(GLFW_KEY_WORLD_2, SDL_SCANCODE_INTERNATIONAL1, "International 1");

        key(GLFW_KEY_CAPS_LOCK, SDL_SCANCODE_CAPSLOCK, "CapsLock");
        for (int i = 0; i < 12; i++) {
            key(GLFW_KEY_F1 + i, SDL_SCANCODE_F1 + i, "F" + (i + 1));
        }
        for (int i = 0; i < 12; i++) {
            key(GLFW_KEY_F13 + i, SDL_SCANCODE_F13 + i, "F" + (i + 13));
        }
        key(GLFW_KEY_PRINT_SCREEN, SDL_SCANCODE_PRINTSCREEN, "PrintScreen");
        key(GLFW_KEY_SCROLL_LOCK, SDL_SCANCODE_SCROLLLOCK, "ScrollLock");
        key(GLFW_KEY_PAUSE, SDL_SCANCODE_PAUSE, "Pause");
        key(GLFW_KEY_INSERT, SDL_SCANCODE_INSERT, "Insert");
        key(GLFW_KEY_HOME, SDL_SCANCODE_HOME, "Home");
        key(GLFW_KEY_PAGE_UP, SDL_SCANCODE_PAGEUP, "PageUp");
        key(GLFW_KEY_DELETE, SDL_SCANCODE_DELETE, (char) 0x7F, (char) 0x7F, "Delete");
        key(GLFW_KEY_END, SDL_SCANCODE_END, "End");
        key(GLFW_KEY_PAGE_DOWN, SDL_SCANCODE_PAGEDOWN, "PageDown");
        key(GLFW_KEY_RIGHT, SDL_SCANCODE_RIGHT, "Right");
        key(GLFW_KEY_LEFT, SDL_SCANCODE_LEFT, "Left");
        key(GLFW_KEY_DOWN, SDL_SCANCODE_DOWN, "Down");
        key(GLFW_KEY_UP, SDL_SCANCODE_UP, "Up");

        key(GLFW_KEY_NUM_LOCK, SDL_SCANCODE_NUMLOCKCLEAR, "Numlock");
        key(GLFW_KEY_KP_DIVIDE, SDL_SCANCODE_KP_DIVIDE, "Keypad /");
        key(GLFW_KEY_KP_MULTIPLY, SDL_SCANCODE_KP_MULTIPLY, "Keypad *");
        key(GLFW_KEY_KP_SUBTRACT, SDL_SCANCODE_KP_MINUS, "Keypad -");
        key(GLFW_KEY_KP_ADD, SDL_SCANCODE_KP_PLUS, "Keypad +");
        key(GLFW_KEY_KP_ENTER, SDL_SCANCODE_KP_ENTER, "Keypad Enter");
        for (int i = 1; i <= 9; i++) {
            key(GLFW_KEY_KP_0 + i, SDL_SCANCODE_KP_1 + i - 1, "Keypad " + i);
        }
        key(GLFW_KEY_KP_0, SDL_SCANCODE_KP_0, "Keypad 0");
        key(GLFW_KEY_KP_DECIMAL, SDL_SCANCODE_KP_PERIOD, "Keypad .");
        key(GLFW_KEY_KP_EQUAL, SDL_SCANCODE_KP_EQUALS, "Keypad =");
        key(GLFW_KEY_MENU, SDL_SCANCODE_APPLICATION, "Application");

        key(GLFW_KEY_LEFT_CONTROL, SDL_SCANCODE_LCTRL, "Left Ctrl");
        key(GLFW_KEY_LEFT_SHIFT, SDL_SCANCODE_LSHIFT, "Left Shift");
        key(GLFW_KEY_LEFT_ALT, SDL_SCANCODE_LALT, "Left Alt");
        key(GLFW_KEY_LEFT_SUPER, SDL_SCANCODE_LGUI, "Left GUI");
        key(GLFW_KEY_RIGHT_CONTROL, SDL_SCANCODE_RCTRL, "Right Ctrl");
        key(GLFW_KEY_RIGHT_SHIFT, SDL_SCANCODE_RSHIFT, "Right Shift");
        key(GLFW_KEY_RIGHT_ALT, SDL_SCANCODE_RALT, "Right Alt");
        key(GLFW_KEY_RIGHT_SUPER, SDL_SCANCODE_RGUI, "Right GUI");
    }

    static int glfwKeyToScancode(int glfwKey) {
        return glfwKey >= 0 && glfwKey < GLFW_TO_SCANCODE.length ? GLFW_TO_SCANCODE[glfwKey] : SDL_SCANCODE_UNKNOWN;
    }

    static int modifierForScancode(int scancode) {
        if (scancode == SDL_SCANCODE_LSHIFT) return SDL_KMOD_LSHIFT;
        if (scancode == SDL_SCANCODE_RSHIFT) return SDL_KMOD_RSHIFT;
        if (scancode == SDL_SCANCODE_LCTRL) return SDL_KMOD_LCTRL;
        if (scancode == SDL_SCANCODE_RCTRL) return SDL_KMOD_RCTRL;
        if (scancode == SDL_SCANCODE_LALT) return SDL_KMOD_LALT;
        if (scancode == SDL_SCANCODE_RALT) return SDL_KMOD_RALT;
        if (scancode == SDL_SCANCODE_LGUI) return SDL_KMOD_LGUI;
        if (scancode == SDL_SCANCODE_RGUI) return SDL_KMOD_RGUI;
        return 0;
    }

    /**
     * SDL_GetKeyFromScancode: with {@code keyEvent} the key's own (unshifted) keycode, otherwise the
     * character the key produces with the given modifiers.
     */
    static int keyFromScancode(int scancode, int modstate, boolean keyEvent) {
        if (scancode <= SDL_SCANCODE_UNKNOWN || scancode >= SDL_SCANCODE_COUNT) {
            return SDLK_UNKNOWN;
        }
        char plain = PLAIN[scancode];
        if (plain == '\0') {
            return SDL_SCANCODE_TO_KEYCODE(scancode);
        }
        if (keyEvent) {
            return plain;
        }
        boolean shift = (modstate & SDL_KMOD_SHIFT) != 0;
        boolean letter = plain >= 'a' && plain <= 'z';
        if (letter && (modstate & SDL_KMOD_CAPS) != 0) {
            shift = !shift;
        }
        return shift ? SHIFTED[scancode] : plain;
    }

    static int scancodeFromKey(int key) {
        if ((key & SDLK_SCANCODE_MASK) != 0) {
            return key & ~SDLK_SCANCODE_MASK;
        }
        for (int scancode = 0; scancode < SDL_SCANCODE_COUNT; scancode++) {
            if (PLAIN[scancode] == key) {
                return scancode;
            }
        }
        return SDL_SCANCODE_UNKNOWN;
    }

    /** SDL_GetKeyName: printable keys are named by their (upper case) character. */
    static String keyName(int key) {
        if (key == SDLK_UNKNOWN) {
            return "";
        }
        int scancode = scancodeFromKey(key);
        if (scancode != SDL_SCANCODE_UNKNOWN && NAMES[scancode] != null) {
            return NAMES[scancode];
        }
        if ((key & SDLK_SCANCODE_MASK) == 0 && key > 32 && key < 0x110000) {
            return new String(Character.toChars(Character.toUpperCase(key)));
        }
        return "";
    }

    /** SDL_GetKeyName returns a string owned by SDL; keep one buffer per key for the whole run. */
    static long keyNamePointer(int key) {
        synchronized (NAME_BUFFERS) {
            ByteBuffer buffer = NAME_BUFFERS.get(key);
            if (buffer == null) {
                buffer = memUTF8(keyName(key), true);
                NAME_BUFFERS.put(key, buffer);
            }
            return memAddress(buffer);
        }
    }
}
