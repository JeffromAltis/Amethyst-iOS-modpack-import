package org.lwjgl.opengl;

/** LWJGL 2 compatibility class for EXT_fog_coord (constants from the LWJGL 2 template; functions delegate to LWJGL 3). */
public final class EXTFogCoord {
	public static final int GL_FOG_COORDINATE_SOURCE_EXT = 0x8450;
	public static final int GL_FOG_COORDINATE_EXT = 0x8451;
	public static final int GL_FRAGMENT_DEPTH_EXT = 0x8452;
	public static final int GL_CURRENT_FOG_COORDINATE_EXT = 0x8453;
	public static final int GL_FOG_COORDINATE_ARRAY_TYPE_EXT = 0x8454;
	public static final int GL_FOG_COORDINATE_ARRAY_STRIDE_EXT = 0x8455;
	public static final int GL_FOG_COORDINATE_ARRAY_POINTER_EXT = 0x8456;
	public static final int GL_FOG_COORDINATE_ARRAY_EXT = 0x8457;

	private EXTFogCoord() {}

	public static void glFogCoordfEXT(float coord) { GL14.glFogCoordf(coord); }
	public static void glFogCoorddEXT(double coord) { GL14.glFogCoordd(coord); }
	public static void glFogCoordPointerEXT(int type, int stride, java.nio.FloatBuffer data) { GL14.glFogCoordPointer(type, stride, data); }
	public static void glFogCoordPointerEXT(int type, int stride, java.nio.ByteBuffer data) { GL14.glFogCoordPointer(type, stride, data); }
	public static void glFogCoordPointerEXT(int type, int stride, java.nio.ShortBuffer data) { GL14.glFogCoordPointer(type, stride, data); }
	public static void glFogCoordPointerEXT(int type, int stride, long data_buffer_offset) { GL14.glFogCoordPointer(type, stride, data_buffer_offset); }
}
