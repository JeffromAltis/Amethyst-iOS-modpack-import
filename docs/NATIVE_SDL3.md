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

### SDL GPU splash: black loading screen and brief magenta transition

User testing of 7e328b9 reaches the main menu successfully with
-Dangelica.sdlgpu.enable=true, but the loading screen is black and briefly
magenta before the menu. Logs confirm successful native Metal window claim and
backend initialization, followed by `prepareIndexedDraw: frame not active; draw
skipped` on the Client thread. The splash target's larger desktop-sized allocation
is intentional in Angelica and does not by itself establish a scaling defect.

The launcher previously forced BetterLoadingScreen threadedRendering=false for
all iOS launches to avoid shared-OpenGL-context failures. The installed Angelica
2.2.28 backend starts its offscreen splash frame for SDL-managed contexts on a
secondary rendering thread, not the GLStateManager main thread. This makes the
forced nonthreaded setting a specific compatibility problem for this backend.

Follow-up applies required mod settings after final JVM arguments are assembled.
It resolves the SDL GPU enable property with JVM last-value-wins semantics and
enables BetterLoadingScreen threaded rendering only when that property is true
and both Angelica and lwjgl3ify are installed. OpenGL retains the existing iOS
setting; other mod settings are unchanged. Both edited native files pass iOS
syntax checks. This targets the splash failure; black/magenta recovery still
requires the iPad retest. No unrelated mod updates or renderer changes are added.

### Home indicator remains visible with hiding enabled

IMG_0112.PNG shows the home indicator on GTNH's main menu with build 81decbc.
The user confirms Hide home indicator is enabled. The gameplay controller still
returned bottom-edge gesture deferral regardless of that preference, contrary to
the setting's documented behavior. Exclude the bottom edge when hiding is enabled,
while retaining right-edge deferral. Refresh both UIKit preferences in
viewDidAppear, including after returning from settings. Both edited native files
pass iOS 14-targeted syntax checks. Device confirmation remains pending.

### Home indicator follow-up: SDL window handoff

The user reports 57d8802 did not fix the issue: the indicator disappears during
launch, then returns when the game window appears. IMG_0113.PNG records recurrence.
Embedding hides SDL's secondary window without explicitly restoring gameplay
window UI preferences. Refresh home indicator, gesture and status preferences
after embedding and on repeated attachment; restore the host as key only when
no other window is key, preserving alert/keyboard focus. iOS syntax check passes.
This targets the handoff path; device success is not yet confirmed.

The user subsequently installed 0b858a7 and confirmed the home-indicator fix
works. This verifies the reported handoff symptom on their GTNH setup.

### Controller binding inventory — 2026-10-30

Read installed mod filenames from the active iPad guest and copied the following
JARs read-only for bytecode inspection. Device originals were unchanged.

| Installed mod | Controller binding | Direct use of our LWJGL SDL3 controller bindings |
| --- | --- | --- |
| controlify-3.0.1+lts+1.21.11-fabric.jar | JNA, via embedded libsdl4j-3.2.18.release-3.2.18-79.jar | No |
| controlify-3.5.3+mc26.3-universal.jar | dev.isxander.sdl API with embedded sdl-backend-ffm-release-3.4.14-7.jar | No implemented LWJGL loader |

Inspection used class constant references, nested JAR service registrations and
`javap -c -p` on each SDLNativesLoader. In 3.5.3, loadFromLwjgl returns
Optional.empty unconditionally. Its LWJGL SDL references are in cursor/input
utility code, not its controller manager. The embedded SdlLoader provider is
dev.isxander.sdl.ffm.SdlFfmLoader. Do not describe this version as using JNA.

The installed controller-mod inventory found Controlify, with no Controllable or
MidnightControls JARs. lwjgl3ify is also installed in GTNH but is not itself a
controller mod. No installed mod offers a direct LWJGL SDL controller backend to
test unchanged. No controller routing or forced-fallback settings were changed.
Native SDL gamepad runtime behavior remains unverified. Replacing the bridge
requires a binding integration: for 26.3, implement an SDL API backend backed by
the existing LWJGL bindings and connect its loader; assess the older JNA API
separately. Do not remove the working GLFW fallback before native device testing.

