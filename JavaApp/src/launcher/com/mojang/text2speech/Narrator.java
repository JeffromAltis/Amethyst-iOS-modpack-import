package com.mojang.text2speech;

/**
 * Stand-in for Mojang's text2speech library (found first on the classpath). The real one loads Flite, SAPI or
 * AppKit through JNA, none of which exist on iOS, so the narrator is always silent.
 * Covers both APIs: the old one (say(String, boolean)) and the one used since 1.19.x / 26.x
 * (say(String, boolean, float), EMPTY, InitializeException, FatalException).
 */
public interface Narrator {
    Narrator EMPTY = new NarratorDummy();

    /** Old API (Minecraft up to 1.19.3) */
    default void say(final String msg, final boolean interrupt) { }

    /** New API, with volume */
    default void say(final String msg, final boolean interrupt, final float volume) { }

    void clear();

    default boolean active() {
        return false;
    }

    void destroy();

    static Narrator getNarrator() {
        return new NarratorDummy();
    }

    static void setJNAPath(String sep) {
        System.setProperty("jna.library.path", System.getProperty("jna.library.path") + sep + "./src/natives/resources/");
        System.setProperty("jna.library.path", System.getProperty("jna.library.path") + sep + System.getProperty("java.library.path"));
    }

    class InitializeException extends Exception {
        public InitializeException(String message, Throwable cause) {
            super(message, cause);
        }

        public InitializeException(String message) {
            super(message);
        }
    }

    class FatalException extends RuntimeException {
        public FatalException(String message) {
            super(message);
        }
    }
}
