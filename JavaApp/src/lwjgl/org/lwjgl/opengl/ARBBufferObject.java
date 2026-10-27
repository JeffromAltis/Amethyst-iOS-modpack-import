/*
 * Amethyst-iOS: overrides the org.lwjgl.opengl.ARBBufferObject copy shipped in lwjgl-lwjglx.jar (JavaApp/Makefile copies
 * JavaApp/src/lwjgl/** over the extracted jars).
 *
 * In LWJGL 2 ARBBufferObject declares the GL_ARB_buffer_object entry points and *_ARB constants and
 * ARBVertexBufferObject extends it; lwjglx inverts this (ARBBufferObject extends LWJGL 3's ARBVertexBufferObject), so
 * glBindBufferARB, glBufferDataARB, glBufferSubDataARB, glDeleteBuffersARB, glGenBuffersARB, glGetBufferParameterivARB,
 * glGetBufferSubDataARB, glIsBufferARB, glMapBufferARB, glUnmapBufferARB and all GL_*_ARB constants are inherited and
 * link correctly against ARBBufferObject.* (static members are resolved through the superclass chain).
 * Added here: the LWJGL 2 form of glGetBufferPointerARB(int, int, long) returning a ByteBuffer
 * (LWJGL 3 only has the (int, int) -> long form).
 */
package org.lwjgl.opengl;

import java.nio.ByteBuffer;

import org.lwjgl.system.MemoryUtil;

public class ARBBufferObject extends ARBVertexBufferObject
{
    /**
     * LWJGL 2 variant: returns the buffer object pointer as a ByteBuffer of {@code result_size} bytes.
     * Returns null if the pointer is NULL.
     */
    public static ByteBuffer glGetBufferPointerARB(int target, int pname, long result_size) {
        long pointer = ARBVertexBufferObject.glGetBufferPointerARB(target, pname);
        if (pointer == 0L) return null;
        return MemoryUtil.memByteBuffer(pointer, (int) result_size);
    }
}