### Existing binding compatibility investigation

The user authorized investigating the existing JNA/FFM backends with bundled
SDL3 before considering a replacement backend. Changes outside that scope need
the user's approval. Controller routing and fallback settings remain unchanged.

Controlify 26.3's FFM loader supports an explicit Path through SdlFfmLoader.create
and the `dev.isxander.sdl.library` property for its system-loading path. That path
uses SymbolLookup.libraryLookup, so a new LWJGL backend is not a prerequisite for
testing FFM compatibility. Native linker/downcall/upcall support on the iPad is
still unverified; the presence of Java runtime classes does not establish support.

`scripts/diagnostics/SDLBindingProbe.java` is a standalone Java-8-bytecode probe
intended to run on Java 25. Package its class with the installed mod's unchanged
sdl-api and sdl-backend-ffm JARs as root resources `sdl-api.jar` and `sdl-ffm.jar`,
and set Main-Class to SDLBindingProbe. No third-party JARs were added to Git.
It locates the bundled dylib, creates the native linker and the existing FFM
backend, then calls SDL_GetVersion. It does not initialize SDL, install callbacks,
or open controllers. It writes `sdl-binding-probe.log` under Java user.home.

The probe passed on the Linux host's Java 25 / SDL 3.4.18; this validates the probe
and packaging, not iPad compatibility. SDLBindingProbe.jar was copied to
LiveContainer Documents for a device run with the Execute JAR runtime set to
Java 25. Device result pending. JNA direct registration remains a separate pending
check; simply pointing its loader at a dylib does not establish safe invocation.

Device probe result: after an initial Java 8 run stopped with the expected
ClassNotFoundException for java.lang.foreign.Linker, the user selected Java 25
and reran. The iPad's Java 25.0.4-internal created the native FFM linker, loaded
the unchanged Controlify 26.3 FFM backend against the installed bundled SDL3,
and returned 3004012 (SDL 3.4.12) from SDL_GetVersion. Native loading and this
downcall are device-confirmed. This does not validate upcalls/callbacks, SDL
subsystem initialization, threading, controller input or the older JNA backend.

Next standalone test: SDLCallbackProbe.jar uses the same probe class and embedded
FFM/API JARs with an empty root resource `probe-callbacks` enabling the additional
stage. It creates a temporary SDL properties group, sets one string property,
enumerates it through the unchanged backend's native-to-Java callback, asserts
exactly one matching callback, and destroys the group in finally. It does not
initialize SDL subsystems or open controllers. The test passed on Linux Java 25;
device callback support remains pending. Both probes write the same report path.

Device callback result: the user ran SDLCallbackProbe.jar on Java 25.0.4-internal.
The report confirms SDL 3.4.12 loading/downcalls and exactly one successful
native-to-Java callback through the unchanged FFM backend. This validates the
synchronous property-enumeration callback on this iPad. SDL subsystem/controller
initialization, callbacks from other threads, input and the older JNA backend
remain untested.

Controller-discovery probe prepared: package the same probe with the root marker
`probe-controllers` and Java-25-compiled SDLProbeMainThread.class. The helper uses
FFM libdispatch dispatch_sync_f and the _dispatch_main_q global on iPadOS to run
the unchanged backend's subsystem initialization, enumeration and open/close calls
on UIKit's main thread. SDL_SetMainReady runs there first. The Java caller waits
two seconds between initialization and enumeration to let UIKit discovery run.
Every opened gamepad is closed, and successful initialization is balanced with
SDL_QuitSubSystem for the probe's gamepad reference, rather than global SDL_Quit.
The probe does not read buttons, move the cursor, rumble, or change routing.
Linux initialization/zero-device discovery/cleanup passed; the UIKit dispatch
and physical controller paths require the iPad test. Source is under
scripts/diagnostics; no production app changes are required for this probe.

