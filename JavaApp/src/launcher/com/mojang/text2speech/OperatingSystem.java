package com.mojang.text2speech;

/**
 * Stand-in, see {@link Narrator}. The real get() reads os.name, which says "Mac" on iOS, and would send mods
 * (ModernFix's narrator fix, for one) towards macOS-only code; there is no system narrator here, so it is
 * always UNSUPPORTED.
 */
public enum OperatingSystem {
    LINUX,
    WINDOWS,
    MAC_OS,
    UNSUPPORTED;

    public static OperatingSystem get() {
        return UNSUPPORTED;
    }
}
