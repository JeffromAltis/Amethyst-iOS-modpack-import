// GL entry points that the SDL3 compatibility layer (JavaApp org.lwjgl.sdl.SDLShim) hands to games
// in place of the renderer's own, for the few calls whose honest behaviour breaks them on iOS.
// Only games that get their GL functions through SDL_GL_GetProcAddress (lwjgl3ify 3.x) see these.
//
// SDLShim passes the renderer's real functions in through amethyst_sdl_setGlFunction() before it
// hands out a hook, so every hook below has its real function, and the helpers it needs, set.

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define GL_UNSIGNED_BYTE                0x1401
#define GL_RGBA                         0x1908
#define GL_BGRA                         0x80E1
#define GL_BGRA8_EXT                    0x93A1
#define GL_UNSIGNED_INT_8_8_8_8         0x8035
#define GL_UNSIGNED_INT_8_8_8_8_REV     0x8367
#define GL_UNPACK_ROW_LENGTH            0x0CF2
#define GL_UNPACK_SKIP_ROWS             0x0CF3
#define GL_UNPACK_SKIP_PIXELS           0x0CF4
#define GL_UNPACK_ALIGNMENT             0x0CF5
#define GL_PIXEL_UNPACK_BUFFER          0x88EC
#define GL_PIXEL_UNPACK_BUFFER_BINDING  0x88EF
#define GL_MAP_READ_BIT                 0x0001
#define GL_ALIASED_LINE_WIDTH_RANGE     0x846E

typedef unsigned int GLenum;
typedef unsigned int GLuint;
typedef int GLint;
typedef int GLsizei;

typedef void (*gl_get_floatv_t)(GLenum pname, float *params);
typedef void (*gl_get_integerv_t)(GLenum pname, GLint *params);
typedef void (*gl_pixel_storei_t)(GLenum pname, GLint param);
typedef void (*gl_bind_buffer_t)(GLenum target, GLuint buffer);
typedef void *(*gl_map_buffer_range_t)(GLenum target, intptr_t offset, intptr_t length, GLuint access);
typedef unsigned char (*gl_unmap_buffer_t)(GLenum target);
typedef void (*gl_tex_image_2d_t)(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height,
    GLint border, GLenum format, GLenum type, const void *pixels);
typedef void (*gl_tex_sub_image_2d_t)(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width,
    GLsizei height, GLenum format, GLenum type, const void *pixels);
typedef void (*gl_texture_sub_image_2d_t)(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLsizei width,
    GLsizei height, GLenum format, GLenum type, const void *pixels);
typedef void (*gl_texture_sub_image_2d_ext_t)(GLuint texture, GLenum target, GLint level, GLint xoffset, GLint yoffset,
    GLsizei width, GLsizei height, GLenum format, GLenum type, const void *pixels);

static gl_get_floatv_t real_glGetFloatv;
static gl_get_integerv_t real_glGetIntegerv;
static gl_pixel_storei_t real_glPixelStorei;
static gl_bind_buffer_t real_glBindBuffer;
static gl_map_buffer_range_t real_glMapBufferRange;
static gl_unmap_buffer_t real_glUnmapBuffer;
static gl_tex_image_2d_t real_glTexImage2D;
static gl_tex_sub_image_2d_t real_glTexSubImage2D;
static gl_texture_sub_image_2d_t real_glTextureSubImage2D;
static gl_texture_sub_image_2d_ext_t real_glTextureSubImage2DEXT;

