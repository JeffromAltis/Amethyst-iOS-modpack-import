// GL entry points that the SDL3 compatibility layer (JavaApp org.lwjgl.sdl.SDLShim) hands to games
// in place of the renderer's own, for the one call whose honest behaviour breaks them on iOS
// (glGetFloatv). Texture uploads are not hooked: MobileGlues converts BGRA uploads itself.
// Only games that get their GL functions through SDL_GL_GetProcAddress (lwjgl3ify 3.x) see these.
// amethyst_gl4es_* hooks are the exception: LWJGL 2 games on gl4es get them through
// JavaApp org.lwjgl.opengl.GLFunctionHooks.
//
// SDLShim passes the renderer's real functions in through amethyst_sdl_setGlFunction() before it
// hands out a hook, so the hook below has its real function set.

#include <stdlib.h>
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
    if (!real_glGetFloatv) return;
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
    if (!real_glGetIntegerv) return;
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

// ---------------------------------------------------------------------------------------------
// glMultiDrawArrays (gl4es, LWJGL 2 games; installed by JavaApp org.lwjgl.opengl.GLFunctionHooks)

#define GL_QUADS                         0x0007
#define GL_TRIANGLES                     0x0004
#define GL_UNSIGNED_INT                  0x1405
#define GL_ELEMENT_ARRAY_BUFFER          0x8893
#define GL_ELEMENT_ARRAY_BUFFER_BINDING  0x8895

typedef void (*gl_draw_arrays_t)(GLenum mode, int first, int count);
typedef void (*gl_multi_draw_arrays_t)(GLenum mode, const int *firsts, const int *counts, int primcount);
typedef void (*gl_draw_elements_t)(GLenum mode, int count, GLenum type, const void *indices);
typedef void (*gl_bind_buffer_t)(GLenum target, unsigned int buffer);

static gl_draw_arrays_t real_glDrawArrays;
static gl_multi_draw_arrays_t real_glMultiDrawArrays;
static gl_draw_elements_t real_glDrawElements;
static gl_bind_buffer_t real_glBindBuffer;

__attribute__((used, visibility("default")))
void amethyst_gl4es_setGlFunction(const char *name, void *function) {
    if (!name) return;
#define SET(fn, type) if (!strcmp(name, #fn)) { real_##fn = (type)function; return; }
    SET(glDrawArrays, gl_draw_arrays_t)
    SET(glMultiDrawArrays, gl_multi_draw_arrays_t)
    SET(glDrawElements, gl_draw_elements_t)
    SET(glBindBuffer, gl_bind_buffer_t)
#undef SET
    amethyst_sdl_setGlFunction(name, function);
}

// Quads [first, first + count) as GL_TRIANGLES with 32-bit indices (GLES has no quads).
static void draw_quads_uint(int first, int count) {
    static unsigned int *indices;
    static int capacity;
    int quads = count / 4;
    int needed = quads * 6;
    if (needed > capacity) {
        free(indices);
        indices = malloc(sizeof(unsigned int) * needed);
        capacity = indices ? needed : 0;
        if (!indices) return;
    }
    unsigned int *p = indices;
    for (int q = 0; q < quads; q++) {
        unsigned int v = (unsigned int)first + q * 4;
        *p++ = v; *p++ = v + 1; *p++ = v + 2;
        *p++ = v; *p++ = v + 2; *p++ = v + 3;
    }
    // Client-side indices: an element buffer bound (e.g. in the current VAO) would turn the pointer into an offset
    int elementBuffer = 0;
    real_glGetIntegerv(GL_ELEMENT_ARRAY_BUFFER_BINDING, &elementBuffer);
    if (elementBuffer > 0) real_glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
    real_glDrawElements(GL_TRIANGLES, needed, GL_UNSIGNED_INT, indices);
    if (elementBuffer > 0) real_glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, (unsigned int)elementBuffer);
}

// gl4es draws GL_QUADS by building a 16-bit triangle index list, and its glMultiDrawArrays copy of that
// code advances the loop counter twice and the vertex number never ("k+=4, k+=4"), so it fills a quarter
// of the list and draws the rest from uninitialised memory. Angelica 1's chunk renderer (Sodium GL 2.0
// path, GT New Horizons 2.8) draws every chunk with it and crashed in gl4es_glMultiDrawArrays on joining a
// world. Draw each range on its own instead: small ranges through gl4es' (correct) glDrawArrays, ranges it
// would get wrong (vertex numbers past 65535 in 16-bit indices, or over 32000 vertices, which it splits
// ignoring `first`) with our own 32-bit indices.
__attribute__((used, visibility("default")))
void amethyst_gl4es_glMultiDrawArrays(GLenum mode, const int *firsts, const int *counts, int primcount) {
    if (!real_glMultiDrawArrays) return;
    if (mode != GL_QUADS || !real_glDrawArrays || !real_glDrawElements || !real_glBindBuffer || !real_glGetIntegerv) {
        real_glMultiDrawArrays(mode, firsts, counts, primcount);
        return;
    }
    for (int i = 0; i < primcount; i++) {
        int first = firsts[i];
        int count = counts[i] & ~3;
        if (first < 0 || count <= 0) continue;
        if (count <= 32000 && (long)first + count <= 65536) {
            real_glDrawArrays(GL_QUADS, first, count);
        } else {
            draw_quads_uint(first, count);
        }
    }
}
