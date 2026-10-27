// GL entry points that the SDL3 compatibility layer (JavaApp org.lwjgl.sdl.SDLShim) hands to games
// in place of the renderer's own, for the one call whose honest behaviour breaks them on iOS
// (glGetFloatv). Texture uploads are not hooked: MobileGlues converts BGRA uploads itself.
// Only games that get their GL functions through SDL_GL_GetProcAddress (lwjgl3ify 3.x) see these.
//
// SDLShim passes the renderer's real functions in through amethyst_sdl_setGlFunction() before it
// hands out a hook, so the hook below has its real function set.

#include <string.h>

#define GL_ALIASED_LINE_WIDTH_RANGE     0x846E

typedef unsigned int GLenum;

typedef void (*gl_get_floatv_t)(GLenum pname, float *params);

static gl_get_floatv_t real_glGetFloatv;

__attribute__((used, visibility("default")))
void amethyst_sdl_setGlFunction(const char *name, void *function) {
    if (!name) return;
#define SET(fn, type) if (!strcmp(name, #fn)) { real_##fn = (type)function; return; }
    SET(glGetFloatv, gl_get_floatv_t)
#undef SET
}

// ---------------------------------------------------------------------------------------------
// glGetFloatv

// OpenGL ES on Metal (ANGLE) only draws 1 pixel wide lines and says so: GL_ALIASED_LINE_WIDTH_RANGE
// is [1, 1]. Angelica then emulates wide lines with geometry shaders, which OpenGL ES doesn't have,
// and the game crashes creating its first one. Report a wider range instead: glLineWidth accepts any
// positive width on ES, so wide lines are simply drawn 1 pixel wide.
__attribute__((used, visibility("default")))
void amethyst_sdl_glGetFloatv(GLenum pname, float *params) {
    real_glGetFloatv(pname, params);
    if (pname == GL_ALIASED_LINE_WIDTH_RANGE && params && params[1] <= 1.0f) {
        params[1] = 8.0f;
    }
}
