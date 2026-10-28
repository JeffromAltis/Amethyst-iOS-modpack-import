package org.lwjgl.stb;

import java.nio.ByteBuffer;

/**
 * 8-bit image resizing for {@code STBImageResize.nstbir_resize_uint8_linear} (stb_image_resize2's
 * {@code stbir_resize_uint8_linear}). The app's native stb library only has the old stb_image_resize functions,
 * so the new one is done here, in plain Java.
 *
 * <p>Colours are filtered as plain numbers (no gamma conversion), like the "linear" entry point. Reducing an
 * image averages the source pixels each result pixel covers (a box filter); enlarging it interpolates
 * between neighbouring pixels. stb's own default filters are slightly sharper, which does not matter for what
 * the game does with it (scaling screenshots down for world icons). Pixels with an alpha channel are weighted
 * by it, as stb does, so transparent pixels do not darken the edges.</p>
 */
final class ImageResizeLinear {

    private ImageResizeLinear() {}

    /** Channels per pixel for a stb_image_resize2 {@code stbir_pixel_layout}, or 0 if unknown. */
    static int channels(int layout) {
        switch (layout) {
            case 1: // STBIR_1CHANNEL
                return 1;
            case 2: case 9: case 10: case 15: case 16: // 2CHANNEL, RA, AR and their premultiplied forms
                return 2;
            case 0: case 3: // BGR, RGB
                return 3;
            case 4: case 5: case 6: case 7: case 8: case 11: case 12: case 13: case 14: // RGBA, 4CHANNEL, BGRA, ARGB, ABGR, premultiplied
                return 4;
            default:
                return 0;
        }
    }

    /** Index of the straight (not premultiplied) alpha channel, or -1 if there is none to weight by. */
    static int alphaChannel(int layout) {
        switch (layout) {
            case 4: case 6: return 3; // RGBA, BGRA
            case 7: case 8: return 0; // ARGB, ABGR
            case 9: return 1;         // RA
            case 10: return 0;        // AR
            default: return -1;
        }
    }

    /** Source positions and weights for each result position along one axis. */
    private static final class Axis {
        final int[] first;   // first source index per result index
        final float[][] weights;

        Axis(int in, int out) {
            first = new int[out];
            weights = new float[out][];
            double scale = (double) in / out;
            for (int o = 0; o < out; o++) {
                if (scale > 1.0) {
                    // Reducing: the result covers [o*scale, (o+1)*scale) of the source
                    double start = o * scale, end = Math.min((o + 1) * scale, in);
                    int i0 = (int) Math.floor(start);
                    int i1 = Math.min((int) Math.ceil(end), in);
                    float[] w = new float[Math.max(1, i1 - i0)];
                    double total = 0;
                    for (int i = i0; i < i1; i++) {
                        double cover = Math.min(i + 1, end) - Math.max(i, start);
                        w[i - i0] = (float) cover;
                        total += cover;
                    }
                    for (int k = 0; k < w.length; k++) {
                        w[k] /= (float) total;
                    }
                    first[o] = i0;
                    weights[o] = w;
                } else {
                    // Enlarging (or same size): interpolate between the two nearest source pixels
                    double centre = (o + 0.5) * scale - 0.5;
                    int i0 = (int) Math.floor(centre);
                    float frac = (float) (centre - i0);
                    int a = Math.max(0, Math.min(in - 1, i0));
                    int b = Math.max(0, Math.min(in - 1, i0 + 1));
                    if (a == b) {
                        first[o] = a;
                        weights[o] = new float[] {1f};
                    } else {
                        first[o] = a;
                        weights[o] = new float[] {1f - frac, frac};
                    }
                }
            }
        }
    }

    /**
     * @param in        source pixels starting at the first pixel of the area to scale
     * @param inStride  bytes between source rows (0 means tightly packed)
     * @param out       result pixels
     * @param outStride bytes between result rows (0 means tightly packed)
     * @return false if the arguments are invalid or a buffer is too small
     */
    static boolean resize(ByteBuffer in, int inW, int inH, int inStride,
                          ByteBuffer out, int outW, int outH, int outStride, int layout) {
        int ch = channels(layout);
        if (ch == 0 || inW <= 0 || inH <= 0 || outW <= 0 || outH <= 0) {
            return false;
        }
        if (inStride == 0) inStride = inW * ch;
        if (outStride == 0) outStride = outW * ch;
        if (inStride < inW * ch || outStride < outW * ch) {
            return false;
        }
        if ((long) (inH - 1) * inStride + (long) inW * ch > in.remaining()
            || (long) (outH - 1) * outStride + (long) outW * ch > out.remaining()) {
            return false;
        }
        int alpha = alphaChannel(layout);
        int inBase = in.position(), outBase = out.position();

        Axis xs = new Axis(inW, outW), ys = new Axis(inH, outH);

        // Pass 1, across: every source row becomes outW pixels. Colour is premultiplied by alpha when there is one.
        float[] rows = new float[inH * outW * ch];
        float[] sum = new float[ch];
        for (int y = 0; y < inH; y++) {
            int rowStart = inBase + y * inStride;
            for (int x = 0; x < outW; x++) {
                java.util.Arrays.fill(sum, 0f);
                int i0 = xs.first[x];
                float[] w = xs.weights[x];
                for (int k = 0; k < w.length; k++) {
                    int p = rowStart + (i0 + k) * ch;
                    float a = alpha >= 0 ? (in.get(p + alpha) & 0xFF) / 255f : 1f;
                    for (int c = 0; c < ch; c++) {
                        float v = in.get(p + c) & 0xFF;
                        sum[c] += w[k] * (c == alpha ? v : v * a);
                    }
                }
                System.arraycopy(sum, 0, rows, (y * outW + x) * ch, ch);
            }
        }

        // Pass 2, down: outH rows from the intermediate rows, then back to straight alpha and bytes
        for (int y = 0; y < outH; y++) {
            int i0 = ys.first[y];
            float[] w = ys.weights[y];
            for (int x = 0; x < outW; x++) {
                java.util.Arrays.fill(sum, 0f);
                for (int k = 0; k < w.length; k++) {
                    int q = ((i0 + k) * outW + x) * ch;
                    for (int c = 0; c < ch; c++) {
                        sum[c] += w[k] * rows[q + c];
                    }
                }
                int p = outBase + y * outStride + x * ch;
                float a = alpha >= 0 ? sum[alpha] / 255f : 1f;
                for (int c = 0; c < ch; c++) {
                    float v = sum[c];
                    if (alpha >= 0 && c != alpha) {
                        v = a > 0f ? v / a : 0f;
                    }
                    out.put(p + c, (byte) Math.max(0, Math.min(255, Math.round(v))));
                }
            }
        }
        return true;
    }

}
