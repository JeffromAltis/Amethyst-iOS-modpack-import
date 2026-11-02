#import "KeyboardInput.h"
#import "../utils.h"

#include "../glfw_keycodes.h"

@implementation KeyboardInput

int keycodeTable[UIKeyboardHIDUsageKeyboardRightGUI+1];

+ (void)initKeycodeTable {
    for (int i = UIKeyboardHIDUsageKeyboardA; i <= UIKeyboardHIDUsageKeyboardZ; i++) {
        keycodeTable[i] = i - UIKeyboardHIDUsageKeyboardA + GLFW_KEY_A;
    }

    // 0-9 keys
    keycodeTable[UIKeyboardHIDUsageKeyboard0] = GLFW_KEY_0;
    for (int i = UIKeyboardHIDUsageKeyboard1; i <= UIKeyboardHIDUsageKeyboard9; i++) {
        keycodeTable[i] = i - UIKeyboardHIDUsageKeyboard1 + GLFW_KEY_1;
    }

    // Arrow keys
    keycodeTable[UIKeyboardHIDUsageKeyboardUpArrow] = GLFW_KEY_DPAD_UP;
    keycodeTable[UIKeyboardHIDUsageKeyboardDownArrow] = GLFW_KEY_DPAD_DOWN;
    keycodeTable[UIKeyboardHIDUsageKeyboardLeftArrow] = GLFW_KEY_DPAD_LEFT;
    keycodeTable[UIKeyboardHIDUsageKeyboardRightArrow] = GLFW_KEY_DPAD_RIGHT;

    keycodeTable[UIKeyboardHIDUsageKeyboardComma] = GLFW_KEY_COMMA;
    keycodeTable[UIKeyboardHIDUsageKeyboardPeriod] = GLFW_KEY_PERIOD;

    // Alt keys
    keycodeTable[UIKeyboardHIDUsageKeyboardLeftAlt] = GLFW_KEY_LEFT_ALT;
    keycodeTable[UIKeyboardHIDUsageKeyboardRightAlt] = GLFW_KEY_RIGHT_ALT;

    // Control keys
    keycodeTable[UIKeyboardHIDUsageKeyboardLeftControl] = GLFW_KEY_LEFT_CONTROL;
    keycodeTable[UIKeyboardHIDUsageKeyboardRightControl] = GLFW_KEY_RIGHT_CONTROL;

    // Shift keys
    keycodeTable[UIKeyboardHIDUsageKeyboardLeftShift] = GLFW_KEY_LEFT_SHIFT;
    keycodeTable[UIKeyboardHIDUsageKeyboardRightShift] = GLFW_KEY_RIGHT_SHIFT;

    // Bracket keys
    keycodeTable[UIKeyboardHIDUsageKeyboardOpenBracket] = GLFW_KEY_LEFT_BRACKET;
    keycodeTable[UIKeyboardHIDUsageKeyboardCloseBracket] = GLFW_KEY_RIGHT_BRACKET;

    // Slash keys
    keycodeTable[UIKeyboardHIDUsageKeyboardSlash] = GLFW_KEY_SLASH;
    keycodeTable[UIKeyboardHIDUsageKeyboardBackslash] = GLFW_KEY_BACKSLASH;

    // Page keys
    keycodeTable[UIKeyboardHIDUsageKeyboardPageUp] = GLFW_KEY_PAGE_UP;
    keycodeTable[UIKeyboardHIDUsageKeyboardPageDown] = GLFW_KEY_PAGE_DOWN;

    // Some other keys
    keycodeTable[UIKeyboardHIDUsageKeyboardHome] = GLFW_KEY_HOME;
    keycodeTable[UIKeyboardHIDUsageKeyboardEscape] = GLFW_KEY_ESCAPE;
    keycodeTable[UIKeyboardHIDUsageKeyboardTab] = GLFW_KEY_TAB;
    keycodeTable[UIKeyboardHIDUsageKeyboardReturnOrEnter] = GLFW_KEY_ENTER;
    keycodeTable[UIKeyboardHIDUsageKeyboardSpacebar] = GLFW_KEY_SPACE;
    keycodeTable[UIKeyboardHIDUsageKeyboardDeleteOrBackspace] = GLFW_KEY_BACKSPACE;
    keycodeTable[UIKeyboardHIDUsageKeyboardDeleteForward] = GLFW_KEY_DELETE;
    keycodeTable[UIKeyboardHIDUsageKeyboardGraveAccentAndTilde] = GLFW_KEY_GRAVE_ACCENT;

    keycodeTable[UIKeyboardHIDUsageKeyboardHyphen] = GLFW_KEY_MINUS;
    keycodeTable[UIKeyboardHIDUsageKeyboardEqualSign] = GLFW_KEY_EQUAL;
    keycodeTable[UIKeyboardHIDUsageKeyboardSemicolon] = GLFW_KEY_SEMICOLON;

    // Lock keys
    keycodeTable[UIKeyboardHIDUsageKeyboardCapsLock] = GLFW_KEY_CAPS_LOCK;
    keycodeTable[UIKeyboardHIDUsageKeypadNumLock] = GLFW_KEY_NUM_LOCK;
    keycodeTable[UIKeyboardHIDUsageKeyboardScrollLock] = GLFW_KEY_SCROLL_LOCK;

    // Numpad keys
    keycodeTable[UIKeyboardHIDUsageKeypadSlash] = GLFW_KEY_NUMPAD_DIVIDE;
    keycodeTable[UIKeyboardHIDUsageKeypadAsterisk] = GLFW_KEY_NUMPAD_MULTIPLY;
    keycodeTable[UIKeyboardHIDUsageKeypadHyphen] = GLFW_KEY_NUMPAD_SUBTRACT;
    keycodeTable[UIKeyboardHIDUsageKeypadPlus] = GLFW_KEY_NUMPAD_ADD;
    keycodeTable[UIKeyboardHIDUsageKeypadEnter] = GLFW_KEY_NUMPAD_ENTER;
    keycodeTable[UIKeyboardHIDUsageKeypadEqualSign] = GLFW_KEY_NUMPAD_EQUAL;
    keycodeTable[UIKeyboardHIDUsageKeypad0] = GLFW_KEY_NUMPAD_0;
    for (int i = UIKeyboardHIDUsageKeypad1; i <= UIKeyboardHIDUsageKeypad9; i++) {
        keycodeTable[i] = i - UIKeyboardHIDUsageKeypad1 + GLFW_KEY_NUMPAD_1;
    }

    // Function keys
    for (int i = UIKeyboardHIDUsageKeyboardF1; i <= UIKeyboardHIDUsageKeyboardF12; i++) {
        keycodeTable[i] = i - UIKeyboardHIDUsageKeyboardF1 + GLFW_KEY_F1;
    }
    for (int i = UIKeyboardHIDUsageKeyboardF13; i <= UIKeyboardHIDUsageKeyboardF24; i++) {
        keycodeTable[i] = i - UIKeyboardHIDUsageKeyboardF13 + GLFW_KEY_F13;
    }

    // Keys the table used to miss (apostrophe made ' unusable as a key bind)
    keycodeTable[UIKeyboardHIDUsageKeyboardQuote] = GLFW_KEY_APOSTROPHE;
    keycodeTable[UIKeyboardHIDUsageKeyboardEnd] = GLFW_KEY_END;
    keycodeTable[UIKeyboardHIDUsageKeyboardInsert] = GLFW_KEY_INSERT;
    keycodeTable[UIKeyboardHIDUsageKeyboardPrintScreen] = GLFW_KEY_PRINT_SCREEN;
    keycodeTable[UIKeyboardHIDUsageKeyboardPause] = GLFW_KEY_PAUSE;
    keycodeTable[UIKeyboardHIDUsageKeyboardNonUSBackslash] = GLFW_KEY_WORLD_1;
    keycodeTable[UIKeyboardHIDUsageKeyboardNonUSPound] = GLFW_KEY_BACKSLASH;
    keycodeTable[UIKeyboardHIDUsageKeypadPeriod] = GLFW_KEY_NUMPAD_DECIMAL;
    keycodeTable[UIKeyboardHIDUsageKeyboardApplication] = GLFW_KEY_MENU;
    keycodeTable[UIKeyboardHIDUsageKeyboardLeftGUI] = GLFW_KEY_LEFT_SUPER;
    keycodeTable[UIKeyboardHIDUsageKeyboardRightGUI] = GLFW_KEY_RIGHT_SUPER;
}