Device discovery result: on Java 25.0.4-internal / bundled SDL 3.4.12, the
unchanged Controlify FFM backend initialized the gamepad subsystem through the
UIKit main-thread probe, discovered one DUALSHOCK 4 Wireless Controller, opened
and closed it, then released the probe's subsystem reference successfully.
Buttons, axes, rumble, reconnect behavior and actual Controlify integration
remain untested; the older JNA backend is also still unverified.

Next test: SDLInputProbe.jar enables `probe-controllers` and `probe-input`.
It retains discovered gamepad handles for 20 seconds, samples buttons 0-14 and
six axes through the unchanged FFM backend every 50 ms on the UIKit main thread,
and reports changes plus the observed-control summary. The Java worker waits
between samples so UIKit remains responsive. Every retained handle and the
probe's subsystem reference are released in finally. No rumble or normal-game
routing changes are made. Compilation and Linux zero-device/skip/cleanup passed;
the physical input path remains pending the iPad run.

Device input result: SDLInputProbe on Java 25.0.4-internal / SDL 3.4.12 observed
the DualShock 4's four face buttons, Share, Options, both stick clicks, L1/R1,
all four D-pad directions, both X/Y stick pairs and both L2/R2 axes through the
unchanged FFM backend. The log contains 95 button-change records and 267
axis-change records, then successful cleanup. Guide/PS was not observed.
This confirms the sampled input path, not axis calibration/deadzones, rumble,
hotplug/reconnect, sustained gameplay or Controlify integration. JNA remains
untested. No production controller routing has changed.

Next standalone test: SDLRumbleReconnectProbe.jar enables `probe-controllers`
and `probe-hotplug`. Through the unchanged FFM backend it requests a single
300 ms rumble at 25% strength, then polls controller IDs for 30 seconds, closing
removed devices and opening newly discovered devices on UIKit's main thread.
Rumble's boolean response does not establish physical vibration; the user must
confirm it. Removal/reopening does not establish post-reconnect input. Handles
and the probe's subsystem reference are released afterward. Linux compilation,
zero-device skip and cleanup passed. Device rumble/reconnect results pending.

Device rumble/hotplug result: on Java 25.0.4-internal / SDL 3.4.12 the DualShock 4
accepted the rumble request, and the user confirmed feeling it. The probe saw
controller ID 1 disconnect, but no controller reappeared within the 30-second
window. Cleanup completed. Rumble and removal detection are confirmed; reconnect
is not. Whether physical reconnection completed during the window is not yet
known, so this result alone does not establish a backend reconnect defect.

Reconnect retest: user believes reconnection occurred within 30 seconds. The
first hotplug probe did not pump SDL events. Corrected SDLReconnectProbe-v2.jar
calls SDL_PumpEvents on UIKit's main thread before device enumeration, extends
the window to 60 seconds, logs elapsed times for transitions, and disables the
already-confirmed rumble request via `probe-no-rumble`. SDL documents PumpEvents
as updating the queue and internal input-device state. The earlier negative
result cannot distinguish a probe deficiency from actual reconnect behavior.
Compilation and Linux no-device skip/cleanup pass; iPad retest pending.

Device reconnect-v2 result: the user completed the disconnect/reconnect test.
On Java 25.0.4-internal / SDL 3.4.12, the probe observed DualShock 4 id=1 at
startup, removal at 12 seconds, then a DualShock 4 id=2 at 21 seconds. It opened
the new device and completed cleanup. Native rediscovery and reopening are
confirmed with event pumping. Post-reconnect input and actual Controlify game
integration remain untested. The earlier no-reconnect result was from an
incomplete probe, not sufficient evidence of a backend defect.

Older binding probe: copied the installed shared game_data/libraries JNA 5.17.0
JAR read-only and packaged it unchanged with Controlify 1.21.11's embedded
libsdl4j-3.2.18.release-3.2.18-79.jar in SDLJNAProbe.jar. Source is
scripts/diagnostics/SDLJNAProbe.java, with SDLBindingProbe for dylib discovery.
The probe logs JNA initialization, explicit SDL loading, original SdlVersion
direct registration, and SDL_GetVersion separately to sdl-jna-probe.log under
user.home. It does not initialize SDL subsystems or controllers. Linux Java 21
loading/registration/version call passed. The original JNA darwin-aarch64 native
dispatch library identifies as macOS in its Mach-O build command; whether the
launcher's existing loading environment accepts it must be tested on-device,
not inferred from the Linux pass. Device run intended on Java 21, matching the
older instance; normal controller behavior remains unchanged.

