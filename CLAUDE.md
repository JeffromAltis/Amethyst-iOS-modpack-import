# Claude handoff — updated 2026-10-31

Read this file first. Full prior handoff text (Codex-era detail, icon-fix history, section scope) is in
`docs/HANDOFF_HISTORY.md`; review detail is in `docs/CODE_REVIEW.md`; the native SDL3 migration log
(newest sections last) is in `docs/NATIVE_SDL3.md`. Verify branch, working tree and remote state before editing.

## State
- Repo: JeffromAltis/Amethyst-iOS-modpack-import. Work happens on `codex-review` (PR #1, open, mergeable).
  **Do not merge or touch main**: the SDL/controller rewrite is unfinished; merging needs explicit user approval.
- Independent clone is `amethyst-review` in the shared Claude workspace. Avoid the Actions runner checkout.
- Native SDL3 replaced the Java SDL shim (see `docs/NATIVE_SDL3.md`). Minecraft 26.3 + native Controlify FFM
  works (user-confirmed, 095613b). GTNH on MobileGL works. The older Controlify/JNA GLFW fallback is retained
  on purpose. No further renderer or older-binding migration is approved unless the user asks.
- Installed-mods icon flash: accepted by the user as good enough (18e846e).

## Active work
- Why Controlify for 1.21.11 (3.0.1+lts, JNA/GLFW fallback) shows the generic profile. Finding (2026-11-01 log,
  guest 4360C1BB): the instance runs on Java 25, where `ControlifyCompatTransformer` (patchjna agent) fails with
  `NoClassDefFoundError: jdk/internal/org/objectweb/asm/ClassVisitor` (Java 25 dropped the internal ASM), so the
  `fetchType` hook never installs and Controlify logs the pad as `GLFWUniqueControllerID[jid=0]-hid (null)`.
  Fix written (uncommitted, not built/installed): `ControlifyCompatTransformer` now uses the defining loader's
  Fabric ASM tree API via reflection. Host test on the real 1.21.11 Controlify jar patches 2 fetchType calls and the
  driver; driver verifies. Device check pending: expect `[ControlifyCompat] joystick 0 is 054c:09cc -> ...`.

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