+ (BOOL)sendKeyEvent:(UIKey *)key down:(BOOL)isDown {
    char modifiers = 0;

    // convert UIKey's modifiers to GLFW
    if (key.modifierFlags & UIKeyModifierAlphaShift) {
        modifiers |= GLFW_MOD_CAPS_LOCK;
    }
    if (key.modifierFlags & UIKeyModifierShift) {
        modifiers |= GLFW_MOD_SHIFT;
    }
    if (key.modifierFlags & UIKeyModifierAlternate) {
        modifiers |= GLFW_MOD_ALT;
    }
    if (key.modifierFlags & UIKeyModifierControl) {
        modifiers |= GLFW_MOD_CONTROL;
    }

    // send the keycode
    if (key.keyCode < 0 || key.keyCode > UIKeyboardHIDUsageKeyboardRightGUI) {
        NSLog(@"KeyboardInput: key %ld outside the table", (long)key.keyCode);
        return isDown;
    }
    int keycode = keycodeTable[key.keyCode];
    // Option+` (or Cmd+`) acts as Esc: the Logitech Combo Touch has no Esc key (its top-left key is Home, which
    // iPadOS keeps), and iPadOS swallows Cmd+` on it, so Option+` is the one that reliably arrives.
    // The release is matched to the press, so letting go of Cmd first still releases Esc.
    static BOOL comboEscapeDown;
    if (key.keyCode == UIKeyboardHIDUsageKeyboardGraveAccentAndTilde &&
        (isDown ? (key.modifierFlags & (UIKeyModifierCommand | UIKeyModifierAlternate)) != 0 : comboEscapeDown)) {
        comboEscapeDown = isDown;
        CallbackBridge_nativeSendKey(GLFW_KEY_ESCAPE, 0, isDown, 0);
        return YES;
    }
    static int loggedKeys;
    if (isDown && loggedKeys++ < 60) {
        // which HID code each physical key sends (keyboards differ, e.g. Logitech Combo Touch)
        NSLog(@"KeyboardInput: key %ld -> GLFW %d chars=%@ mods=0x%lx", (long)key.keyCode, keycode,
            key.charactersIgnoringModifiers, (unsigned long)key.modifierFlags);
    }
    if (keycode != 0) {
        CallbackBridge_nativeSendKey(keycode, 0 /* scancode */, isDown, modifiers);
    } else {
        NSLog(@"KeyboardInput: Unhandled key %lu", (unsigned long)key.keyCode);
    }

    // key.characters.length < 11: skip sending characters if the string starts with UIKeyInput
    if (isDown && key.characters.length < 11) {
        for (int i = 0; i < key.characters.length; i++) {
            int keychar = [key.characters characterAtIndex:i];
            CallbackBridge_nativeSendCharMods(keychar, modifiers);
            CallbackBridge_nativeSendChar(keychar);
        }
    }

    return keycode != 0 || isDown;
}

@end