First iPad JNA result: report identifies Java 25.0.4-internal, not the requested
Java 21. JNA initialization, explicit SDL3 loading and original SdlVersion direct
registration all completed. The last flushed stage is "Direct registration
completed; calling SDL_GetVersion", with no return, FAIL record or relevant JVM
fatal error in the inspected launch log. This is not a pass and does not prove
a crash; whether the app hung or terminated requires user confirmation. Java 21
behavior is still untested. The equivalent FFM version call previously passed.

Java 21 retest: report now identifies Java 21.0.8-internal and again completes
JNA initialization, SDL3 loading and direct registration, then ends immediately
before SDL_GetVersion returns. No PASS/FAIL was recorded. The same incomplete
native-call result is therefore observed on both Java 21 and Java 25; process
hang versus termination is not yet confirmed. This rules out the initial wrong
runtime selection as the sole explanation, but does not establish the root cause.

User reports no app freezing or closing. The Java 21 launch log still ends at
the original direct SDL_GetVersion call, without a JVM error or completion.
Prepared SDLJNAProbe-v2.jar: first call the same SDL function through JNA's
ordinary Function.invokeInt API, then attempt unchanged direct registration and
call. A daemon watchdog records the caller state/Java stack after five seconds
if the calls have not completed; it does not interrupt or alter the native call.
This distinguishes SDL loading/invocation from direct-mapping behavior without
changing controller bindings. Both paths pass on Linux Java 21. Device result
pending; normal controller routing remains unchanged.

JNA-v2 device result on Java 21.0.8-internal: ordinary JNA Function.invokeInt
returned 3004012 successfully from the same bundled SDL3. Original libsdl4j
direct registration completed, but the subsequent direct SDL_GetVersion call
did not return within five seconds. The watchdog ran successfully and recorded
the caller RUNNABLE inside SdlVersion.SDL_GetVersion(Native Method), reached via
DirectMethodHandleAccessor$NativeAccessor. The app remained responsive according
to the user. This localizes the observed stall to direct native mapping/call
execution, rather than basic SDL library availability or all JNA invocation.
It does not establish the underlying libffi/JVM/TXM cause. Existing older
libsdl4j bindings are not validated as usable unchanged. Switching their native
methods to interface/dynamic calls or another backend is a binding change,
beyond the current compatibility investigation, and needs user approval.
Normal controller routing and forced fallback remain unchanged.

### Authorized integration: Controlify 26.3 FFM first

The user authorized integrating the existing FFM backend for 26.3 while keeping
the older fallback temporarily. The new independent agent transformer recognizes
SDLNativesLoader's static load():dev.isxander.sdl.Sdl and matching startSdl(Sdl).
It uses Fabric's existing public ASM through the defining class loader because
Java 25 no longer ships the internal ASM used by the older compatibility patch.
The older JNA loader does not match and its existing fallback/compatibility code
and forced invalid SDL override remain unchanged.

ControlifySDL creates the mod's unchanged SdlFfmLoader with the bundled dylib's
explicit path, wraps public subsystem interfaces to synchronously dispatch
calls through a JNI UIKit bridge, then invokes Controlify's original startSdl.
Values, handles and callback objects are not replaced. Startup initialization
references are tracked and balanced if startup fails. Native controller ownership
detaches Amethyst's mapping/GLFW handlers before SDL initializes, suppresses
Amethyst controller tick/connect/disconnect handling while SDL owns input, and
restores the previous handlers if startup fails. Existing touch, keyboard, mouse,
renderers, profile preferences and the older controller path are unchanged.

Validation: Java build and iOS syntax checks pass. Exact installed old/new loader
JAR tests confirm the old class is untouched and the modern replacement passes
ASM bytecode dataflow verification. A host JNI stub test runs the production
Java forwarding layer against the unchanged FFM backend; startup, forwarding and
cleanup after an injected startup failure pass. The stub does not validate UIKit
or GameController ownership. The full IPA/device Controlify test is pending.
Expected device log markers are [ControlifySDL] Patched FFM loader and
[ControlifySDL] Existing FFM backend initialized with bundled SDL3 on UIKit thread.

