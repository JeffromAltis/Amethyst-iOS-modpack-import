/*
 * Copyright LWJGL. All rights reserved.
 * License terms: https://www.lwjgl.org/license
 * Based on the LWJGL 3.3.3 binding of stb_image_resize.h, with {@link #nstbir_resize_uint8_linear} added for the
 * stb_image_resize2 function Minecraft 26.x calls (see ImageResizeLinear).
 */
package org.lwjgl.stb;

import javax.annotation.*;

import java.nio.*;

import org.lwjgl.system.*;

import static org.lwjgl.system.Checks.*;
import static org.lwjgl.system.MemoryUtil.*;

/**
 * Native bindings to stb_image_resize.h from the stb library, plus the one stb_image_resize2 function below.
 */
public class STBImageResize {

    static {
        LibSTB.initialize();
    }

    public static final int
        STBIR_ALPHA_CHANNEL_NONE       = -1,
        STBIR_FLAG_ALPHA_PREMULTIPLIED = 1,
        STBIR_FLAG_ALPHA_USES_COLORSPACE = 2;

    public static final int
        STBIR_EDGE_CLAMP   = 1,
        STBIR_EDGE_REFLECT = 2,
        STBIR_EDGE_WRAP    = 3,
        STBIR_EDGE_ZERO    = 4;

    public static final int
        STBIR_FILTER_DEFAULT     = 0,
        STBIR_FILTER_BOX         = 1,
        STBIR_FILTER_TRIANGLE    = 2,
        STBIR_FILTER_CUBICBSPLINE = 3,
        STBIR_FILTER_CATMULLROM  = 4,
        STBIR_FILTER_MITCHELL    = 5;

    public static final int
        STBIR_COLORSPACE_LINEAR = 0,
        STBIR_COLORSPACE_SRGB   = 1;

    public static final int
        STBIR_TYPE_UINT8  = 0,
        STBIR_TYPE_UINT16 = 1,
        STBIR_TYPE_UINT32 = 2,
        STBIR_TYPE_FLOAT  = 3;

    /** stb_image_resize2's pixel layouts, the last argument of {@link #nstbir_resize_uint8_linear}. */
    public static final int
        STBIR_BGR      = 0,
        STBIR_1CHANNEL = 1,
        STBIR_2CHANNEL = 2,
        STBIR_RGB      = 3,
        STBIR_RGBA     = 4,
        STBIR_4CHANNEL = 5,
        STBIR_BGRA     = 6,
        STBIR_ARGB     = 7,
        STBIR_ABGR     = 8,
        STBIR_RA       = 9,
        STBIR_AR       = 10;

    protected STBImageResize() {
        throw new UnsupportedOperationException();
    }

    // --- [ stbir_resize_uint8_linear (stb_image_resize2), done in Java ] ---

    /**
     * Resizes 8-bit pixels without any colour space conversion.
     *
     * @param input_pixels            address of the first source pixel
     * @param input_stride_in_bytes   bytes between source rows, 0 for tightly packed
     * @param output_stride_in_bytes  bytes between result rows, 0 for tightly packed
     * @param pixel_layout            a {@code STBIR_*} layout, which also gives the channel count
     * @return {@code output_pixels}, or NULL if the arguments are not valid
     */
    @NativeType("unsigned char *")
    public static long nstbir_resize_uint8_linear(long input_pixels, int input_w, int input_h, int input_stride_in_bytes,
                                                  long output_pixels, int output_w, int output_h, int output_stride_in_bytes,
                                                  int pixel_layout) {
        int channels = ImageResizeLinear.channels(pixel_layout);
        if (input_pixels == NULL || output_pixels == NULL || channels == 0 || input_w <= 0 || input_h <= 0 || output_w <= 0 || output_h <= 0) {
            return NULL;
        }
        long inStride = input_stride_in_bytes != 0 ? input_stride_in_bytes : (long) input_w * channels;
        long outStride = output_stride_in_bytes != 0 ? output_stride_in_bytes : (long) output_w * channels;
        long inSize = (input_h - 1) * inStride + (long) input_w * channels;
        long outSize = (output_h - 1) * outStride + (long) output_w * channels;
        if (inSize > Integer.MAX_VALUE || outSize > Integer.MAX_VALUE) {
            return NULL;
        }
        boolean done = ImageResizeLinear.resize(
            memByteBuffer(input_pixels, (int) inSize), input_w, input_h, (int) inStride,
            memByteBuffer(output_pixels, (int) outSize), output_w, output_h, (int) outStride,
            pixel_layout);
        return done ? output_pixels : NULL;
    }

