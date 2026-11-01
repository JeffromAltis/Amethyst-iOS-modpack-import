# Claude handoff — updated 2026-10-31

Read this file first. Full prior handoff text (Codex-era detail, icon-fix history, section scope) is in
`docs/HANDOFF_HISTORY.md`; review detail is in `docs/CODE_REVIEW.md`; the native SDL3 migration log
(newest sections last) is in `docs/NATIVE_SDL3.md`. Verify branch, working tree and remote state before editing.

## State
- Repo: JeffromAltis/Amethyst-iOS-modpack-import. PR #1 (`codex-review`) was MERGED into main on 2026-11-01 at the
  user's request (merge commit fee34203). Keep working on `codex-review`; merging further changes to main needs the
  user's explicit approval each time.
- Independent clone is `amethyst-review` in the shared Claude workspace. Avoid the Actions runner checkout.
- Native SDL3 replaced the Java SDL shim (see `docs/NATIVE_SDL3.md`). Minecraft 26.3 + native Controlify FFM
  works (user-confirmed, 095613b). GTNH on MobileGL works. The older Controlify/JNA GLFW fallback is retained
  on purpose. No further renderer or older-binding migration is approved unless the user asks.
- Installed-mods icon flash: accepted by the user as good enough (18e846e).

## Active work
- MobileGL bug fixing/testing (user's stated next focus, 2026-11-01). Renderer benchmark results: see
  `docs/BENCHMARK_PLAN.md` and memory; MobileGL beats MobileGlues, VulkanMod is fastest; no GL-to-Metal translator.

## Recently fixed
- Controlify 1.21.11 generic profile: `ControlifyCompatTransformer` used Java's internal ASM, absent on Java 25, so
  the `fetchType` hook never installed (log: `ControlifyCompat unavailable ... jdk/internal/org/objectweb/asm`).
  Now uses the defining loader's Fabric ASM tree API via reflection (bcd9749). User confirmed on device with
  build f2b2c0a7 (2026-11-01). Rumble hook shares the same patch; not separately verified.
- Build infra: `assets.angelauramc.dev` (iOS JRE zips) reset connections on 2026-11-01. Builds normally reuse
  `depends/java-*-openjdk` already in the runner workspace; a fresh checkout lost them. Workflow now restores
  them from `~/jre-cache` (f2b2c0a7). Keep `~/jre-cache` (from a prior good build) if the host stays down.

## Parked (do not start without a request)
- Angelica SDL GPU UIKit crash (fix 7e328b9 unconfirmed): revisit only if a similar crash recurs.
- Modpack download disconnects: cause unknown, revisit only if it becomes an issue. Section 3 modpack import
  changes were reverted at the user's request; do not reapply.
- Uncommitted diagnostic-disabling edits (JavaLauncher.m, metal_conversion_trace.m, mobilegl_draw_trace.h,
  MobileGL submodule): leave out of commits; the user may want them later for rendering diagnosis.
- Code review sections 4–10: to be noted/started only AFTER the SDL/controller rewrite is finished.
- LiveContainer shortcut troubleshooting: dropped (believed a Codex problem).
- Retained user decisions: "Delete Instance (Keep files)" is removed, do not reintroduce.

## Working practices
- Build manually via `build-fork.yml` on codex-review with `upload=true`; pushes do not trigger it. Confirm the
  log line "Copied ... as Amethyst-latest.ipa". Copying is not installing: the user installs via LiveContainer.
- `python3 scripts/collect_ipad_logs.py` (`--crashes` too) reads guest logs over USB into ignored
  `diagnostics/ipad/`. Logs can hold private data: never commit or paste raw logs. Bundle
  `com.kdt.livecontainer.W89WFJM5TF`; verify the active guest UUID before collecting.
- Host tests: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -v` (USB deploy only).
- Keep fixes narrow and updates concise. Distinguish inspected, compiled, built, copied, installed and
  device-tested. Never claim a fix worked until verified. Don't change work outside the authorized scope.