Delivery: code commit 8199d3e compiled and packaged in workflow 41119572271.
Runner log explicitly confirms the USB copy as Amethyst-latest.ipa at
2026-10-30T20:00:07Z. Artifact upload was still running when copy was confirmed.
Installation and actual Fabric 26.3 / Controlify 3.5.3 gameplay remain pending.

First reported crash after delivery: diagnostics/ipad/20261030-200318-456916
identifies running build 0b858a7, without the new ControlifySDL markers. The
native stack is in libshaderc/glslang shader compilation. Read-only device binary
inspection confirms installed org.angelauramc.amethyst.app still contains
0b858a7, while LiveContainer's Amethyst-latest.ipa contains 8199d3e and the new
integration. Thus this is not yet a runtime test of 8199d3e. Install the delivered
IPA before attributing a crash to the FFM integration; shader-renderer changes
are outside the current controller scope.

Correct-build crash retest: diagnostics/ipad/20261030-200604-655854 confirms
8199d3e. Minecraft selects its native Vulkan backend on MoltenVK/Apple M3, creates
the SDL window, then crashes in libshaderc's glslang::TParseContext::lValueErrorCheck
during resource/shader initialization. No ControlifySDL loader-patch or backend
initialization marker is present before termination. The same native shader
compiler stack was observed on the prior 0b858a7 test. FFM gameplay is blocked
before the integration's initialization is observed, not verified as failed in
its own call path. The user required asking before work outside controller scope;
shader compiler/renderer diagnosis needs approval before changes.

The user authorized investigating the shader crash. Binary inspection found
MobileGlues exports 2,577 glslang symbols and shares 750 glslang exports with
shaderc, including weak TIntermediate::addSwizzle implementations. The failing
shaderc instruction dereferences a pointer while walking a swizzle-related AST
path in lValueErrorCheck. This supports, but does not yet prove, cross-library
compiler symbol coalescing between incompatible embedded glslang versions.

Narrow linker change: the Apple MobileGlues override applies
mobileglues_private_symbols.txt to make glslang/TInterm implementation symbols
private. iOS relinking passes. Export comparison against the previous built
MobileGlues confirms 2,601 matching compiler symbols removed, zero glslang exports
remaining, no unrelated export removals and no lost graphics API exports. No
shader translation or controller logic changes are part of this follow-up.
The iPad retest is necessary to establish whether this addresses the crash.

5062ddb device retest: diagnostics/ipad/20261030-201857-598873 shows Minecraft
passes the prior shader compilation failure, patches the modern loader,
initializes Controlify's unchanged FFM backend and identifies the DualShock 4.
It then throws WrongThreadException in SdlFfmGamepad.SDL_GetGamepadSensorData:
the original proxy dispatches a render-thread-confined FloatBuffer to UIKit.

Correction: gamepad/joystick API calls with java.nio.Buffer arguments remain on
their caller's thread. SDL_GetGamepadSensorData is documented thread-safe.
Initialization, event pumping and other calls retain UIKit dispatch. The older
fallback is unchanged. Java compilation and a regression with a genuine confined
FFM arena/FloatBuffer pass; the test verifies output is written without invoking
the UIKit bridge (scripts/diagnostics/VerifyControlifyBuffers.java). Device test
is pending. This was an integration bug, not a failure of the standalone FFM
loading/input probes; those did not exercise Controlify's sensor-buffer lifetime.

Latest device confirmation: after delivery of sensor-buffer fix 095613b, the
user reports that it now works with Minecraft 26.3. Native FFM integration is
therefore confirmed working for the user's reported 26.3 setup. The older
Controlify/JNA GLFW fallback remains retained as agreed. Standalone rumble and
reconnect tests passed earlier; do not infer exhaustive in-game rumble, sensors,
post-reconnect input, long-session stability or other-controller validation from
this general success report. No additional older-binding migration is approved.
