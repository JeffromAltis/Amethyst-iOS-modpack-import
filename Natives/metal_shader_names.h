#pragma once
#include <cstddef>
#include <cstring>

// Run only on the final Vulkan module, after GL reflection and binding lookup.
// Removing this debug name lets MoltenVK assign an identifier which cannot hide
// Metal's sampler type. Resource IDs, bindings and executable code stay intact.
template<class Words>
inline void AmethystMetalShaderNames(Words& words) {
    for (std::size_t offset = 5; offset < words.size();) {
        const std::size_t count = words[offset] >> 16;
        if (count == 0 || count > words.size() - offset) return;
        const unsigned opcode = words[offset] & 0xffff;
        if (opcode == 5 /* OpName */ && count == 4 &&
            std::memcmp(words.data() + offset + 2, "sampler", 8) == 0) {
            words.erase(words.begin() + offset, words.begin() + offset + count);
        } else {
            offset += count;
        }
    }
}
