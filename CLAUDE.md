# Claude handoff — 2026-10-29

Current work: the user authorized replacing the SDL3-to-GLFW shim with native SDL3,
then explicitly authorized the renderer upgrades from Taylen-chud's 1.2.0 release.
See `docs/NATIVE_SDL3.md` for scope, pins and validation. Other UI/control-layout
changes and additional review sections remain deferred. The first GTNH device test of `6dd8777` failed during renderer initialization.
See the failure and follow-up in `docs/NATIVE_SDL3.md`; do not describe this
migration as device-verified.


## Deferred: Angelica SDL GPU UIKit crash

The user asked to note this for later. GTNH on MobileGL was confirmed working
correctly after afd3cbf. Enabling `-Dangelica.sdlgpu.enable=true` selected native
SDL GPU Metal and created an Apple M3 device, then crashed because SDL's Metal
window path called UIKit off the main thread (`UIWindow setRootViewController`,
`NSInternalInconsistencyException: Call must be made on main thread`).

Fix 7e328b9 marshals SDL GPU window claim/release and device destruction to the
UIKit thread. It passed build/API checks and was copied to LiveContainer as
Amethyst-latest.ipa. Installation and SDL GPU runtime success are unconfirmed.
Defer further work on this crash until the user returns to it. Details are in
`docs/NATIVE_SDL3.md`; diagnostics are ignored under
`diagnostics/ipad/20261030-065617-334228/`.

Read this file and `docs/CODE_REVIEW.md` before editing. This records Codex's work
and the user's decisions; it is not a claim that the whole launcher was audited.
The user has stopped for today. Do not start another review section without a new
request. Verify the actual branch, working tree and remote state before resuming.

## Branch and deployment state

- Repository: JeffromAltis/Amethyst-iOS-modpack-import.
- Codex reviewed main and pushed fixes to `codex-review`. Review PR:
  https://github.com/JeffromAltis/Amethyst-iOS-modpack-import/pull/1
- Codex has not merged the PR or pushed these fixes to main. Do not assume main
  contains them. Any merge/main change needs separate user authorization.
- Latest delivered app code: `18e846e`. Subsequent `18e7256` only records validation.
  This handoff is also documentation only; it does not require another IPA build.
- Successful build and confirmed USB copy for `18e846e`:
  https://github.com/JeffromAltis/Amethyst-iOS-modpack-import/actions/runs/40832497677
- Fresh IPA was copied to LiveContainer Documents as `Amethyst-latest.ipa`.
  Copying is not installation: the user installs through LiveContainer's picker.
  Installation and runtime success of this latest build are not yet confirmed.
- Last build actually observed in device logs was `cea3c1e`, before the latest fix.

## Changes retained

Sections 1 and 2 were tested and accepted by the user for normal behavior; later
mod-icon testing found the UI issue below. Edge/failure cases are not all verified.

Section 1 — instances and saved data:
- Validate profile registries, preserve recovery copies, repair invalid selection,
  report save errors and roll back failed metadata operations.
- Protect shared/legacy folders and detach a directory before asynchronous deletion.
- Prevent instance folder collisions and bound long Unicode folder names.
- Fix stale Java arguments and empty-list/profile-editor handling.
- Remove “Delete Instance (Keep files)” and the equivalent profile-list swipe
  action at the user's explicit request. Do not add restore functionality or
  reintroduce that deletion option. Existing orphaned folders were not deleted.

Section 2 — mod management:
- Target exact enabled/disabled file paths; recognize duplicate mod copies;
  improve checksum-cache invalidation and ignore directories named like JARs.
- Protect against unrelated filename collisions and refresh batch dependency state.
- Preserve disabled state during updates and honor pinned dependencies.
- Improve snapshot/prerelease compatibility detection, CurseForge pagination,
  stale source/category callbacks and reused-cell icon request cancellation.

