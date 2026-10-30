# Native SDL3 migration

## Approved scope

Replace the Java SDL3-to-GLFW shim on `codex-review` with native SDL3, retaining
its public API and Amethyst's controls. The user subsequently approved importing
the renderer upgrades from the reference release. Other UI, control layouts,
instance/mod management and additional review sections remain outside this work.

## Reference and dependencies

Adapted from Taylen-chud/Amethyst-iOS tag `1.2.0`, commit
`6542ff276e93011e4b8f2ce8e46777eb3c6415db`:
https://github.com/Taylen-chud/Amethyst-iOS/tree/1.2.0

- Native SDL3 and LWJGL 3.4.1 bindings/natives come from that release.
- MobileGL: `08124c99f12ab2283cc15e4dc64ea972ecbd49c1`.
- MobileGlues: `fcdf91456c1b3b5e77e5264cffe682595c13113f`.
- MoltenVK, Mesa/GLAPI, ANGLE and SPIRV-Cross binaries come from the same release.
- MobileGL patches and MobileGlues overrides are retained as reproducible build
  inputs. The former MobileGlues patches targeted its superseded source layout.

The Linux build now defaults to
`~/ios-toolchain/sdks-modern/iPhoneOS26.2.sdk`. Set `SDKPATH` to another modern SDK
with C++23 libc++ headers if needed. MobileGL targets iOS 17; the launcher retains
its iOS 14 deployment target. The other renderers remain selectable.

## Integration

SDL games and lwjgl3ify use a matched LWJGL 3.4.1 bundle. Other launches retain
LWJGL 3.3.3. Their jars and native libraries are selected together; the bundles
are not placed on the same classpath. The existing custom-system-classloader
launch path is retained.

SDL owns the real windows, properties, events, surfaces and gamepad API. Its
UIKit render view is embedded behind Amethyst's existing controls. UIKit input
is forwarded into SDL events directly; it does not travel through Java GLFW
callbacks. Synthetic keyboard/mouse polling state and text-input gating are
maintained because SDL_PushEvent does not update device state. Injected text
remains allocated until delivery and the following pump, or an explicit flush.

UIKit initialization, window changes and event pumping run on the UIKit thread.
Waiting for events stays on the calling Java thread so UIKit remains responsive.
The Java event-thread identity is retained for lwjgl3ify compatibility. EGL
contexts for MobileGL/MobileGlues use their renderer exports and SDL's Metal
layer, including shared contexts, resolution changes and the existing Angelica
wide-line hook. Other renderer choices follow SDL's native GL path.

`JavaApp/tools/PatchSDLABI.java` adds legacy shim signatures to the merged SDL
runtime at build time. Some old message-box accessors return raw pointers where
LWJGL returns typed buffers; JVM descriptors allow both versions to coexist.
Upstream jars remain unmodified. Normal shutdown is retained; the reference's
forced-exit watchdog and private Controlify SDL copy are not imported. Existing
controller passthrough preferences remain authoritative.

## Validation before device testing

- Both Java bundles compile with JDK 8.
- JVM verification passes for all 522 SDL classes without native initialization.
- Compared all 5,059 public fields/methods of the original shim at `7290b2b`:
  none are missing, including legacy return descriptors.
- All 1,045 common/iPad SDL function lookups have native exports. Two Windows-only
  registration names are not iPad APIs.
- Native launcher, upgraded MobileGlues and MobileGL compile/link for iOS arm64.
- Full packaging and USB delivery are recorded separately after completion.

These checks do not establish runtime equivalence or renderer correctness.

## iPad checks

Install the fresh IPA through LiveContainer's picker. Test the existing
lwjgl3ify/GTNH instance and a Minecraft version using native SDL, then an older
GLFW version as a regression check. Verify launch, world rendering, keyboard/chat,
touch camera, cursor and clicks, scrolling, controller mapping/passthrough, window
recreation, shared loading contexts, rotation, resolution scaling, background and
foreground transitions, and normal exit. Exercise Vulkan and OpenGL separately;
select MobileGL explicitly to test the newly added renderer.

## First GTNH device test: failed

The user tested `6dd8777`. Logs confirm MobileGlues was selected and LWJGL 3.4.1
was loaded. Its RFB event thread asked SDL for a context before LWJGL initialized
its GL function provider. The reference bridge treated that missing provider as
an EGL failure, permanently disabled itself, and fell back to native iOS GLES.
Desktop GL 4.0/4.1/3.3 context requests failed. A subsequent native SDL context
creation on a Java worker thread raised a UIKit main-thread assertion and aborted.

The follow-up loads the selected renderer independently when LWJGL's provider is
not initialized. It keeps renderer selection stable after an EGL failure, so
failed desktop-context requests cannot silently switch to the iOS GLES driver.
Native SDL context creation/destruction is dispatched to UIKit's thread.
A fresh device test is required; the first build is not a runtime success.

