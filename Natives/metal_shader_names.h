#pragma once
#include <atomic>
#include <cstddef>
#include <cstdio>
#include <cstring>

// Only final Vulkan modules are changed, after GL reflection and binding lookup.
// Preserve instruction lengths and IDs while avoiding Metal's sampler type name.
template<class Words>
inline void AmethystMetalShaderNames(Words& words) {
    std::size_t renamed = 0;
    for (std::size_t offset = 5; offset < words.size();) {
        const std::size_t count = words[offset] >> 16;
        if (count == 0 || count > words.size() - offset) return;
        const unsigned opcode = words[offset] & 0xffff;
        if (opcode == 5 /* OpName */ && count == 4 &&
            std::memcmp(words.data() + offset + 2, "sampler", 8) == 0) {
            std::memcpy(words.data() + offset + 2, "ame_tex", 8);
            ++renamed;
        }
        offset += count;
    }
    if (renamed) {
        std::fprintf(stderr, "[Amethyst Metal] renamed %zu sampler debug names; module words=%zu\n",
                     renamed, words.size());
        // Capture at most two small affected modules for an exact host replay if
        // MoltenVK still refuses them. Shader words contain no launch arguments.
        static std::atomic<unsigned> captured{0};
        if (words.size() <= 16384 && captured.fetch_add(1) < 2) {
            std::fprintf(stderr, "[Amethyst Metal SPIRV] ");
            for (auto word : words) std::fprintf(stderr, "%08x", static_cast<unsigned>(word));
            std::fprintf(stderr, "\n");
        }
    }
}
