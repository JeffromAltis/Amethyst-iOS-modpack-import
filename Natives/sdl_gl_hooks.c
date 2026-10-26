// GL entry points that the SDL3 compatibility layer (JavaApp org.lwjgl.sdl.SDLShim) hands to games
// in place of the renderer's own, for the few queries whose honest answer breaks them on iOS.
// Only games that get their GL functions through SDL_GL_GetProcAddress (lwjgl3ify 3.x) see these.

#define GL_ALIASED_LINE_WIDTH_RANGE 0x846E

typedef void (*gl_get_floatv_t)(unsigned int pname, float *params);

static gl_get_floatv_t real_glGetFloatv;

__attribute__((used, visibility("default")))
void amethyst_sdl_setRealGlGetFloatv(void *function) {
    real_glGetFloatv = (gl_get_floatv_t)function;
}

// OpenGL ES on Metal (ANGLE) only draws 1 pixel wide lines and says so: GL_ALIASED_LINE_WIDTH_RANGE
// is [1, 1]. Angelica then emulates wide lines with geometry shaders, which OpenGL ES doesn't have,
// and the game crashes creating its first one. Report a wider range instead: glLineWidth accepts any
// positive width on ES, so wide lines are simply drawn 1 pixel wide.
__attribute__((used, visibility("default")))
void amethyst_sdl_glGetFloatv(unsigned int pname, float *params) {
    real_glGetFloatv(pname, params);
    if (pname == GL_ALIASED_LINE_WIDTH_RANGE && params && params[1] <= 1.0f) {
        params[1] = 8.0f;
    }
}