    /** Buffer version of {@link #nstbir_resize_uint8_linear}; returns false if the arguments are not valid. */
    public static boolean stbir_resize_uint8_linear(@NativeType("unsigned char const *") ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes,
                                                    @NativeType("unsigned char *") ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes,
                                                    int pixel_layout) {
        return nstbir_resize_uint8_linear(memAddress(input_pixels), input_w, input_h, input_stride_in_bytes,
            memAddress(output_pixels), output_w, output_h, output_stride_in_bytes, pixel_layout) != NULL;
    }

    // --- [ stb_image_resize.h (version 1), implemented by the native library ] ---

    public static native int nstbir_resize_uint8(long input_pixels, int input_w, int input_h, int input_stride_in_bytes, long output_pixels, int output_w, int output_h, int output_stride_in_bytes, int num_channels);

    public static boolean stbir_resize_uint8(@NativeType("unsigned char const *") ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, @NativeType("unsigned char *") ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, int num_channels) {
        if (CHECKS) {
            check(input_pixels, (input_stride_in_bytes != 0 ? input_stride_in_bytes : input_w * num_channels) * input_h);
            check(output_pixels, (output_stride_in_bytes != 0 ? output_stride_in_bytes : output_w * num_channels) * output_h);
        }
        return nstbir_resize_uint8(memAddress(input_pixels), input_w, input_h, input_stride_in_bytes, memAddress(output_pixels), output_w, output_h, output_stride_in_bytes, num_channels) != 0;
    }

    public static native int nstbir_resize_float(long input_pixels, int input_w, int input_h, int input_stride_in_bytes, long output_pixels, int output_w, int output_h, int output_stride_in_bytes, int num_channels);

    public static boolean stbir_resize_float(@NativeType("float const *") FloatBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, @NativeType("float *") FloatBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, int num_channels) {
        return nstbir_resize_float(memAddress(input_pixels), input_w, input_h, input_stride_in_bytes, memAddress(output_pixels), output_w, output_h, output_stride_in_bytes, num_channels) != 0;
    }

    public static native int nstbir_resize_uint8_srgb(long input_pixels, int input_w, int input_h, int input_stride_in_bytes, long output_pixels, int output_w, int output_h, int output_stride_in_bytes, int num_channels, int alpha_channel, int flags);

    public static boolean stbir_resize_uint8_srgb(@NativeType("unsigned char const *") ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, @NativeType("unsigned char *") ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, int num_channels, int alpha_channel, int flags) {
        return nstbir_resize_uint8_srgb(memAddress(input_pixels), input_w, input_h, input_stride_in_bytes, memAddress(output_pixels), output_w, output_h, output_stride_in_bytes, num_channels, alpha_channel, flags) != 0;
    }

    public static native int nstbir_resize_uint8_srgb_edgemode(long input_pixels, int input_w, int input_h, int input_stride_in_bytes, long output_pixels, int output_w, int output_h, int output_stride_in_bytes, int num_channels, int alpha_channel, int flags, int edge_wrap_mode);

    public static boolean stbir_resize_uint8_srgb_edgemode(@NativeType("unsigned char const *") ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, @NativeType("unsigned char *") ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, int num_channels, int alpha_channel, int flags, @NativeType("stbir_edge") int edge_wrap_mode) {
        return nstbir_resize_uint8_srgb_edgemode(memAddress(input_pixels), input_w, input_h, input_stride_in_bytes, memAddress(output_pixels), output_w, output_h, output_stride_in_bytes, num_channels, alpha_channel, flags, edge_wrap_mode) != 0;
    }

    public static native int nstbir_resize_uint8_generic(long input_pixels, int input_w, int input_h, int input_stride_in_bytes, long output_pixels, int output_w, int output_h, int output_stride_in_bytes, int num_channels, int alpha_channel, int flags, int edge_wrap_mode, int filter, int space, long alloc_context);

    public static boolean stbir_resize_uint8_generic(@NativeType("unsigned char const *") ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, @NativeType("unsigned char *") ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, int num_channels, int alpha_channel, int flags, @NativeType("stbir_edge") int edge_wrap_mode, @NativeType("stbir_filter") int filter, @NativeType("stbir_colorspace") int space) {
        return nstbir_resize_uint8_generic(memAddress(input_pixels), input_w, input_h, input_stride_in_bytes, memAddress(output_pixels), output_w, output_h, output_stride_in_bytes, num_channels, alpha_channel, flags, edge_wrap_mode, filter, space, NULL) != 0;
    }

