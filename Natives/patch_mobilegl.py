#!/usr/bin/env python3
import re
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

APPLIED = "applied"
SKIPPED = "skipped"
FAILED = "failed"
WARNED = "warned"


def read(path):
    return path.read_text(encoding="utf-8")


def write(path, text):
    path.write_text(text, encoding="utf-8")


def replace_once(path, old, new, marker, label, required=True):
    if not path.is_file():
        print(f"[{label}] {path} not found", file=sys.stderr)
        return FAILED if required else WARNED
    text = read(path)
    if marker in text:
        print(f"[{label}] already applied")
        return SKIPPED
    if text.count(old) != 1:
        print(f"[{label}] expected block found {text.count(old)} times in {path.name}, not touching it", file=sys.stderr)
        return FAILED if required else WARNED
    write(path, text.replace(old, new, 1))
    print(f"[{label}] applied")
    return APPLIED


def ios_visibility(root):
    old = """if (APPLE AND MOBILEGL_IOS)
    target_compile_definitions(${CMAKE_PROJECT_NAME} PUBLIC MOBILEGL_IOS=1 _LIBCPP_DISABLE_AVAILABILITY)"""
    new = """if (APPLE AND MOBILEGL_IOS)
    target_compile_definitions(${CMAKE_PROJECT_NAME} PUBLIC MOBILEGL_IOS=1 _LIBCPP_DISABLE_AVAILABILITY)

    set(MOBILEGL_IOS_EXPORTED_SYMBOLS
        "${CMAKE_CURRENT_SOURCE_DIR}/MobileGL/MG_Impl/DyldInterpose/ExportedSymbols.txt")
    target_link_options(${CMAKE_PROJECT_NAME} PRIVATE
        "LINKER:-exported_symbols_list,${MOBILEGL_IOS_EXPORTED_SYMBOLS}")
    set_property(TARGET ${CMAKE_PROJECT_NAME} APPEND PROPERTY
        LINK_DEPENDS "${MOBILEGL_IOS_EXPORTED_SYMBOLS}")"""
    return replace_once(root / "CMakeLists.txt", old, new, "MOBILEGL_IOS_EXPORTED_SYMBOLS", "ios_visibility")


def ios_resolution(root):
    old = """        VkImageBlit blitRegion{};
        blitRegion.srcSubresource.aspectMask = srcBinding.aspectMask;"""
    new = """        // resolution slider: the source fbo is smaller but the dst rect can end up the same size,
        // so stretch it over the whole swapchain and let the blit scale it
        if (drawIsDefaultFbo) {
            const Int requestedSrcWidth = std::abs(srcX1 - srcX0);
            const Int requestedSrcHeight = std::abs(srcY1 - srcY0);
            const Int requestedDstWidth = std::abs(dstX1 - dstX0);
            const Int requestedDstHeight = std::abs(dstY1 - dstY0);

            const Uint32 framebufferWidth = dstBinding.extent.x();
            const Uint32 framebufferHeight = dstBinding.extent.y();

            const Bool isFullscreenScaledBlit =
                requestedSrcWidth > 0 &&
                requestedSrcHeight > 0 &&
                requestedDstWidth == requestedSrcWidth &&
                requestedDstHeight == requestedSrcHeight &&
                (requestedDstWidth != static_cast<Int>(framebufferWidth) ||
                 requestedDstHeight != static_cast<Int>(framebufferHeight));

            if (isFullscreenScaledBlit) {
                dstX0 = 0;
                dstY0 = 0;
                dstX1 = static_cast<GLint>(framebufferWidth);
                dstY1 = static_cast<GLint>(framebufferHeight);
            }
        }

        VkImageBlit blitRegion{};
        blitRegion.srcSubresource.aspectMask = srcBinding.aspectMask;"""
    target = root / "MobileGL/MG_Backend/DirectVulkan/Renderer/VulkanRenderer.cpp"
    return replace_once(target, old, new, "isFullscreenScaledBlit", "ios_resolution")


