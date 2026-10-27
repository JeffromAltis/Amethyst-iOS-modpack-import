package org.lwjgl.opengl;

/** LWJGL 2 compatibility class for EXT_draw_range_elements (constants from the LWJGL 2 template; functions delegate to LWJGL 3). */
public final class EXTDrawRangeElements {
	public static final int GL_MAX_ELEMENTS_VERTICES_EXT = 0x80E8;
	public static final int GL_MAX_ELEMENTS_INDICES_EXT = 0x80E9;

	private EXTDrawRangeElements() {}

	public static void glDrawRangeElementsEXT(int mode, int start, int end, java.nio.ByteBuffer indices) { GL12.glDrawRangeElements(mode, start, end, indices); }
	public static void glDrawRangeElementsEXT(int mode, int start, int end, java.nio.ShortBuffer indices) { GL12.glDrawRangeElements(mode, start, end, indices); }
	public static void glDrawRangeElementsEXT(int mode, int start, int end, java.nio.IntBuffer indices) { GL12.glDrawRangeElements(mode, start, end, indices); }
	public static void glDrawRangeElementsEXT(int mode, int start, int end, int count, int type, long indices_buffer_offset) { GL12.glDrawRangeElements(mode, start, end, count, type, indices_buffer_offset); }
}
