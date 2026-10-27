package org.lwjgl.opengl;

/** LWJGL 2 compatibility class for EXT_multi_draw_arrays (constants from the LWJGL 2 template; functions delegate to LWJGL 3). */
public final class EXTMultiDrawArrays {
	private EXTMultiDrawArrays() {}

	public static void glMultiDrawArraysEXT(int mode, java.nio.IntBuffer piFirst, java.nio.IntBuffer piCount) { GL14.glMultiDrawArrays(mode, piFirst, piCount); }
}
