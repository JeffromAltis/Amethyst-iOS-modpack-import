package net.kdt.patchjna;

import java.lang.instrument.ClassFileTransformer;
import java.lang.reflect.Constructor;
import java.lang.reflect.Method;
import java.security.ProtectionDomain;
import java.util.List;

/**
 * Wires Controlify's GLFW backend to org.lwjgl.glfw.ControlifyCompat (see there for why).
 *
 *  - GLFWControllerManager: every ControllerHIDService.fetchType(jid) call becomes
 *    ControlifyCompat.fetchType(service, jid), followed by a CHECKCAST back to ControllerHIDInfo.
 *  - GLFWGamepadDriver: ControlifyCompat.addComponents(jid, controller) before each return of
 *    addComponents(), and ControlifyCompat.update(jid, controller) at the start of update().
 *
 * Uses the ASM tree API of the class's own (Fabric) loader through reflection, because Java 25
 * no longer ships the JDK-internal ASM. Classes that don't match the expected shape are left
 * untouched, so the worst case is losing rumble or identification, never input.
 */
public class ControlifyCompatTransformer implements ClassFileTransformer {
    private static final String TAG = "[ControlifyCompat] ";
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

    private static final int ALOAD = 25, GETFIELD = 180, RETURN = 177, CHECKCAST = 192;
    private static final int INVOKEVIRTUAL = 182, INVOKESTATIC = 184;

    @Override
    public byte[] transform(ClassLoader loader, String className, Class<?> classBeingRedefined,
                            ProtectionDomain protectionDomain, byte[] classfileBuffer) {
        if (loader == null || !(MANAGER.equals(className) || DRIVER.equals(className))) return null;
        try {
            return new Patch(loader, classfileBuffer).run(MANAGER.equals(className));
        } catch (Throwable t) {
            log("failed to patch " + className + ": " + t);
            return null;
        }
    }

    private static void log(String message) {
        System.out.println(TAG + message);
    }

    /** One class rewrite over the reflected ASM tree API. */
    private static final class Patch {
        final ClassLoader loader;
        final byte[] bytes;
        final Class<?> nodeType, visitorType, insnType, listType, methodInsnType;
        final Object node;

        Patch(ClassLoader loader, byte[] bytes) throws Exception {
            this.loader = loader;
            this.bytes = bytes;
            nodeType = load("tree.ClassNode");
            visitorType = load("ClassVisitor");
            insnType = load("tree.AbstractInsnNode");
            listType = load("tree.InsnList");
            methodInsnType = load("tree.MethodInsnNode");
            node = nodeType.getConstructor().newInstance();
            Class<?> readerType = load("ClassReader");
            Object reader = readerType.getConstructor(byte[].class).newInstance((Object) bytes);
            readerType.getMethod("accept", visitorType, int.class).invoke(reader, node, 0);
        }

        Class<?> load(String name) throws ClassNotFoundException {
            return loader.loadClass("org.objectweb.asm." + name);
        }

        byte[] run(boolean manager) throws Exception {
            boolean changed = manager ? patchManager() : patchDriver();
            if (!changed) return null;
            Class<?> writerType = load("ClassWriter");
            Object writer = writerType.getConstructor(int.class).newInstance(1); // COMPUTE_MAXS
            nodeType.getMethod("accept", visitorType).invoke(node, writer);
            return (byte[]) writerType.getMethod("toByteArray").invoke(writer);
        }

        List<?> list(Object owner, String field) throws Exception {
            return (List<?>) owner.getClass().getField(field).get(owner);
        }

        String str(Object owner, String field) throws Exception {
            return (String) owner.getClass().getField(field).get(owner);
        }

        Object[] insns(Object method) throws Exception {
            Object list = method.getClass().getField("instructions").get(method);
            return (Object[]) listType.getMethod("toArray").invoke(list);
        }

        Object methodList(Object method) throws Exception {
            return method.getClass().getField("instructions").get(method);
        }

        int opcode(Object insn) throws Exception {
            return (Integer) insnType.getMethod("getOpcode").invoke(insn);
        }

        Object newList(Object... insns) throws Exception {
            Object list = listType.getConstructor().newInstance();
            Method add = listType.getMethod("add", insnType);
            for (Object insn : insns) add.invoke(list, insn);
            return list;
        }

        Object var(int op, int slot) throws Exception {
            return load("tree.VarInsnNode").getConstructor(int.class, int.class).newInstance(op, slot);
        }

        Object invokeStatic(String name, String desc) throws Exception {
            return methodInsnType.getConstructor(int.class, String.class, String.class, String.class, boolean.class)
                .newInstance(INVOKESTATIC, HOOKS, name, desc, false);
        }

        /** ControlifyCompat.hook(this.jid, controller) */
        Object driverHook(String hook) throws Exception {
            Object field = load("tree.FieldInsnNode").getConstructor(int.class, String.class, String.class, String.class)
                .newInstance(GETFIELD, DRIVER, "jid", "I");
            return newList(var(ALOAD, 0), field, var(ALOAD, 1), invokeStatic(hook, DRIVER_HOOK_DESC));
        }

        boolean patchManager() throws Exception {
            int patched = 0;
            Method insertAfter = listType.getMethod("insert", insnType, insnType);
            Constructor<?> typeInsn = load("tree.TypeInsnNode").getConstructor(int.class, String.class);
            for (Object method : list(node, "methods")) {
                Object instructions = methodList(method);
                for (Object insn : insns(method)) {
                    if (!methodInsnType.isInstance(insn) || opcode(insn) != INVOKEVIRTUAL) continue;
                    if (!HID_SERVICE.equals(str(insn, "owner")) || !"fetchType".equals(str(insn, "name"))
                            || !FETCH_TYPE_DESC.equals(str(insn, "desc"))) continue;
                    // [service, jid] -> ControlifyCompat.fetchType(service, jid) -> (ControllerHIDInfo)
                    methodInsnType.getMethod("setOpcode", int.class).invoke(insn, INVOKESTATIC);
                    methodInsnType.getField("owner").set(insn, HOOKS);
                    methodInsnType.getField("desc").set(insn, FETCH_TYPE_HOOK_DESC);
                    methodInsnType.getField("itf").setBoolean(insn, false);
                    insertAfter.invoke(instructions, insn, typeInsn.newInstance(CHECKCAST, HID_INFO));
                    patched++;
                }
            }
            if (patched == 0) {
                log("no controller type lookup found in GLFWControllerManager, not patching");
                return false;
            }
            log("patched " + patched + " controller type lookup(s)");
            return true;
        }

        boolean patchDriver() throws Exception {
            boolean jid = false;
            for (Object f : list(node, "fields")) {
                if ("jid".equals(str(f, "name")) && "I".equals(str(f, "desc"))) jid = true;
            }
            Object add = null, update = null;
            for (Object m : list(node, "methods")) {
                if ("addComponents".equals(str(m, "name")) && ADD_COMPONENTS_DESC.equals(str(m, "desc"))) add = m;
                if ("update".equals(str(m, "name")) && UPDATE_DESC.equals(str(m, "desc"))) update = m;
            }
            if (!jid || add == null || update == null) {
                log("GLFWGamepadDriver layout not recognised, rumble not patched");
                return false;
            }
            Method insertBefore = listType.getMethod("insertBefore", insnType, listType);
            for (Object insn : insns(add)) {
                if (opcode(insn) == RETURN) insertBefore.invoke(methodList(add), insn, driverHook("addComponents"));
            }
            listType.getMethod("insert", listType).invoke(methodList(update), driverHook("update"));
            log("patched GLFWGamepadDriver for rumble");
            return true;
        }
    }
}