__attribute__((used, visibility("default")))
void amethyst_sdl_setGlFunction(const char *name, void *function) {
    if (!name) return;
#define SET(fn, type) if (!strcmp(name, #fn)) { real_##fn = (type)function; return; }
    SET(glGetFloatv, gl_get_floatv_t)
    SET(glGetIntegerv, gl_get_integerv_t)
    SET(glPixelStorei, gl_pixel_storei_t)
    SET(glBindBuffer, gl_bind_buffer_t)
    SET(glMapBufferRange, gl_map_buffer_range_t)
    SET(glUnmapBuffer, gl_unmap_buffer_t)
    SET(glTexImage2D, gl_tex_image_2d_t)
    SET(glTexSubImage2D, gl_tex_sub_image_2d_t)
    SET(glTextureSubImage2D, gl_texture_sub_image_2d_t)
    SET(glTextureSubImage2DEXT, gl_texture_sub_image_2d_ext_t)
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
// BGRA texture uploads
//
// Minecraft before 1.13 uploads every texture as GL_BGRA / GL_UNSIGNED_INT_8_8_8_8_REV. OpenGL ES
// has neither, and the MobileGlues version we ship only translates GL_UNSIGNED_INT_8_8_8_8, so these
// uploads failed (silently: MobileGlues ignores GL errors) and every texture stayed empty. Textured
// draws then came out transparent and the game showed a black screen with only untextured shapes.
// Convert such uploads to GL_RGBA / GL_UNSIGNED_BYTE here, before the renderer sees them.

enum {
    CONVERT_NONE,     // not ours: pass through
    CONVERT_TYPE,     // bytes are already R, G, B, A: only the type needs renaming
    CONVERT_SWAP_RB,  // bytes are B, G, R, A
    CONVERT_ARGB,     // bytes are A, R, G, B
    CONVERT_ABGR,     // bytes are A, B, G, R
};

// Byte order of each packed type on a little-endian CPU (all iOS devices)
static int conversionFor(GLenum format, GLenum type) {
    if (format == GL_BGRA) {
        if (type == GL_UNSIGNED_BYTE || type == GL_UNSIGNED_INT_8_8_8_8_REV) return CONVERT_SWAP_RB;
        if (type == GL_UNSIGNED_INT_8_8_8_8) return CONVERT_ARGB;
    } else if (format == GL_RGBA) {
        if (type == GL_UNSIGNED_INT_8_8_8_8_REV) return CONVERT_TYPE;
        if (type == GL_UNSIGNED_INT_8_8_8_8) return CONVERT_ABGR;
    }
    return CONVERT_NONE;
}

static void convertRow(int conversion, const uint8_t *src, uint8_t *dst, GLsizei width) {
    for (GLsizei i = 0; i < width; i++, src += 4, dst += 4) {
        switch (conversion) {
            case CONVERT_SWAP_RB: dst[0] = src[2]; dst[1] = src[1]; dst[2] = src[0]; dst[3] = src[3]; break;
            case CONVERT_ARGB:    dst[0] = src[1]; dst[1] = src[2]; dst[2] = src[3]; dst[3] = src[0]; break;
            case CONVERT_ABGR:    dst[0] = src[3]; dst[1] = src[2]; dst[2] = src[1]; dst[3] = src[0]; break;
            default:              memcpy(dst, src, 4); break;
        }
    }
}

static int canConvert(void) {
    return real_glGetIntegerv && real_glPixelStorei && real_glBindBuffer;
}

static GLint boundUnpackBuffer(void) {
    GLint buffer = 0;
    if (real_glGetIntegerv) real_glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &buffer);
    return buffer;
}

typedef void (*upload_rows_t)(void *ctx, GLint yoffset, GLsizei rows, const void *pixels);

