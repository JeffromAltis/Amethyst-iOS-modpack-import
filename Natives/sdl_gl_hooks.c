// GL entry points that the SDL3 compatibility layer (JavaApp org.lwjgl.sdl.SDLShim) hands to games
// in place of the renderer's own, for the one call whose honest behaviour breaks them on iOS
// (glGetFloatv). Texture uploads are not hooked: MobileGlues converts BGRA uploads itself.
// Only games that get their GL functions through SDL_GL_GetProcAddress (lwjgl3ify 3.x) see these.
// amethyst_gl4es_* hooks are the exception: LWJGL 2 games on gl4es get them through
// JavaApp org.lwjgl.opengl.GLFunctionHooks.
//
// SDLShim passes the renderer's real functions in through amethyst_sdl_setGlFunction() before it
// hands out a hook, so the hook below has its real function set.

#include <string.h>

#define GL_ALIASED_LINE_WIDTH_RANGE     0x846E
#define GL_MAX_ATTRIB_STACK_DEPTH        0x0D35
#define GL_MAX_CLIENT_ATTRIB_STACK_DEPTH 0x0D3B

typedef unsigned int GLenum;

typedef void (*gl_get_floatv_t)(GLenum pname, float *params);
typedef void (*gl_get_integerv_t)(GLenum pname, int *params);
typedef GLenum (*gl_get_error_t)(void);

static gl_get_floatv_t real_glGetFloatv;
static gl_get_integerv_t real_glGetIntegerv;
static gl_get_error_t real_glGetError;

__attribute__((used, visibility("default")))
void amethyst_sdl_setGlFunction(const char *name, void *function) {
    if (!name) return;
#define SET(fn, type) if (!strcmp(name, #fn)) { real_##fn = (type)function; return; }
    SET(glGetFloatv, gl_get_floatv_t)
    SET(glGetIntegerv, gl_get_integerv_t)
    SET(glGetError, gl_get_error_t)
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

// ---------------------------------------------------------------------------------------------
// glGetIntegerv (gl4es, LWJGL 2 games; installed by JavaApp org.lwjgl.opengl.GLFunctionHooks)

// gl4es keeps glPushAttrib/glPushClientAttrib stacks of any depth but doesn't answer
// GL_MAX_ATTRIB_STACK_DEPTH / GL_MAX_CLIENT_ATTRIB_STACK_DEPTH (it raises GL_INVALID_ENUM and
// leaves the value alone). Angelica 1 sizes its state stacks from them, got 0, and every
// glPushAttrib/glNewList threw "Stack overflow size 1 reached". Report desktop GL's minimum, 16.
__attribute__((used, visibility("default")))
void amethyst_gl4es_glGetIntegerv(GLenum pname, int *params) {
    if (params && (pname == GL_MAX_ATTRIB_STACK_DEPTH || pname == GL_MAX_CLIENT_ATTRIB_STACK_DEPTH)) {
        params[0] = -1;
        real_glGetIntegerv(pname, params);
        if (params[0] <= 0) {
            if (real_glGetError) real_glGetError(); // drop the GL_INVALID_ENUM this query raised
            params[0] = 16;
        }
        return;
    }
    real_glGetIntegerv(pname, params);
}