## MobileGL device test: launches, incorrect image extent

The user reports GTNH launches and runs with MobileGL in `4c279ef`. The log confirms
Angelica selected OpenGL (LWJGL3), with MobileGL/Magma OpenGL 4.6 and its Direct
Vulkan backend on the Apple M3 GPU. Angelica's separate SDL GPU backend was not
initialized. Thus this was OpenGL translated by MobileGL into Vulkan, then Metal
through MoltenVK; it was not a test of Angelica's native Vulkan backend.

The latest iPad screenshot shows the game occupying a strip along the bottom.
The log records a requested 1416x984 surface at 60% resolution, but a 2360x1640
MoltenVK swapchain with layer contentsScale 2.0. The bridge had skipped the
MobileGL contents-scale update, set drawableSize asynchronously, and allowed
SDL's next layout to restore the full-size drawable. The follow-up applies both
contentsScale and drawableSize synchronously before creating the EGL surface,
keeps UIView's contentScaleFactor aligned, and completes embedding layout first.

The same log records a StackOverflowError during GL function lookup. The follow-up
always resolves GL functions from the selected renderer directly; it no longer
asks LWJGL for a provider that may call back into SDL_GL_GetProcAddress.
Both changes still require a fresh iPad test for full-screen rendering.

### GTNH missing text after screen-size correction

Device test of `7294090` reaches a full-screen GTNH menu, but screenshot
`IMG_0107.PNG` has no text. Logs confirm the swapchain is now 1416×984 at
contents scale 1.2. MoltenVK reports Metal compilation errors because a texture
named `sampler` hides Metal's sampler type, including inside `txSample`.

The reproducible MobileGL patch removes only exact `sampler` OpName debug
instructions from final iOS Vulkan modules immediately before module creation.
GL reflection and binding lookup have already completed; resource IDs, bindings
and executable instructions stay intact. A reproduction with a global texture
and function parameter passes spirv-val before and after the patch, verifies
that only the two conflicting names change, and checks idempotence. Device text
rendering remains unverified until the corrected IPA is installed and tested.

### Remaining font failure on bb40671

Latest device logs confirm bb40671 was installed. The original Metal sampler
name collision is absent, but MoltenVK now reports `SPIR-V to MSL conversion
error: nullptr`; text remains missing. The deletion patch was insufficient.

Follow-up preserves every instruction's size and position, renaming the exact
OpName string from `sampler` to `ame_tex` instead of removing the instruction.
The actual fontFilter.fsh from the local Angelica 2.1.16 JAR validates as SPIR-V
and converts to argument-buffer MSL on the host. Both the earlier deletion and
the rename convert on the host, so this does not reproduce or explain the new
device error. The revised patch logs rename counts and captures at most two
affected modules of at most 16,384 words each in the application log for exact
replay if the iPad failure persists. The capture is bounded and contains shader
code, not launch arguments. The new build requires device testing; do not claim
that missing text is fixed.

### Exact shader replay after ee51cbd

Device logs confirm ee51cbd and one renamed name in a 3,018-word module directly
before the same MoltenVK `nullptr` conversion error. Both captured modules were
recovered successfully. The exact device shader passes Vulkan 1.1 validation and
converts with the bundled MobileGL SPIRV-Cross and newer upstream SPIRV-Cross.
Host probes with iOS argument buffers, descriptor padding, discarded-fragment
store checks and recursive-input handling also convert successfully. This has
not reproduced the device-only failure and does not establish a rendering fix.

A temporary native diagnostic rebinds only MoltenVK's __cxa_throw import and logs
at most four exception backtraces with image names and relative offsets, then
forwards the exception unchanged to the original runtime. It does not change
renderer selection or shader translation. The next device test is needed to
locate the failing conversion path. Remove temporary tracing after diagnosis.

### MoltenVK exception localized on 507bf06

The correct diagnostic IPA ran and installed the MoltenVK-only throw trace.
Every captured conversion exception has the same path. Symbolizing the shipped
MoltenVK binary identifies `CompilerMSL::analyze_argument_buffers()`'s alias
fixup callback, followed by `Variant::get<SPIRVariable>()` throwing `nullptr`,
while `CompilerGLSL::emit_function()` emits the entry point. Disassembly confirms
the callback calls `emit_argument_buffer_aliased_descriptor`.

The supported workaround defaults `MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0`
only for MobileGL launches, before the renderer is loaded, and logs the selected
mode. Explicit user environment overrides remain honored. MobileGL still uses
Vulkan through MoltenVK; this selects discrete Metal descriptor bindings and
avoids the failing argument-buffer conversion path. Other renderers retain
their existing configuration. The exact captured font shader validates and
converts to iOS MSL with discrete resource bindings. This trades argument-buffer
optimizations for compatibility; frame-rate impact is unmeasured. Device text
rendering still needs confirmation. Temporary diagnostics remain for this retest.

### Remaining text and GUI artifacts after discrete bindings

