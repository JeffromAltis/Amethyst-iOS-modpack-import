#pragma once
#include <algorithm>
#include <atomic>
#include <mutex>
#include <set>
#include <string>
#include <tuple>

namespace MobileGL::MG_Backend::DirectVulkan {
inline String AmethystDrawHex(const void* data, SizeT size) {
    static constexpr char digits[] = "0123456789abcdef";
    String out;
    if (!data) return out;
    out.reserve(size * 2);
    const auto* bytes = static_cast<const Uint8*>(data);
    for (SizeT i = 0; i < size; ++i) {
        out.push_back(digits[bytes[i] >> 4]);
        out.push_back(digits[bytes[i] & 15]);
    }
    return out;
}

// Temporary passive capture: no GL calls, no binding changes, no GPU readback.
// Read only authoritative CPU data already used by the descriptor resolver.
inline void AmethystTraceDrawInputs(const MG_State::GLState::ProgramObject& program,
    Uint32 binding, const char* name, Int unit,
    MG_State::GLState::ITextureObject* texture,
    const MG_State::GLState::SamplerObject* sampler) {
    static std::atomic<unsigned> count{0};
    if (count.load(std::memory_order_relaxed) >= 32) return;
    static std::mutex mutex;
    static std::set<std::tuple<Uint64, Uint32, Uint64>> seen;
    const std::lock_guard<std::mutex> guard(mutex);
    if (count.load(std::memory_order_relaxed) >= 32) return;
    if (!seen.emplace(program.GetLifetimeId(), binding, texture ? texture->GetLifetimeId() : 0).second) return;
    ++count;
    const Bool incomplete = texture && MG_State::GLState::SamplesAsIncompleteTexture(texture, sampler);
    MGLOG_I("[Amethyst draw] program=%u sampler=%s binding=%u unit=%d texture=%u format=%d incomplete=%d minFilter=%d",
        program.GetExternalIndex(), name, binding, unit, texture ? texture->GetExternalIndex() : 0,
        texture ? static_cast<Int>(texture->GetFormat()) : -1, incomplete,
        sampler ? static_cast<Int>(sampler->GetMinFilter()) : -1);
    if (texture) {
        const auto size = texture->GetBaseSize();
        const auto swizzle = texture->GetAllSwizzleParams();
        MGLOG_I("[Amethyst texture] size=%dx%dx%d swizzle=%d,%d,%d,%d content=%llu",
            size.x(), size.y(), size.z(), static_cast<Int>(swizzle.x()), static_cast<Int>(swizzle.y()),
            static_cast<Int>(swizzle.z()), static_cast<Int>(swizzle.w()),
            static_cast<unsigned long long>(texture->GetContentVersion()));
        if (!incomplete && texture->GetStorageType() == TextureStorageType::Mipmap &&
            texture->GetTarget() == TextureTarget::Texture2D &&
            (texture->GetFormat() == TextureInternalFormat::RGBA8 || texture->GetFormat() == TextureInternalFormat::SRGB8Alpha8)) {
            auto* mipmap = static_cast<MG_State::GLState::TextureObjectMipmap*>(texture);
            const Uint level = texture->GetLevelRange().x();
            const SizeT bytes = mipmap->GetMipmapByteSize(TextureUploadTarget::Texture2D, level);
            if (bytes > 0 && bytes <= 4 * 1024 * 1024) {
                const auto* pixels = static_cast<const Uint8*>(mipmap->MapMipmapData(TextureUploadTarget::Texture2D, level));
                if (pixels) {
                    unsigned low = 255, high = 0; SizeT transparent = 0, opaque = 0;
                    for (SizeT i = 3; i < bytes; i += 4) {
                        low = std::min(low, static_cast<unsigned>(pixels[i]));
                        high = std::max(high, static_cast<unsigned>(pixels[i]));
                        transparent += pixels[i] == 0; opaque += pixels[i] == 255;
                    }
                    MGLOG_I("[Amethyst alpha] bytes=%zu range=%u..%u zero=%zu full=%zu", bytes, low, high, transparent, opaque);
                }
            }
        }
    }
    const String ubo = AmethystDrawHex(program.GetUBOData(), std::min<SizeT>(program.GetUBOSize(), 256));
    MGLOG_I("[Amethyst uniforms] bytes=%u hex=%s", program.GetUBOSize(), ubo.c_str());
    const auto& vao = MG_State::pGLContext->GetBoundVertexArray();
    if (!vao) return;
    const auto& attributes = vao->GetAllAttributes();
    for (SizeT i = 0; i < std::min<SizeT>(attributes.size(), 4); ++i) {
        const auto& a = attributes[i];
        if (!a.Enabled) continue;
        String data;
        if (a.Buffer && a.Offset < a.Buffer->GetSize()) {
            const auto* base = a.Buffer->MappedData();
            if (base) data = AmethystDrawHex(base + a.Offset, std::min<SizeT>(64, a.Buffer->GetSize() - a.Offset));
        }
        MGLOG_I("[Amethyst vertex] vao=%u attr=%zu size=%d type=%d normalized=%d stride=%d offset=%zu buffer=%u persistent=%d hex=%s",
            vao->GetExternalIndex(), i, a.Size, static_cast<Int>(a.Type), a.Normalized, a.Stride, a.Offset,
            a.Buffer ? a.Buffer->GetExternalIndex() : 0, a.Buffer ? a.Buffer->IsBackendPersistentMapped() : false, data.c_str());
    }
}
}
