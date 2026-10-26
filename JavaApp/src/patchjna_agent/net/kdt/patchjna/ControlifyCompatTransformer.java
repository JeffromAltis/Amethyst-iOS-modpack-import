package net.kdt.patchjna;

import java.lang.instrument.ClassFileTransformer;
import java.security.ProtectionDomain;

import jdk.internal.org.objectweb.asm.ClassReader;
import jdk.internal.org.objectweb.asm.ClassVisitor;
import jdk.internal.org.objectweb.asm.ClassWriter;
import jdk.internal.org.objectweb.asm.FieldVisitor;
import jdk.internal.org.objectweb.asm.MethodVisitor;
import jdk.internal.org.objectweb.asm.Opcodes;

/**
 * Wires Controlify's GLFW backend to org.lwjgl.glfw.ControlifyCompat (see there for why).
 *
 *  - GLFWControllerManager: every ControllerHIDService.fetchType(jid) call becomes
 *    ControlifyCompat.fetchType(service, jid). Same stack shape and a CHECKCAST
 *    back to ControllerHIDInfo, so no stack map frames change.
 *  - GLFWGamepadDriver: ControlifyCompat.addComponents(jid, controller) before each
 *    return of addComponents(), and ControlifyCompat.update(jid, controller) at the
 *    start of update().
 *
 * Classes that don't match the expected shape (another Controlify version) are left
 * untouched, so the worst case is losing rumble or identification, never input.
 * Uses the JDK's internal ASM, exported to the agent by JavaLauncher.
 */
public class ControlifyCompatTransformer implements ClassFileTransformer {
    private static final String TAG = "[ControlifyCompat] ";

    // ASM API level 9 (records, nest members, sealed classes): Controlify targets Java 21.
    // A literal so this still compiles against Java 8's internal ASM.
    private static final int ASM_API = 9 << 16;

    private static final String HOOKS = "org/lwjgl/glfw/ControlifyCompat";

    private static final String MANAGER = "dev/isxander/controlify/controllermanager/GLFWControllerManager";
    private static final String HID_SERVICE = "dev/isxander/controlify/hid/ControllerHIDService";
    private static final String HID_INFO = "dev/isxander/controlify/hid/ControllerHIDService$ControllerHIDInfo";
    private static final String FETCH_TYPE_DESC = "(I)L" + HID_INFO + ";";
    private static final String FETCH_TYPE_HOOK_DESC = "(Ljava/lang/Object;I)Ljava/lang/Object;";

    private static final String DRIVER = "dev/isxander/controlify/driver/glfw/GLFWGamepadDriver";
    private static final String CONTROLLER_ENTITY = "Ldev/isxander/controlify/controller/ControllerEntity;";
    private static final String ADD_COMPONENTS_DESC = "(" + CONTROLLER_ENTITY + ")V";
    private static final String UPDATE_DESC = "(" + CONTROLLER_ENTITY + "Z)V";
    private static final String DRIVER_HOOK_DESC = "(ILjava/lang/Object;)V";

    @Override
    public byte[] transform(ClassLoader loader, String className, Class<?> classBeingRedefined,
                            ProtectionDomain protectionDomain, byte[] classfileBuffer) {
        try {
            if (MANAGER.equals(className)) return patchManager(classfileBuffer);
            if (DRIVER.equals(className)) return patchDriver(classfileBuffer);
        } catch (Throwable t) {
            log("failed to patch " + className + ": " + t);
        }
        return null;
    }

    private static void log(String message) {
        System.out.println(TAG + message);
    }

