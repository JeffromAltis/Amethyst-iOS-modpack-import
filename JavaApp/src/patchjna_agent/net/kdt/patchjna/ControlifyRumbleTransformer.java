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
 * Gives Controlify's GLFW gamepad driver rumble on iOS.
 *
 * Controlify only rumbles through its SDL3 backend, which can't run on iOS
 * (JNA direct mapping freezes). Like MeloNX, Amethyst instead reads the
 * controller natively and passes it to the game (the GLFW gamepad bridge) and
 * plays rumble itself with CoreHaptics. This patch closes the loop:
 *
 *  - GLFWGamepadDriver.addComponents(controller) additionally calls
 *    GLFW.amethystControlifyAddComponents(jid, controller), which attaches a
 *    Controlify RumbleComponent when the controller has haptics.
 *  - GLFWGamepadDriver.update(controller, outOfFocus) first calls
 *    GLFW.amethystControlifyUpdate(jid, controller), which forwards queued
 *    rumble to the native haptics player.
 *
 * Both helpers live in Amethyst's GLFW class, which Controlify already links
 * against, and use reflection so nothing here depends on Controlify's classes.
 * If the driver doesn't look as expected (different Controlify version), the
 * class is left untouched.
 */
public class ControlifyRumbleTransformer implements ClassFileTransformer {
    // ASM API level 9 (records, nest members, sealed classes). Controlify is built for
    // Java 21, and the JDK's internal ASM rejects those attributes at lower levels.
    // Written as a number so this still compiles against Java 8's internal ASM.
    private static final int ASM_API = 9 << 16;
    private static final String TARGET = "dev/isxander/controlify/driver/glfw/GLFWGamepadDriver";
    private static final String CONTROLLER_ENTITY = "Ldev/isxander/controlify/controller/ControllerEntity;";
    private static final String ADD_COMPONENTS_DESC = "(" + CONTROLLER_ENTITY + ")V";
    private static final String UPDATE_DESC = "(" + CONTROLLER_ENTITY + "Z)V";
    private static final String HOOKS = "org/lwjgl/glfw/GLFW";
    private static final String HOOK_DESC = "(ILjava/lang/Object;)V";

    // Controller type: GLFWControllerManager asks ControllerHIDService.fetchType(jid),
    // which needs a USB/HID scan that can't run on iOS. Route the call through
    // GLFW.amethystControlifyFetchType(service, jid), which identifies the
    // controller from the vendor/product IDs iOS reports (falling back to the
    // original lookup). Same stack shape as the original call, so no frames change.
    private static final String MANAGER = "dev/isxander/controlify/controllermanager/GLFWControllerManager";
    private static final String HID_SERVICE = "dev/isxander/controlify/hid/ControllerHIDService";
    private static final String HID_INFO = "dev/isxander/controlify/hid/ControllerHIDService$ControllerHIDInfo";
    private static final String FETCH_TYPE_DESC = "(I)L" + HID_INFO + ";";

    @Override
    public byte[] transform(ClassLoader loader, String className, Class<?> classBeingRedefined,
                            ProtectionDomain protectionDomain, byte[] classfileBuffer) {
        if (MANAGER.equals(className)) {
            return patchManager(classfileBuffer);
        }
        if (!TARGET.equals(className)) {
            return null;
        }
        try {
            ClassReader reader = new ClassReader(classfileBuffer);

            // Only patch the layout we know: an int "jid" field and both methods
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
            if (!found[0] || !found[1] || !found[2]) {
                System.out.println("ControlifyRumble: GLFWGamepadDriver layout not recognised, not patching");
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
                                if (opcode == Opcodes.RETURN) {
                                    emitHook("amethystControlifyAddComponents", this);
                                }
                                super.visitInsn(opcode);
                            }
                        };
                    }
                    if ("update".equals(name) && UPDATE_DESC.equals(desc)) {
                        return new MethodVisitor(ASM_API, mv) {
                            @Override
                            public void visitCode() {
                                super.visitCode();
                                emitHook("amethystControlifyUpdate", this);
                            }
                        };
                    }
                    return mv;
                }
            }, 0);
            System.out.println("ControlifyRumble: patched GLFWGamepadDriver for rumble");
            return writer.toByteArray();
        } catch (Throwable t) {
            System.out.println("ControlifyRumble: failed to patch GLFWGamepadDriver: " + t);
            return null;
        }
    }

    private static byte[] patchManager(byte[] classfileBuffer) {
        try {
            ClassReader reader = new ClassReader(classfileBuffer);
            ClassWriter writer = new ClassWriter(reader, ClassWriter.COMPUTE_MAXS);
            final int[] patched = new int[1];
            reader.accept(new ClassVisitor(ASM_API, writer) {
                @Override
                public MethodVisitor visitMethod(int access, String name, String desc, String signature, String[] exceptions) {
                    return new MethodVisitor(ASM_API, super.visitMethod(access, name, desc, signature, exceptions)) {
                        @Override
                        public void visitMethodInsn(int opcode, String owner, String name, String desc, boolean isInterface) {
                            if (opcode == Opcodes.INVOKEVIRTUAL && HID_SERVICE.equals(owner)
                                    && "fetchType".equals(name) && FETCH_TYPE_DESC.equals(desc)) {
                                // [service, jid] -> GLFW.amethystControlifyFetchType(service, jid) -> ControllerHIDInfo
                                super.visitMethodInsn(Opcodes.INVOKESTATIC, HOOKS, "amethystControlifyFetchType",
                                    "(Ljava/lang/Object;I)Ljava/lang/Object;", false);
                                super.visitTypeInsn(Opcodes.CHECKCAST, HID_INFO);
                                patched[0]++;
                                return;
                            }
                            super.visitMethodInsn(opcode, owner, name, desc, isInterface);
                        }
                    };
                }
            }, 0);
            if (patched[0] == 0) {
                System.out.println("ControlifyRumble: GLFWControllerManager has no fetchType call, not patching");
                return null;
            }
            System.out.println("ControlifyRumble: patched " + patched[0] + " controller type lookup(s)");
            return writer.toByteArray();
        } catch (Throwable t) {
            System.out.println("ControlifyRumble: failed to patch GLFWControllerManager: " + t);
            return null;
        }
    }

    /** GLFW.hook(this.jid, controller) */
    private static void emitHook(String hook, MethodVisitor mv) {
        mv.visitVarInsn(Opcodes.ALOAD, 0);
        mv.visitFieldInsn(Opcodes.GETFIELD, TARGET, "jid", "I");
        mv.visitVarInsn(Opcodes.ALOAD, 1);
        mv.visitMethodInsn(Opcodes.INVOKESTATIC, HOOKS, hook, HOOK_DESC, false);
    }
}