See `docs/CODE_REVIEW.md` for detailed scope, validation and earlier broad fixes.

## Modpack import changes were reverted

The user explicitly requested reverting all section 3 modpack import changes.
`0951ace` restores section 3 production files to `e703910`, the accepted end-of-
section-2 baseline. Earlier accepted instance/import-related changes from section 1
remain; this was not a reset of the entire repository to original main.

Removed section 3 manifest validation, new path/symlink checks, streaming extraction,
override preflights, changed package/folder naming, profile-publication changes,
path-validator tests, and the later automatic retry/progress changes. Do not claim
these features are present or reapply them without a new user request. Section 4
has not been reviewed; sections 5–10 are also not completed (see scope table).

The initial extraction containment rejection was introduced by Codex's section 3
changes. Later device logs showed network-connection-loss errors downloading JARs
from multiple packs. Retries recovered some downloads but did not resolve all
failures. There has been no controlled comparison with original main, so the
cause of those disconnects and whether earlier changes contributed remain unknown.
Do not blame the user's Wi-Fi or claim the network problem is fixed.

## Latest installed-mod icon change and pending verification

The affected screen is the INSTALLED mods list with on/off switches, not the
Modrinth/CurseForge browser. User reported icons briefly returning to defaults
while scrolling/pulling the window down.

- `cea3c1e` added a thumbnail cache to ModsManagerViewController. User tested that
  build and reported the flash remained. User requested removing that change.
- `18e846e` removes that cache completely and restores the previous row icon loader.
  Browser row code was not changed by either icon follow-up.
- The remaining fix is in ModsManagerViewController: refresh initially or after a
  browser visit, rather than on every viewWillAppear; retain recognized mod rows
  while refreshing instead of temporarily publishing a raw scan with no icon URLs.
- Code inspection identified this reset path and canceled sheet dismissal as a
  possible trigger. Device runtime confirmation of that explanation/fix is pending.
- iOS compilation, Clang analysis, full IPA build and USB delivery passed. These
  checks do not prove the visual issue is resolved. Next device test: scroll the
  installed list, pull down/cancel dismissal, and return from browser after a mod
  change; confirm icons remain stable and installed rows still refresh correctly.

Existing AFNetworking caching remains: decoded images in memory and a URL-response
cache configured for 20 MB memory / 150 MB disk. Memory cache is lost on process
termination; disk cache can persist subject to HTTP rules and eviction. There is
no extra custom icon cache now and no guarantee icons are available offline.

## Tools and working practices

- Independent review clone: `amethyst-review` under the shared Claude workspace.
  Avoid the Actions runner checkout; Actions replaces its files/Git metadata.
  An earlier `codex-review` worktree was invalidated by runner checkout changes.
- Build manually via `build-fork.yml` on codex-review with `upload=true`. Pushes to
  codex-review do not trigger that build. Confirm the actual “Copied ... as
  Amethyst-latest.ipa” log line; a successful workflow can otherwise skip USB copy.
- `python3 scripts/collect_ipad_logs.py` collects guest app logs read-only over USB;
  `--crashes` also copies crash reports with originals retained. Diagnostics live
  under ignored `diagnostics/ipad/`. Logs may contain private/authentication data;
  never commit or paste full raw logs. Collect relevant errors before guessing.
- LiveContainer bundle used: `com.kdt.livecontainer.W89WFJM5TF`. Last active guest:
  `4360C1BB-C3EE-43FF-99A3-6A43AF59781B`; verify this when collecting future logs.
- Two remaining host tests cover USB transfer success/failure, not native mod UI:
  `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -v`.
- Keep fixes narrow and updates concise. The user objected to long speculative
  review/build cycles. Distinguish inspected, compiled, built, copied, installed
  and device-tested states. Do not claim a fix worked until verified.
- LiveContainer shortcut troubleshooting is deferred. Do not change its private
  container URL or pairing/trust setup as part of unrelated work.