// Reads width x height pixels the way GL would (unpack parameters, pixel unpack buffer), converts
// them to RGBA bytes and hands them to upload() a strip of rows at a time, so that a large atlas
// doesn't need a full-size copy. Returns 0 if it could not, leaving GL state untouched.
static int uploadConverted(int conversion, GLsizei width, GLsizei height, const void *pixels,
                           upload_rows_t upload, void *ctx) {
    if (!canConvert()) return 0;
    if (width <= 0 || height <= 0) return 1;

    GLint rowLength = 0, skipRows = 0, skipPixels = 0, alignment = 4, buffer = 0;
    real_glGetIntegerv(GL_UNPACK_ROW_LENGTH, &rowLength);
    real_glGetIntegerv(GL_UNPACK_SKIP_ROWS, &skipRows);
    real_glGetIntegerv(GL_UNPACK_SKIP_PIXELS, &skipPixels);
    real_glGetIntegerv(GL_UNPACK_ALIGNMENT, &alignment);
    real_glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &buffer);
    if (alignment <= 0) alignment = 4;

    size_t rowPixels = rowLength > 0 ? (size_t)rowLength : (size_t)width;
    size_t stride = (rowPixels * 4 + alignment - 1) / alignment * alignment;
    size_t start = (size_t)skipRows * stride + (size_t)skipPixels * 4;
    size_t span = start + (size_t)(height - 1) * stride + (size_t)width * 4;

    const uint8_t *source;
    void *mapped = NULL;
    if (buffer != 0) {
        // pixels is an offset into the bound buffer
        if (!real_glMapBufferRange || !real_glUnmapBuffer) return 0;
        mapped = real_glMapBufferRange(GL_PIXEL_UNPACK_BUFFER, (intptr_t)pixels, (intptr_t)span, GL_MAP_READ_BIT);
        if (!mapped) return 0;
        source = (const uint8_t *)mapped;
    } else {
        if (!pixels) return 0;
        source = (const uint8_t *)pixels;
    }
    source += start;

    size_t rowBytes = (size_t)width * 4;
    size_t stripRows = (4u << 20) / rowBytes;
    if (stripRows < 1) stripRows = 1;
    if (stripRows > (size_t)height) stripRows = (size_t)height;
    uint8_t *strip = malloc(rowBytes * stripRows);
    if (!strip) {
        if (mapped) real_glUnmapBuffer(GL_PIXEL_UNPACK_BUFFER);
        return 0;
    }

    // The converted strips are tightly packed client memory
    if (buffer != 0) real_glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    real_glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    real_glPixelStorei(GL_UNPACK_SKIP_ROWS, 0);
    real_glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0);
    real_glPixelStorei(GL_UNPACK_ALIGNMENT, 4);

    for (GLsizei y = 0; y < height; y += (GLsizei)stripRows) {
        GLsizei rows = height - y < (GLsizei)stripRows ? height - y : (GLsizei)stripRows;
        for (GLsizei r = 0; r < rows; r++) {
            convertRow(conversion, source + (size_t)(y + r) * stride, strip + (size_t)r * rowBytes, width);
        }
        upload(ctx, y, rows, strip);
    }

    real_glPixelStorei(GL_UNPACK_ROW_LENGTH, rowLength);
    real_glPixelStorei(GL_UNPACK_SKIP_ROWS, skipRows);
    real_glPixelStorei(GL_UNPACK_SKIP_PIXELS, skipPixels);
    real_glPixelStorei(GL_UNPACK_ALIGNMENT, alignment);
    if (buffer != 0) {
        real_glBindBuffer(GL_PIXEL_UNPACK_BUFFER, (GLuint)buffer);
        real_glUnmapBuffer(GL_PIXEL_UNPACK_BUFFER);
    }
    free(strip);
    return 1;
}

typedef struct {
    GLuint texture;
    GLenum target;
    GLint level, xoffset, yoffset;
    GLsizei width;
} sub_image_ctx;

