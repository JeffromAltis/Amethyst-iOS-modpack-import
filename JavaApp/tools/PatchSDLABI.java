import java.nio.file.*;
import jdk.internal.org.objectweb.asm.*;

/**
 * Keeps the public signatures of Amethyst's former shim alongside LWJGL's native API.
 * A few shim struct getters exposed raw pointers where LWJGL exposes typed buffers.
 * The JVM supports both return descriptors; Java source cannot declare both overloads.
 * Applied only to our merged SDL runtime, never to the upstream binding jar.
 */
public final class PatchSDLABI implements Opcodes {
    private static final String PKG = "org/lwjgl/sdl/";
    private static final String MEMORY = "org/lwjgl/system/MemoryUtil";
    private static MethodVisitor method(ClassVisitor cv, int flags, String name, String desc) {
        MethodVisitor m = cv.visitMethod(flags, name, desc, null, null);
        m.visitCode(); return m;
    }
    private static void end(MethodVisitor m, int opcode) {
        m.visitInsn(opcode); m.visitMaxs(0, 0); m.visitEnd();
    }
    private static void address(MethodVisitor m, String owner) {
        m.visitVarInsn(ALOAD, 0);
        m.visitMethodInsn(INVOKEVIRTUAL, owner, "address", "()J", false);
    }
    private static void offset(MethodVisitor m, String owner, String field) {
        m.visitFieldInsn(GETSTATIC, owner, field, "I");
        m.visitInsn(I2L); m.visitInsn(LADD);
    }
    private static void pointers(ClassVisitor cv, String owner, String field, String name, boolean buffer) {
        String base = buffer ? owner.substring(0, owner.indexOf('$')) : owner;
        MethodVisitor m = method(cv, ACC_PUBLIC, name, "()J");
        address(m, owner); offset(m, base, field);
        m.visitMethodInsn(INVOKESTATIC, MEMORY, "memGetAddress", "(J)J", false); end(m, LRETURN);
        m = method(cv, ACC_PUBLIC, name, "(J)L" + owner + ";");
        address(m, owner); offset(m, base, field); m.visitVarInsn(LLOAD, 1);
        m.visitMethodInsn(INVOKESTATIC, MEMORY, "memPutAddress", "(JJ)V", false);
        m.visitVarInsn(ALOAD, 0); end(m, ARETURN);
        if (buffer) return;
        m = method(cv, ACC_PUBLIC | ACC_STATIC, "n" + name, "(J)J");
        m.visitVarInsn(LLOAD, 0); offset(m, base, field);
        m.visitMethodInsn(INVOKESTATIC, MEMORY, "memGetAddress", "(J)J", false); end(m, LRETURN);
        m = method(cv, ACC_PUBLIC | ACC_STATIC, "n" + name, "(JJ)V");
        m.visitVarInsn(LLOAD, 0); offset(m, base, field); m.visitVarInsn(LLOAD, 2);
        m.visitMethodInsn(INVOKESTATIC, MEMORY, "memPutAddress", "(JJ)V", false); end(m, RETURN);
    }
    private static void add(ClassVisitor cv, String owner) {
        if (owner.equals(PKG + "SDL_MessageBoxData") || owner.equals(PKG + "SDL_MessageBoxData$Buffer")) {
            boolean buffer = owner.endsWith("$Buffer");
            for (String name : new String[]{"title", "message", "buttons", "colorScheme"})
                pointers(cv, owner, name.toUpperCase(), name, buffer);
            MethodVisitor m = method(cv, ACC_PUBLIC, "numbuttons", "(I)L" + owner + ";");
            address(m, owner); m.visitVarInsn(ILOAD, 1);
            m.visitMethodInsn(INVOKESTATIC, PKG + "SDL_MessageBoxData", "nnumbuttons", "(JI)V", false);
            m.visitVarInsn(ALOAD, 0); end(m, ARETURN);
        } else if (owner.equals(PKG + "SDL_MessageBoxButtonData") || owner.equals(PKG + "SDL_MessageBoxButtonData$Buffer")) {
            pointers(cv, owner, "TEXT", "text", owner.endsWith("$Buffer"));
        } else if (owner.equals(PKG + "SDL_EventFilter") || owner.equals(PKG + "SDL_LogOutputFunction")) {
            String desc = "(L" + owner + "I;)L" + owner + ";";
            MethodVisitor m = method(cv, ACC_PUBLIC | ACC_STATIC, "createSafe", desc);
            Label nonnull = new Label(); m.visitVarInsn(ALOAD, 0); m.visitJumpInsn(IFNONNULL, nonnull);
            m.visitInsn(ACONST_NULL); m.visitInsn(ARETURN); m.visitLabel(nonnull); m.visitFrame(F_SAME, 0, null, 0, null); m.visitVarInsn(ALOAD, 0);
            m.visitMethodInsn(INVOKESTATIC, owner, "create", desc, false); end(m, ARETURN);
        } else if (owner.equals(PKG + "SDLStdinc")) {
            for (String type : new String[]{"ShortBuffer", "FloatBuffer"}) {
                MethodVisitor m = method(cv, ACC_PUBLIC | ACC_STATIC, "SDL_free", "(Ljava/nio/" + type + ";)V");
                m.visitVarInsn(ALOAD, 0);
                m.visitMethodInsn(INVOKESTATIC, MEMORY, "memAddressSafe", "(Ljava/nio/" + type + ";)J", false);
                m.visitMethodInsn(INVOKESTATIC, owner, "nSDL_free", "(J)V", false); end(m, RETURN);
            }
        } else if (owner.equals(PKG + "SDLGamepad")) {
            MethodVisitor m = method(cv, ACC_PUBLIC | ACC_STATIC, "SDL_ReloadGamepadMappings", "()I");
            m.visitMethodInsn(INVOKESTATIC, owner, "SDL_ReloadGamepadMappings", "()Z", false);
            m.visitInsn(ICONST_1); m.visitInsn(ISUB); end(m, IRETURN);
            m = method(cv, ACC_PUBLIC | ACC_STATIC, "SDL_GetGamepads", "(Ljava/nio/IntBuffer;)Ljava/nio/IntBuffer;");
            m.visitVarInsn(ALOAD, 0);
            m.visitMethodInsn(INVOKESTATIC, PKG + "SDL3Bridge", "gamepadsWithCount", "(Ljava/nio/IntBuffer;)Ljava/nio/IntBuffer;", false);
            end(m, ARETURN);
        }
    }
    public static void main(String[] args) throws Exception {
        for (String name : new String[]{"SDL_MessageBoxData", "SDL_MessageBoxData$Buffer", "SDL_MessageBoxButtonData", "SDL_MessageBoxButtonData$Buffer", "SDL_EventFilter", "SDL_LogOutputFunction", "SDLStdinc", "SDLGamepad"}) {
            final String owner = PKG + name;
            Path file = Paths.get(args[0], owner + ".class");
            ClassReader reader = new ClassReader(Files.readAllBytes(file));
            ClassWriter writer = new ClassWriter(reader, ClassWriter.COMPUTE_MAXS);
            reader.accept(new ClassVisitor(ASM5, writer) {
                public void visitEnd() { add(this, owner); super.visitEnd(); }
            }, 0);
            Files.write(file, writer.toByteArray());
        }
    }
}
