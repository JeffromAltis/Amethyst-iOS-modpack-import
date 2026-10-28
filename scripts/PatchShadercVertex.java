// Regenerates lwjgl-shaderc-overlay.jar: patches Shaderc.shaderc_compile_options_initialize to define the macro
// vertex -> mc_vertex, because MoltenVK 1.2.9 does not rename the GLSL function "vertex" (a Metal keyword).
// Usage (JDK 25): java scripts/PatchShadercVertex.java JavaApp/libs/lwjgl/lwjgl-shaderc.jar <outdir>
import java.lang.classfile.*;
import java.lang.constant.*;
import java.nio.file.*;
import java.util.zip.*;
import java.io.*;

public class Patch {
    public static void main(String[] a) throws Exception {
        ClassModel cm;
        try (ZipFile z = new ZipFile(a[0])) {
            byte[] in = z.getInputStream(z.getEntry("org/lwjgl/util/shaderc/Shaderc.class")).readAllBytes();
            ClassFile cf = ClassFile.of();
            cm = cf.parse(in);
            ClassDesc self = ClassDesc.of("org.lwjgl.util.shaderc.Shaderc");
            ClassDesc jni = ClassDesc.of("org.lwjgl.system.JNI");
            ClassDesc cs = ClassDesc.of("java.lang.CharSequence");
            byte[] out = cf.transformClass(cm, ClassTransform.transformingMethodBodies(
                m -> m.methodName().equalsString("shaderc_compile_options_initialize"),
                CodeTransform.ofStateful(() -> new CodeTransform() {
                    public void accept(CodeBuilder b, CodeElement e) {
                        if (e instanceof java.lang.classfile.instruction.InvokeInstruction i && i.name().equalsString("invokeP")) {
                            b.with(e);
                            b.lstore(2).lload(2).ldc("vertex").ldc("mc_vertex")
                             .invokestatic(self, "shaderc_compile_options_add_macro_definition",
                                MethodTypeDesc.of(ConstantDescs.CD_void, ConstantDescs.CD_long, cs, cs))
                             .lload(2);
                        } else b.with(e);
                    }
                })));
            Files.createDirectories(Path.of(a[1]).resolve("org/lwjgl/util/shaderc"));
            Files.write(Path.of(a[1]).resolve("org/lwjgl/util/shaderc/Shaderc.class"), out);
        }
    }
}
