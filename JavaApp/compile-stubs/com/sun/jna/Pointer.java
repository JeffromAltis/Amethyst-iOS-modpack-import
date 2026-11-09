package com.sun.jna;

/**
 * Compile-only stand-in so the launcher's java-objc-bridge stubs can name JNA's Pointer type.
 * Never packaged (javac runs with -implicit:none); at runtime the real JNA from the game's libraries is used.
 */
public class Pointer {
    public Pointer(long peer) { }
}
