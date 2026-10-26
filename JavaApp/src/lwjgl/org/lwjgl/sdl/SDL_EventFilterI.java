package org.lwjgl.sdl;

/**
 * SDL's event filter / watch callback ({@code SDL_EventFilter}). Same functional shape as LWJGL's
 * {@code SDL_EventFilterI}: {@code userdata} is the pointer given when the watch was added and
 * {@code event} points at an {@code SDL_Event}.
 */
@FunctionalInterface
public interface SDL_EventFilterI {
    boolean invoke(long userdata, long event);
}
