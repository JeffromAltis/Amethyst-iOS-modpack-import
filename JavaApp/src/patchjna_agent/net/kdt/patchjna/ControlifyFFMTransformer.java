package net.kdt.patchjna;

import java.lang.instrument.ClassFileTransformer;
import java.lang.reflect.*;
import java.security.ProtectionDomain;
import java.util.List;

/** Uses Fabric's ASM, avoiding the internal ASM removed from Java 25. */
public final class ControlifyFFMTransformer implements ClassFileTransformer {
    private static final String OWNER = "dev/isxander/controlify/driver/sdl/SDLNativesLoader";
    @Override public byte[] transform(ClassLoader loader, String name, Class<?> redef,
            ProtectionDomain domain, byte[] bytes) {
        if (!OWNER.equals(name) || loader == null) return null;
        try {
            Class<?> readerType = loader.loadClass("org.objectweb.asm.ClassReader");
            Class<?> visitorType = loader.loadClass("org.objectweb.asm.ClassVisitor");
            Class<?> writerType = loader.loadClass("org.objectweb.asm.ClassWriter");
            Class<?> nodeType = loader.loadClass("org.objectweb.asm.tree.ClassNode");
            Object node = nodeType.getConstructor().newInstance();
            Object reader = readerType.getConstructor(byte[].class).newInstance((Object)bytes);
            readerType.getMethod("accept", visitorType, int.class).invoke(reader, node, 0);
            Object target = null;
            boolean start = false;
            for (Object method : (List<?>)nodeType.getField("methods").get(node)) {
                Class<?> type = method.getClass();
                String methodName = (String)type.getField("name").get(method);
                String desc = (String)type.getField("desc").get(method);
                if ((((Integer)type.getField("access").get(method)) & 8) == 0) continue;
                if (methodName.equals("load") && desc.equals("()Ldev/isxander/sdl/Sdl;")) target = method;
                if (methodName.equals("startSdl") && desc.equals("(Ldev/isxander/sdl/Sdl;)V")) start = true;
            }
            if (target == null || !start) return null; // Older JNA loaders retain their fallback.
            Class<?> methodType = target.getClass();
            Object instructions = methodType.getField("instructions").get(target);
            Class<?> listType = instructions.getClass();
            listType.getMethod("clear").invoke(instructions);
            Class<?> insnType = loader.loadClass("org.objectweb.asm.tree.AbstractInsnNode");
            Method add = listType.getMethod("add", insnType);
            Object ownerType = loader.loadClass("org.objectweb.asm.Type").getMethod("getObjectType", String.class).invoke(null, OWNER);
            add.invoke(instructions, loader.loadClass("org.objectweb.asm.tree.LdcInsnNode").getConstructor(Object.class).newInstance(ownerType));
            add.invoke(instructions, loader.loadClass("org.objectweb.asm.tree.MethodInsnNode")
                    .getConstructor(int.class, String.class, String.class, String.class, boolean.class)
                    .newInstance(184, "net/kdt/patchjna/ControlifySDL", "load", "(Ljava/lang/Class;)Ljava/lang/Object;", false));
            add.invoke(instructions, loader.loadClass("org.objectweb.asm.tree.TypeInsnNode")
                    .getConstructor(int.class, String.class).newInstance(192, "dev/isxander/sdl/Sdl"));
            add.invoke(instructions, loader.loadClass("org.objectweb.asm.tree.InsnNode").getConstructor(int.class).newInstance(176));
            for (String field : new String[]{"tryCatchBlocks", "localVariables", "visibleLocalVariableAnnotations", "invisibleLocalVariableAnnotations"}) {
                Object value = methodType.getField(field).get(target);
                if (value != null) ((List<?>)value).clear();
            }
            methodType.getField("maxStack").setInt(target, 1);
            methodType.getField("maxLocals").setInt(target, 0);
            Object writer = writerType.getConstructor(int.class).newInstance(1);
            nodeType.getMethod("accept", visitorType).invoke(node, writer);
            byte[] result = (byte[])writerType.getMethod("toByteArray").invoke(writer);
            System.out.println("[ControlifySDL] Patched FFM loader; older JNA path unchanged");
            return result;
        } catch (Throwable failure) {
            System.err.println("[ControlifySDL] Cannot integrate this SDL loader: " + failure);
            return null;
        }
    }
}
