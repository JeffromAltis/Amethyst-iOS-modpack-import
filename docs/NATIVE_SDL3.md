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