def hash_shim(root):
    shim_rel = "MobileGL/MG_Util/Compat/libcxx_hash_shim.cpp"
    anchor = "MobileGL/MG_Util/Debug/Log.cpp"

    src = HERE / "libcxx_hash_shim.cpp"
    dst = root / shim_rel
    if src.is_file():
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)
        print("[hash_shim] copied libcxx_hash_shim.cpp")
    elif not dst.is_file():
        print(f"[hash_shim] {src} missing and {shim_rel} not in the checkout", file=sys.stderr)
        return FAILED

    target = root / "CMakeLists.txt"
    if not target.is_file():
        print(f"[hash_shim] {target} not found", file=sys.stderr)
        return FAILED
    text = read(target)
    if shim_rel in text:
        print("[hash_shim] cmake entry already there")
        return SKIPPED
    if anchor not in text:
        print(f"[hash_shim] anchor {anchor} not in CMakeLists.txt, upstream moved it", file=sys.stderr)
        return FAILED

    out = []
    done = False
    for line in text.splitlines(keepends=True):
        out.append(line)
        if not done and anchor in line:
            out.append(f"\n    {shim_rel}\n")
            done = True
    write(target, "".join(out))
    print("[hash_shim] applied")
    return APPLIED


def enable_availability(root):
    target = root / "CMakeLists.txt"
    if not target.is_file():
        print(f"[enable_availability] {target} not found", file=sys.stderr)
        return FAILED
    text = read(target)
    if "_LIBCPP_DISABLE_AVAILABILITY" not in text:
        print("[enable_availability] already applied")
        return SKIPPED
    pattern = re.compile(
        r"(target_compile_definitions\(\$\{CMAKE_PROJECT_NAME\}(?:_s)? PUBLIC MOBILEGL_IOS=1) _LIBCPP_DISABLE_AVAILABILITY(\))")
    text, count = pattern.subn(r"\1\2", text)
    if count == 0:
        print("[enable_availability] pattern not found, CMakeLists.txt changed upstream", file=sys.stderr)
        return FAILED
    write(target, text)
    print(f"[enable_availability] applied to {count} target(s)")
    return APPLIED


def glslang(root):
    target = root / "3rdparty/glslang/SPIRV/GlslangToSpv.cpp"
    old = """// Convert a glslang AST swizzle node to a swizzle vector for building SPIR-V.
void TGlslangToSpvTraverser::convertSwizzle(const glslang::TIntermAggregate& node, std::vector<unsigned>& swizzle)
{
    const glslang::TIntermSequence& swizzleSequence = node.getSequence();
    for (int i = 0; i < (int)swizzleSequence.size(); ++i)
        swizzle.push_back(swizzleSequence[i]->getAsConstantUnion()->getConstArray()[0].getIConst());
}"""
    new = """// Convert a glslang AST swizzle node to a swizzle vector for building SPIR-V.
void TGlslangToSpvTraverser::convertSwizzle(const glslang::TIntermAggregate& node, std::vector<unsigned>& swizzle)
{
    const glslang::TIntermSequence& swizzleSequence = node.getSequence();
    for (int i = 0; i < (int)swizzleSequence.size(); ++i) {
        // non-constant index node used to null deref and kill the whole jvm, fall back to .x instead
        const glslang::TIntermConstantUnion* constUnion = swizzleSequence[i]->getAsConstantUnion();
        if (constUnion == nullptr) {
            fprintf(stderr, "[glslang] convertSwizzle: non-constant swizzle index element %d, using component 0\\n", i);
            swizzle.push_back(0);
            continue;
        }
        swizzle.push_back(constUnion->getConstArray()[0].getIConst());
    }
}"""
    return replace_once(target, old, new, "using component 0", "glslang", required=False)