    private static byte[] patchManager(byte[] classfile) {
        ClassReader reader = new ClassReader(classfile);
        ClassWriter writer = new ClassWriter(reader, ClassWriter.COMPUTE_MAXS);
        final int[] patched = {0};
        reader.accept(new ClassVisitor(ASM_API, writer) {
            @Override
            public MethodVisitor visitMethod(int access, String name, String desc, String signature, String[] exceptions) {
                return new MethodVisitor(ASM_API, super.visitMethod(access, name, desc, signature, exceptions)) {
                    @Override
                    public void visitMethodInsn(int opcode, String owner, String name, String desc, boolean isInterface) {
                        if (opcode == Opcodes.INVOKEVIRTUAL && HID_SERVICE.equals(owner)
                                && "fetchType".equals(name) && FETCH_TYPE_DESC.equals(desc)) {
                            // [service, jid] -> ControlifyCompat.fetchType(service, jid) -> (ControllerHIDInfo)
                            super.visitMethodInsn(Opcodes.INVOKESTATIC, HOOKS, "fetchType", FETCH_TYPE_HOOK_DESC, false);
                            super.visitTypeInsn(Opcodes.CHECKCAST, HID_INFO);
                            patched[0]++;
                        } else {
                            super.visitMethodInsn(opcode, owner, name, desc, isInterface);
                        }
                    }
                };
            }
        }, 0);
        if (patched[0] == 0) {
            log("no controller type lookup found in GLFWControllerManager, not patching");
            return null;
        }
        log("patched " + patched[0] + " controller type lookup(s)");
        return writer.toByteArray();
    }

    private static byte[] patchDriver(byte[] classfile) {
        ClassReader reader = new ClassReader(classfile);
        if (!hasExpectedDriverShape(reader)) {
            log("GLFWGamepadDriver layout not recognised, rumble not patched");
            return null;
        }
        ClassWriter writer = new ClassWriter(reader, ClassWriter.COMPUTE_MAXS);
        reader.accept(new ClassVisitor(ASM_API, writer) {
            @Override
            public MethodVisitor visitMethod(int access, String name, String desc, String signature, String[] exceptions) {
                MethodVisitor mv = super.visitMethod(access, name, desc, signature, exceptions);
                if ("addComponents".equals(name) && ADD_COMPONENTS_DESC.equals(desc)) {
                    return new MethodVisitor(ASM_API, mv) {
                        @Override
                        public void visitInsn(int opcode) {
                            if (opcode == Opcodes.RETURN) emitDriverHook(this, "addComponents");
                            super.visitInsn(opcode);
                        }
                    };
                }
                if ("update".equals(name) && UPDATE_DESC.equals(desc)) {
                    return new MethodVisitor(ASM_API, mv) {
                        @Override
                        public void visitCode() {
                            super.visitCode();
                            emitDriverHook(this, "update");
                        }
                    };
                }
                return mv;
            }
        }, 0);
        log("patched GLFWGamepadDriver for rumble");
        return writer.toByteArray();
    }

    /** Requires an int "jid" field and both hooked methods. */
    private static boolean hasExpectedDriverShape(ClassReader reader) {
        final boolean[] found = new boolean[3];
        reader.accept(new ClassVisitor(ASM_API) {
            @Override
            public FieldVisitor visitField(int access, String name, String desc, String signature, Object value) {
                if ("jid".equals(name) && "I".equals(desc)) found[0] = true;
                return null;
            }

            @Override
            public MethodVisitor visitMethod(int access, String name, String desc, String signature, String[] exceptions) {
                if ("addComponents".equals(name) && ADD_COMPONENTS_DESC.equals(desc)) found[1] = true;
                if ("update".equals(name) && UPDATE_DESC.equals(desc)) found[2] = true;
                return null;
            }
        }, ClassReader.SKIP_CODE);
        return found[0] && found[1] && found[2];
    }

    /** ControlifyCompat.hook(this.jid, controller) */
    private static void emitDriverHook(MethodVisitor mv, String hook) {
        mv.visitVarInsn(Opcodes.ALOAD, 0);
        mv.visitFieldInsn(Opcodes.GETFIELD, DRIVER, "jid", "I");
        mv.visitVarInsn(Opcodes.ALOAD, 1);
        mv.visitMethodInsn(Opcodes.INVOKESTATIC, HOOKS, hook, DRIVER_HOOK_DESC, false);
    }
}