    public static native int nstbir_resize_uint16_generic(long input_pixels, int input_w, int input_h, int input_stride_in_bytes, long output_pixels, int output_w, int output_h, int output_stride_in_bytes, int num_channels, int alpha_channel, int flags, int edge_wrap_mode, int filter, int space, long alloc_context);

    public static boolean stbir_resize_uint16_generic(@NativeType("stbir_uint16 const *") ShortBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, @NativeType("stbir_uint16 *") ShortBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, int num_channels, int alpha_channel, int flags, @NativeType("stbir_edge") int edge_wrap_mode, @NativeType("stbir_filter") int filter, @NativeType("stbir_colorspace") int space) {
        return nstbir_resize_uint16_generic(memAddress(input_pixels), input_w, input_h, input_stride_in_bytes, memAddress(output_pixels), output_w, output_h, output_stride_in_bytes, num_channels, alpha_channel, flags, edge_wrap_mode, filter, space, NULL) != 0;
    }

    public static native int nstbir_resize_float_generic(long input_pixels, int input_w, int input_h, int input_stride_in_bytes, long output_pixels, int output_w, int output_h, int output_stride_in_bytes, int num_channels, int alpha_channel, int flags, int edge_wrap_mode, int filter, int space, long alloc_context);

    public static boolean stbir_resize_float_generic(@NativeType("float const *") FloatBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, @NativeType("float *") FloatBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, int num_channels, int alpha_channel, int flags, @NativeType("stbir_edge") int edge_wrap_mode, @NativeType("stbir_filter") int filter, @NativeType("stbir_colorspace") int space) {
        return nstbir_resize_float_generic(memAddress(input_pixels), input_w, input_h, input_stride_in_bytes, memAddress(output_pixels), output_w, output_h, output_stride_in_bytes, num_channels, alpha_channel, flags, edge_wrap_mode, filter, space, NULL) != 0;
    }

    public static native int nstbir_resize(long input_pixels, int input_w, int input_h, int input_stride_in_bytes, long output_pixels, int output_w, int output_h, int output_stride_in_bytes, int datatype, int num_channels, int alpha_channel, int flags, int edge_mode_horizontal, int edge_mode_vertical, int filter_horizontal, int filter_vertical, int space, long alloc_context);

    public static boolean stbir_resize(@NativeType("void const *") ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, @NativeType("void *") ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, @NativeType("stbir_datatype") int datatype, int num_channels, int alpha_channel, int flags, @NativeType("stbir_edge") int edge_mode_horizontal, @NativeType("stbir_edge") int edge_mode_vertical, @NativeType("stbir_filter") int filter_horizontal, @NativeType("stbir_filter") int filter_vertical, @NativeType("stbir_colorspace") int space) {
        return nstbir_resize(memAddress(input_pixels), input_w, input_h, input_stride_in_bytes, memAddress(output_pixels), output_w, output_h, output_stride_in_bytes, datatype, num_channels, alpha_channel, flags, edge_mode_horizontal, edge_mode_vertical, filter_horizontal, filter_vertical, space, NULL) != 0;
    }

    public static native int nstbir_resize_subpixel(long input_pixels, int input_w, int input_h, int input_stride_in_bytes, long output_pixels, int output_w, int output_h, int output_stride_in_bytes, int datatype, int num_channels, int alpha_channel, int flags, int edge_mode_horizontal, int edge_mode_vertical, int filter_horizontal, int filter_vertical, int space, long alloc_context, float x_scale, float y_scale, float x_offset, float y_offset);

    public static boolean stbir_resize_subpixel(@NativeType("void const *") ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, @NativeType("void *") ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, @NativeType("stbir_datatype") int datatype, int num_channels, int alpha_channel, int flags, @NativeType("stbir_edge") int edge_mode_horizontal, @NativeType("stbir_edge") int edge_mode_vertical, @NativeType("stbir_filter") int filter_horizontal, @NativeType("stbir_filter") int filter_vertical, @NativeType("stbir_colorspace") int space, float x_scale, float y_scale, float x_offset, float y_offset) {
        return nstbir_resize_subpixel(memAddress(input_pixels), input_w, input_h, input_stride_in_bytes, memAddress(output_pixels), output_w, output_h, output_stride_in_bytes, datatype, num_channels, alpha_channel, flags, edge_mode_horizontal, edge_mode_vertical, filter_horizontal, filter_vertical, space, NULL, x_scale, y_scale, x_offset, y_offset) != 0;
    }