def metal_shader_names(root):
    target = root / "MobileGL/MG_Backend/DirectVulkan/Renderer/ProgramFactory.cpp"
    shutil.copyfile(HERE / "metal_shader_names.h", target.parent / "AmethystMetalShaderNames.h")
    result = replace_once(target, '#include "ProgramFactory.h"',
                          '#include "ProgramFactory.h"\n#include "AmethystMetalShaderNames.h"',
                          'AmethystMetalShaderNames.h', 'metal_shader_names_include')
    if result == FAILED:
        return FAILED
    old = """            VkShaderModuleCreateInfo smci{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
            smci.codeSize = moduleSpv.size() * sizeof(Uint);"""
    new = """#if defined(MOBILEGL_IOS)
            // ReflectLayout below still needs the original GL uniform names.
            auto metalModuleSpv = moduleSpv;
            AmethystMetalShaderNames(metalModuleSpv);
            const auto& driverModuleSpv = metalModuleSpv;
#else
            const auto& driverModuleSpv = moduleSpv;
#endif
            VkShaderModuleCreateInfo smci{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
            smci.codeSize = driverModuleSpv.size() * sizeof(Uint);"""
    # Migrate the earlier local patch without leaving its in-place rename behind.
    legacy = """#if defined(MOBILEGL_IOS)
            AmethystMetalShaderNames(moduleSpv);
#endif
"""
    source = read(target)
    if legacy in source:
        write(target, source.replace(legacy, "", 1))
    result = replace_once(target, old, new, 'auto metalModuleSpv = moduleSpv', 'metal_shader_names')
    if result == FAILED:
        return FAILED
    return replace_once(target, '            smci.pCode = moduleSpv.data();',
                        '            smci.pCode = driverModuleSpv.data();',
                        'smci.pCode = driverModuleSpv.data()', 'metal_shader_code')



def draw_input_trace(root):
    target = root / "MobileGL/MG_Backend/DirectVulkan/Renderer/UniformManager.cpp"
    shutil.copyfile(HERE / "mobilegl_draw_trace.h", target.parent / "AmethystDrawTrace.h")
    result = replace_once(target, '#include <limits>',
        '#include <limits>\n#if defined(MOBILEGL_IOS)\n#include "AmethystDrawTrace.h"\n#endif',
        'AmethystDrawTrace.h', 'draw_trace_include')
    if result == FAILED:
        return FAILED
    old = """        const auto preferredTarget = programObj.samplerTextureTargetByBinding[binding];"""
    new = old + """
#if defined(MOBILEGL_IOS)
        AmethystTraceDrawInputs(program, binding, programObj.samplerNameByBinding[binding].c_str(), unit,
            texture, samplerOverride ? samplerOverride.get() : (texture ? texture->GetSamplerObject().get() : nullptr));
#endif"""
    return replace_once(target, old, new, 'AmethystTraceDrawInputs(program', 'draw_trace')


STEPS = [
    ("draw_input_trace", draw_input_trace, True),
    ("metal_shader_names", metal_shader_names, True),
    ("ios_visibility", ios_visibility, True),
    ("ios_resolution", ios_resolution, True),
    ("hash_shim", hash_shim, True),
    ("enable_availability", enable_availability, True),
    ("glslang", glslang, False),
]


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <path-to-mobilegl-checkout>", file=sys.stderr)
        return 1

    root = Path(sys.argv[1]).resolve()
    if not (root / "CMakeLists.txt").is_file():
        print(f"{root} doesn't look like a MobileGL checkout", file=sys.stderr)
        return 1

    failed = []
    for name, step, required in STEPS:
        try:
            result = step(root)
        except Exception as e:
            print(f"[{name}] crashed: {e}", file=sys.stderr)
            result = FAILED if required else WARNED
        if result == FAILED:
            failed.append(name)

    if failed:
        print("patch_mobilegl: failed steps: " + ", ".join(failed), file=sys.stderr)
        return 1
    print("patch_mobilegl: done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
