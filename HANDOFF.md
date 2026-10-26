# Handoff: GTNH 2.9.0 Mobile on Amethyst iOS (branch `modpack-import`)

## Goal
Import and run the **GT New Horizons 2.9.0 Mobile `.mrpack`** (which uses lwjgl3ify 3.0.37, RetroFuturaBootstrap, LWJGL 3.4 with SDL3) on **Java 25** in Amethyst iOS. CurseForge import is deferred ("skip curseforge for now").

- **Repo:** fork `JeffromAltis/amethyst-ios-modpack-import`, local clone `/home/claude/amethyst-ios-modpack-import`, branch `modpack-import`. Everything is pushed; the working tree is clean apart from this file.
- **Testing loop:**
  1. Push to the branch.
  2. CI (`.github/workflows/build-fork.yml`, macos-26) produces the artifact `amethyst-ios-ipa`. Watch it with `gh run watch`.
  3. The user installs the IPA on an iPad Air 11" M3 (8 GB RAM, iPadOS 18.6.2) and sends back logs: `latestlog.txt`, `fml-client-latest.log`, `fml-junk-earlystartup.log`, `hs_err_*.log`.
- **Commit trailer:**
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_014tB9C3R4hT1rGRz9p3PVHR
  ```
- **PR descriptions** end with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.

## Commits so far (oldest → newest)
| Commit | What it does |
|---|---|
| c54bb42 | lwjgl3ify detection and launch profile install (`Natives/installer/modpack/LWJGL3ifyUtils.m`); Maven path derivation for libraries without a `path` (`MinecraftResourceUtils pathForLibraryName`, Java `Tools.mavenPath`); custom system class loader support (`-cp`, JVM args, `Class.forName` mainClass) |
| 3bee5a7 | SDL3 compatibility layer over the GLFW bridge: `JavaApp/src/lwjgl/org/lwjgl/sdl/`, about 66 files. The core is `SDLShim.java` plus `SDLKeys.java`; the rest are adapted generated structs and function classes |
| 8f3486d | CI builds this branch |
| aea1a5f | `-Djava.awt.headless=true` for RFB profiles; skip the Caciocavallo preload when headless |
| 6d84ae7 | `SDL_GL_MakeCurrent(NULL)` is a no-op before any context exists (fixed a SIGSEGV) |
| 5c26aa0 | Park and reuse the on-screen GL context when Angelica recreates the display (fixed EGL 0x3003) |
| c292ba3 | Create and make current native contexts only on the rendering thread; lazy GL library load |
| 1471321 | `Natives/sdl_gl_hooks.c`: `glGetFloatv(GL_ALIASED_LINE_WIDTH_RANGE)` reports max 8, so Angelica skips its geometry-shader wide lines (ES has no geometry shaders) |
| 508dc98 | `LWJGL3ifyUtils applyRequiredConfigToGameDirectory:` writes `B:threadedRendering=false` into `config/Betterloadingscreen/betterloadingscreen.cfg` and `B:stbiTextureLoading=false` into `config/lwjgl3ify.cfg` |

## What works on device
- The import succeeds, and the profile becomes `1.7.10-LWJGL3ify-3.0.37`.
- Java 25, RFB, Forge, coremods and mixins all load.
- The SDL layer initializes and the GL context is created.
- MobileGlues 1.3.3 runs on ANGLE Metal (GL 4.0 over ES 3.0).
- Angelica's line width probe is accepted, and the ResourceManager reload starts.

## CURRENT BLOCKER (build 508dc98, log at 02:37)
The game still crashes with this error from `alexiil.mods.load.MinecraftDisplayer.displayProgress` (`new SharedDrawable(...)`):
```
UnsupportedOperationException: Shared GL contexts are disabled (Config.OPENGL_SHARED_CONTEXT=false)
```

**Diagnosis (very likely; not yet verified):** BLS opens its config through a relative path:
```java
new File("./config/Betterloadingscreen/betterloadingscreen.cfg")
```
(`/home/claude/ref/bls/.../ProgressDisplayer.java:157`). Java hands relative paths straight to `open()`, so they resolve against the **process's native cwd**, not `-Duser.dir`.

`Natives/JavaLauncher.m` sets `-Duser.dir=<gameDir>` (line ~276) but never calls `chdir()`. So BLS reads a different (or uncreatable) file and falls back to its default `threadedRendering=true`. The config we write into the instance directory is correct but never read.

Android Amethyst calls `chdir(gameDirectory)` before launching (`JREUtils.java:415`).

**Fix to implement next:**
1. In `Natives/JavaLauncher.m` `launchJVM`, once `gameDir` is resolved (about line 207–213, before `JLI_Launch` at about line 452), call:
   ```objc
   [NSFileManager.defaultManager createDirectoryAtPath:gameDir withIntermediateDirectories:YES attributes:nil error:nil];
   chdir(gameDir.fileSystemRepresentation);
   ```
   Log any failure.
2. This should also fix any other mod that uses relative `config/...` paths.
3. Optional safety net: if cwd can't be fixed, also make `SDLShim` / lwjgl3ify accept shared contexts. That is the deferred task below, so don't do it unless needed.

## Expected issues after this
- Memory pressure during the mod load (allocation is about 4.8 GB on an 8 GB device). A silent app disappearance means jetsam killed it.
- A long load time; tell the user to wait at least 10 minutes.
- No stencil buffer, which affects ModularUI2 GT GUIs, the Navigator minimap, Botania, OpenBlocks and the CCC mod list.
- Clip planes (Galacticraft map, GT cutting machine) depend on ANGLE's `EXT_clip_cull_distance`.
- Wireframe is a no-op, and shader packs won't work.
- The GTNH exit-confirm Swing dialog may fail when quitting.

## Deferred to-dos (ONLY after the game fully works; the user said so explicitly)
1. **Shared GL contexts:** off-screen/pbuffer contexts sharing with the game view in `ctxbridges/gl_bridge.m`. Then re-enable BLS `threadedRendering` and lwjgl3ify `sharedContext`, and remove the forced setting in `LWJGL3ifyUtils RequiredSettings()`.
2. **Stencil buffer:** add `EGL_STENCIL_SIZE 8` in `gl_bridge.m` `gl_init_context`. If `eglChooseConfig` finds no config, fall back to the current attributes.

## Useful local material (may not survive a new container)
- **Reference sources in `/home/claude/ref/`:**
  - `amethyst-android`
  - `lwjgl3ify-src` (3.0.37)
  - `rfb-src`
  - `lwjgl3-341`, `lwjgl3-333`
  - `angelica` (at 2.2.28)
  - `mobileglues`
  - `bls`
  - `l3`: lwjgl3ify jar, `version.json`, `sdl_members.txt`
  - `gtnh-mods`: 212 of 241 mod jars
- **Tooling in `/tmp/claude-0/`:**
  - SDL generators: `sdlgen/` (`structs.py`, `consts.py`, `assemble.py`, `frag/`). `SDLShim` and `SDLKeys` are hand-written, not generated.
  - `DescChk`: checks that all 126 SDL members lwjgl3ify references exist with matching descriptors.
  - Desktop harness: `lwjgltest` (fake GLFW bridge; asserts no context work on `RFB-ActualMain-EventLoop`).
  - Mod bytecode scanner: `scan.py`.
- **Java compile check:** JDK 21 with `-source 8 -target 8 -XDignore.symbol.file`.

## Key architecture notes
- **Threads:** lwjgl3ify's SDL event loop runs on the first thread (`RFB-ActualMain-EventLoop`), and the game runs on the "Client thread". In `SDLShim`, GL contexts are virtual handles. The native bridge context is realized lazily on the first non-event-loop thread that calls makeCurrent; calls on the event-loop thread are bookkeeping only.
- **Single surface:** the bridge supports only one EGL window surface; a second one fails with `EGL_BAD_ALLOC`. That is why contexts are reused and why shared contexts are unsupported today.
- **Input:** GLFW callbacks are translated into SDL events in a native queue that `SDL_PumpEvents` / `SDL_PeepEvents` drain, under a lock around `glfwPollEvents`.