    // --- [ Overloads of the above that take arrays, and the region variant ] ---

    public static native int nstbir_resize_float(float[] input_pixels, int input_w, int input_h, int input_stride_in_bytes, float[] output_pixels, int output_w, int output_h, int output_stride_in_bytes, int num_channels);

    public static boolean stbir_resize_float(@NativeType("float const *") float[] input_pixels, int input_w, int input_h, int input_stride_in_bytes, @NativeType("float *") float[] output_pixels, int output_w, int output_h, int output_stride_in_bytes, int num_channels) {
        return nstbir_resize_float(input_pixels, input_w, input_h, input_stride_in_bytes, output_pixels, output_w, output_h, output_stride_in_bytes, num_channels) != 0;
    }

    public static native int nstbir_resize_uint16_generic(short[] input_pixels, int input_w, int input_h, int input_stride_in_bytes, short[] output_pixels, int output_w, int output_h, int output_stride_in_bytes, int num_channels, int alpha_channel, int flags, int edge_wrap_mode, int filter, int space, long alloc_context);

    public static boolean stbir_resize_uint16_generic(@NativeType("stbir_uint16 const *") short[] input_pixels, int input_w, int input_h, int input_stride_in_bytes, @NativeType("stbir_uint16 *") short[] output_pixels, int output_w, int output_h, int output_stride_in_bytes, int num_channels, int alpha_channel, int flags, @NativeType("stbir_edge") int edge_wrap_mode, @NativeType("stbir_filter") int filter, @NativeType("stbir_colorspace") int space) {
        return nstbir_resize_uint16_generic(input_pixels, input_w, input_h, input_stride_in_bytes, output_pixels, output_w, output_h, output_stride_in_bytes, num_channels, alpha_channel, flags, edge_wrap_mode, filter, space, NULL) != 0;
    }

    public static native int nstbir_resize_float_generic(float[] input_pixels, int input_w, int input_h, int input_stride_in_bytes, float[] output_pixels, int output_w, int output_h, int output_stride_in_bytes, int num_channels, int alpha_channel, int flags, int edge_wrap_mode, int filter, int space, long alloc_context);

    public static boolean stbir_resize_float_generic(@NativeType("float const *") float[] input_pixels, int input_w, int input_h, int input_stride_in_bytes, @NativeType("float *") float[] output_pixels, int output_w, int output_h, int output_stride_in_bytes, int num_channels, int alpha_channel, int flags, @NativeType("stbir_edge") int edge_wrap_mode, @NativeType("stbir_filter") int filter, @NativeType("stbir_colorspace") int space) {
        return nstbir_resize_float_generic(input_pixels, input_w, input_h, input_stride_in_bytes, output_pixels, output_w, output_h, output_stride_in_bytes, num_channels, alpha_channel, flags, edge_wrap_mode, filter, space, NULL) != 0;
    }

    public static native int nstbir_resize_region(long input_pixels, int input_w, int input_h, int input_stride_in_bytes, long output_pixels, int output_w, int output_h, int output_stride_in_bytes, int datatype, int num_channels, int alpha_channel, int flags, int edge_mode_horizontal, int edge_mode_vertical, int filter_horizontal, int filter_vertical, int space, long alloc_context, float s0, float t0, float s1, float t1);

    public static boolean stbir_resize_region(@NativeType("void const *") ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, @NativeType("void *") ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, @NativeType("stbir_datatype") int datatype, int num_channels, int alpha_channel, int flags, @NativeType("stbir_edge") int edge_mode_horizontal, @NativeType("stbir_edge") int edge_mode_vertical, @NativeType("stbir_filter") int filter_horizontal, @NativeType("stbir_filter") int filter_vertical, @NativeType("stbir_colorspace") int space, float s0, float t0, float s1, float t1) {
        return nstbir_resize_region(memAddress(input_pixels), input_w, input_h, input_stride_in_bytes, memAddress(output_pixels), output_w, output_h, output_stride_in_bytes, datatype, num_channels, alpha_channel, flags, edge_mode_horizontal, edge_mode_vertical, filter_horizontal, filter_vertical, space, NULL, s0, t0, s1, t1) != 0;
    }

}
