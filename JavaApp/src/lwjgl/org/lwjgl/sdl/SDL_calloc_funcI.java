package org.lwjgl.sdl;

/**
 * SDL's allocator callback, as passed to {@code SDL_SetMemoryFunctions}. The SDL3 compatibility layer
 * (see {@link SDLShim}) accepts but does not need custom allocators, so this is only the functional type.
 */
@FunctionalInterface
public interface SDL_calloc_funcI {
    long invoke(long nmemb, long size);
}