The user reports missing text plus corrupted GUI elements. IMG_0110.PNG shows
white blocks in text positions while the background and some icons draw. Fresh
GTNH logs confirm 0b08910, argument buffers set to 0, and no prior SPIR-V-to-MSL
conversion exception. An earlier collection contained subsequent Minecraft
1.12.2 sessions; do not use those to diagnose this GTNH screenshot. The remaining
rendering failure is unresolved.

MobileGL's logger compiles console output off, file output on, but the non-Android
default file path is empty. Consequently its existing texture/sampler warnings
were unavailable. The follow-up provides Documents/mobilegl-latest.log as the
default MOBILEGL_LOG_FILE_PATH only on MobileGL launches and adds that file to
the USB log collector. Custom environment overrides are preserved. This enables
existing diagnostic output; it is not a visual fix. A fresh GTNH launch is needed
to capture renderer warnings before choosing a texture or vertex-data change.

### MobileGlues control result and iPad draw capture

The user confirms GTNH text and GUI render correctly with MobileGlues in the
same native-SDL build. Remaining visible corruption is specific to the MobileGL
path; this does not establish complete SDL equivalence for other games.

The bd46b08 renderer log confirms missing standalone-stencil support and an
unbound lightmap sampler, but neither warning establishes the cause of text and
GUI corruption. A host-only reproduction was prepared from Angelica 2.2.28's
actual font shaders, interleaved 36-byte vertices, alpha atlas, texture rebinding
and ordinary/persistent buffer updates. The Vulkan harness could not initialize
because the host driver lacks VK_EXT_headless_surface. No pixel assertions ran;
there is no host rendering pass or failure to infer from that attempt. Host-only
compiler/configuration workarounds remain in /tmp, outside the repository.

The follow-up adds a temporary iOS-only passive capture before sampler fallback.
At most 32 distinct program/binding/texture combinations log requested texture
identity, format, size, swizzle, completeness, filter and CPU alpha range (only
small complete RGBA8 textures), plus bounded UBO and vertex bytes. It issues no
GL calls and does not change bindings or request GPU readback. It uses the
existing MobileGL log collector. The renderer source passes an iOS syntax check;
new iPad evidence is required to distinguish corrupt input state from downstream
MoltenVK rendering. This is diagnostic, not a claimed visual fix.

### Atlas binding omission confirmed by 0242f65 capture

The device capture records font program 7's lightmap at binding 1 but never its
font atlas at binding 2. Its CPU vertex bytes contain plausible positions and UVs.
Tracing the call order reveals an integration bug in our Metal-name workaround:
ProgramFactory creates shader modules and only then calls ReflectLayout on the
same moduleSpirvs. Renaming sampler in place makes that later reflection look up
ame_tex in the frontend's original GL uniform-name table. It finds no location
and silently drops the sampler binding. Previous notes claiming the rename was
after all descriptor reflection were incorrect.

Fix: rename only a separate driverModuleSpv copy supplied to vkCreateShaderModule;
leave moduleSpirvs unchanged for the subsequent input/output/layout reflection.
A CPU regression using the exact captured font module and SPIRV-Reflect reproduces
the old renamed descriptor and verifies that the copy preserves the original
sampler descriptor while the driver sees ame_tex. Every executable instruction
and descriptor decoration stays unchanged. Clean-upstream patch application and
idempotent reapplication both pass. No host GPU result is used for this fix.

A layout missing a sampler still declared by its shader is invalid Vulkan input.
Thus the prior argument-buffer alias exception occurred with an invalid layout
and does not establish an independent MoltenVK driver bug. Restore normal Metal
argument buffers (default 1, preserving explicit user overrides) with the corrected
layout instead of retaining the disabling workaround. Earlier statements attributing
that exception solely to a driver defect were premature. Keep bounded diagnostics
for the iPad retest. Full text/GUI recovery and argument-buffer behavior still
require device confirmation.

### SDL GPU Metal window claim crash

The user confirms afd3cbf renders GTNH correctly with MobileGL, including text
and GUI. Enabling -Dangelica.sdlgpu.enable=true then crashes. Device logs confirm
SDL 3.4.12 creates a Metal GPU device on Apple M3 before UIKit throws
NSInternalInconsistencyException: Call must be made on main thread. The crash
stack reaches UIWindow setRootViewController from SDL's Metal window path on
the RFB event-loop thread. This is separate from MobileGL/MoltenVK rendering.

The follow-up delegates SDL's SharedLibrary handle/name/path/lifetime unchanged
and substitutes function pointers only for SDL GPU window claim/release and
device destruction. These operations run through the existing synchronous UIKit
bridge; successful claims re-embed the new SDL Metal view. GPU rendering and
command submission remain on the caller thread. Java build and verification of
524 SDL classes pass; focused iOS static analysis passes. SDL GPU gameplay and
any subsequent shader/backend limitations still need device testing.