static void uploadTexSubImage(void *ctx, GLint y, GLsizei rows, const void *pixels) {
    sub_image_ctx *c = ctx;
    real_glTexSubImage2D(c->target, c->level, c->xoffset, c->yoffset + y, c->width, rows, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
}

static void uploadTextureSubImage(void *ctx, GLint y, GLsizei rows, const void *pixels) {
    sub_image_ctx *c = ctx;
    real_glTextureSubImage2D(c->texture, c->level, c->xoffset, c->yoffset + y, c->width, rows, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
}

static void uploadTextureSubImageEXT(void *ctx, GLint y, GLsizei rows, const void *pixels) {
    sub_image_ctx *c = ctx;
    real_glTextureSubImage2DEXT(c->texture, c->target, c->level, c->xoffset, c->yoffset + y, c->width, rows, GL_RGBA,
        GL_UNSIGNED_BYTE, pixels);
}

__attribute__((used, visibility("default")))
void amethyst_sdl_glTexImage2D(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height,
                               GLint border, GLenum format, GLenum type, const void *pixels) {
    int conversion = conversionFor(format, type);
    if (conversion == CONVERT_NONE || (conversion != CONVERT_TYPE && (!canConvert() || !real_glTexSubImage2D))) {
        real_glTexImage2D(target, level, internalformat, width, height, border, format, type, pixels);
        return;
    }
    if (internalformat == GL_BGRA || internalformat == GL_BGRA8_EXT) {
        internalformat = GL_RGBA;
    }
    if (conversion == CONVERT_TYPE) {
        real_glTexImage2D(target, level, internalformat, width, height, border, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
        return;
    }
    // Allocate as RGBA bytes (with no unpack buffer, so that NULL means no data), then fill it in
    GLint buffer = boundUnpackBuffer();
    if (buffer != 0) real_glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    real_glTexImage2D(target, level, internalformat, width, height, border, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    if (buffer != 0) real_glBindBuffer(GL_PIXEL_UNPACK_BUFFER, (GLuint)buffer);
    if (pixels == NULL && buffer == 0) {
        return;
    }
    sub_image_ctx ctx = {0, target, level, 0, 0, width};
    uploadConverted(conversion, width, height, pixels, uploadTexSubImage, &ctx);
}

__attribute__((used, visibility("default")))
void amethyst_sdl_glTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width,
                                  GLsizei height, GLenum format, GLenum type, const void *pixels) {
    int conversion = conversionFor(format, type);
    if (conversion == CONVERT_TYPE) {
        format = GL_RGBA;
        type = GL_UNSIGNED_BYTE;
    } else if (conversion != CONVERT_NONE) {
        sub_image_ctx ctx = {0, target, level, xoffset, yoffset, width};
        if (uploadConverted(conversion, width, height, pixels, uploadTexSubImage, &ctx)) return;
    }
    real_glTexSubImage2D(target, level, xoffset, yoffset, width, height, format, type, pixels);
}

__attribute__((used, visibility("default")))
void amethyst_sdl_glTextureSubImage2D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLsizei width,
                                      GLsizei height, GLenum format, GLenum type, const void *pixels) {
    int conversion = conversionFor(format, type);
    if (conversion == CONVERT_TYPE) {
        format = GL_RGBA;
        type = GL_UNSIGNED_BYTE;
    } else if (conversion != CONVERT_NONE) {
        sub_image_ctx ctx = {texture, 0, level, xoffset, yoffset, width};
        if (uploadConverted(conversion, width, height, pixels, uploadTextureSubImage, &ctx)) return;
    }
    real_glTextureSubImage2D(texture, level, xoffset, yoffset, width, height, format, type, pixels);
}

__attribute__((used, visibility("default")))
void amethyst_sdl_glTextureSubImage2DEXT(GLuint texture, GLenum target, GLint level, GLint xoffset, GLint yoffset,
                                         GLsizei width, GLsizei height, GLenum format, GLenum type, const void *pixels) {
    int conversion = conversionFor(format, type);
    if (conversion == CONVERT_TYPE) {
        format = GL_RGBA;
        type = GL_UNSIGNED_BYTE;
    } else if (conversion != CONVERT_NONE) {
        sub_image_ctx ctx = {texture, target, level, xoffset, yoffset, width};
        if (uploadConverted(conversion, width, height, pixels, uploadTextureSubImageEXT, &ctx)) return;
    }
    real_glTextureSubImage2DEXT(texture, target, level, xoffset, yoffset, width, height, format, type, pixels);
}
