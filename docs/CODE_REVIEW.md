# Review reference

## User-approved workflow

- Review Claude's changes on `main` in JeffromAltis/Amethyst-iOS-modpack-import.
- Commit and push fixes to `codex-review`, and open/update a PR targeting `main`.
- Do not push directly to or merge into `main` without a separate request.
- Build IPAs and copy them to the USB-connected iPad through the self-hosted
  `build-fork.yml` Actions workflow. Manually dispatch with a descriptive title
  and `upload=true`; pushes to codex-review do not trigger that workflow.
- Deployment writes `Amethyst-latest.ipa` into LiveContainer's Documents folder.
  Installation is completed with LiveContainer's file picker. Shortcut repair
  is deferred. A successful copy does not prove successful installation/gameplay.
- Use an independent clone outside the Actions runner checkout. Actions checkout
  can replace its Git metadata and invalidate worktrees attached to that checkout.
- State what was reviewed and distinguish compilation/static analysis from runtime tests.

## Sections

| Order | Section | Scope | Status |
| --- | --- | --- | --- |
| 1 | Instances and saved data | Creation, profiles, directories, upgrades, editing, deletion | User tested and accepted; specific fault-injection checks remain unverified |
| 2 | Mod management | Scanning, recognition, browsing, updates, dependencies, enable/disable | User tested and accepted; specific edge cases remain unverified |
| 3 | Modpack importing | Modrinth, CurseForge, MultiMC/Prism, manifests, extraction, overrides | Reverted at user request; production code restored to pre-section-3 baseline |
| 4 | Downloads and installation | Queues, progress, cancellation, checksums, caching, recovery | Not started |
| 5 | Mod loaders | Fabric, Quilt, Forge, NeoForge, processors, lwjgl3ify | Not started |
| 6 | Java and game launching | Runtimes, arguments, classpaths, inheritance, startup failures | Partial earlier coverage |
| 7 | Accounts and authentication | Login, token storage, refresh, logout, errors | Not started |
| 8 | Rendering and input | Graphics, native bridges, touch, keyboard, mouse, controllers | Not started |
| 9 | UI and preferences | Navigation, settings, lifecycle, accessibility, compatibility | Partial earlier coverage |
| 10 | Build and deployment | Makefiles, CMake, Actions, packaging, signing, USB | Partial earlier coverage |

External libraries need a separate pass, starting with local patches and integration.
The user tested sections 1 and 2 and reported both look good. Section 3 changes were subsequently reverted at the user's request.
Do not automatically advance to section 4.

## Previous broad pass

PR: https://github.com/JeffromAltis/Amethyst-iOS-modpack-import/pull/1

Source main: a782e3a. Review head before section 1: 9424a7d.
Earlier fixes covered stale mod-list callbacks, atomic replacement, disabled mod
updates, exact dependencies, iOS 14 menus, folder collisions, legacy storage
fallback, deletion path checks, profile-name collisions and failed USB copies.
This was partial coverage, not a repository-wide audit.

Validation at 9424a7d: iOS compiler checks, Clang static analysis of selected files,
two USB regression tests, full Actions build and confirmed iPad copy passed.
UI races, dependency graphs and legacy upgrades were not exercised at runtime.

## Section 1

Scope: PLProfiles, instance creation, profile editor/list/dashboard, startup data
directory selection, profile creation by import, and their persistence/path helpers.

### Pass findings and fixes

| Finding | Resolution |
| --- | --- |
| Invalid/unreadable registry was overwritten with defaults; valid JSON with the wrong structure could crash | Validate root/profile structures, preserve a uniquely named `.recovery-*` copy before resetting, block saving if backup fails, and repair missing/invalid selection |
| Save failures were ignored during creation, renaming and deletion | Return a save result, report errors and restore registry/selection on failed destructive operations; keep the editor open on failure |
| Profile-list confirmation captured a reusable cell and an old row index | Capture the profile name, recheck that it exists and is not the last profile, then reload current rows |
| Background deletion retained the original instance path | Move files to a unique `.deleted-*` directory before releasing the name; delete only that detached directory; restore it if registry saving fails |
| Dashboard Java arguments stayed blank or reflected another instance | Refresh arguments alongside other instance settings |
| Empty version categories and missing Java/control lists could use invalid array indexes | Handle empty lists and NSNotFound explicitly, use NSInteger indexes and insert the default Java entry rather than replacing element zero |
| Long Unicode names exceeded filesystem byte limits | Bound sanitized folder stems in UTF-8 bytes without splitting composed characters |
| Long imported pack names could truncate the content hash and collide | Preserve the full hash after the bounded stem; retain old folder identities when their names already included the full hash |
| An editor could recreate a profile removed elsewhere | Refuse saving an editor whose original profile no longer exists |

### Validation

- iOS 14-targeted compilation of changed native files passed.
- Clang static analysis of the section's changed controllers/model passed;
  MinecraftResourceDownloadTask has an existing unrelated dead-store warning at versionStr.
- Existing USB success/failure regression suite passed. These tests do not cover profile behavior.
- Full Actions build, artifact uploads and confirmed USB copy passed for code revision 6951725:
  https://github.com/JeffromAltis/Amethyst-iOS-modpack-import/actions/runs/40815224323
- No runtime recovery/deletion tests were performed on the user's saved worlds.
- Interrupted cleanup may leave a `.deleted-*` directory; its files remain recoverable.
- Import/download lifecycle behavior beyond instance naming belongs to sections 3/4;
  profile-save errors now surface, but import transaction rollback is not covered by this pass.
- Runtime scenarios below have NOT been executed automatically on an iOS device.

### Device checks before considering runtime behavior verified

Use disposable instances/copies of data for destructive checks:
1. Corrupt/malformed JSON, absent selection, missing version ID, and missing registry;
   confirm recovery file preservation and a valid selected profile.
2. Fail a profile write; verify creation/rename/deletion reports failure and does not
   discard existing metadata/files. Verify blocked backups cannot overwrite the original.
3. Delete a profile after list refresh; ensure the confirmed profile is the target,
   the last profile remains, and a new instance at a reused path survives cleanup.
4. Switch dashboards with different Java arguments and open empty version categories.
5. Create long Unicode names and import distinct packs with long common prefixes;
   verify valid distinct directories and normal reimports retain their identity.
6. Confirm the previous pass's legacy-storage fallback and shared-directory deletion
   protection with copies of an old installation.

Section 1 was accepted by the user after device testing. Do not infer that every
fault-injection scenario above was exercised. Section 2 is now authorized.


### Follow-up: deletion option removed

The user decided against implementing restoration and requested removal of
“Delete Instance (Keep files)”. Removed that dashboard action and the profile-list
swipe action, which also deleted metadata while keeping files. Deletion now goes
through the dashboard's explicit delete-with-files confirmation and existing
shared/legacy-folder and last-instance protections. Existing orphaned folders are
not touched. Restore support remains out of scope.

Validation: iOS 14 compilation passed. Full Actions build, uploads and actual USB
copy passed for d4cf3f9:
https://github.com/JeffromAltis/Amethyst-iOS-modpack-import/actions/runs/40816296684
Installation and UI verification on the iPad remain manual.


## Section 2: mod management

Scope: ModCatalog, ModsManagerViewController, ModBrowserViewController and their
API interactions. Earlier mod fixes were rechecked as part of this pass.

### Findings and fixes

- Enabled/disabled files sharing a base name could target one another during
  toggle, deletion or update. Actions and UI replacement now use the exact listed
  path. Missing update sources require a refresh rather than guessing another file.
- Recognition stored one mod per checksum/fingerprint. Matching metadata and
  update offers now reach every copy. Dependency lookup prefers enabled copies.
- Hash-cache stamps converted dates to second-precision strings. Cache identity
  now retains full date objects, size and filesystem file identity.
- Directory names ending in .jar were treated as mods. Scans exclude directories,
  and installation refuses a directory occupying its destination.
- New downloads could overwrite unrelated same-name JARs. Replacement now requires
  an explicitly selected old path or an identical known checksum; collisions report
  an error without modifying existing contents.
- Update All/dependency checks used the pre-batch installed snapshot. Each successful
  install now publishes fresh file/version metadata before subsequent operations.
- Compatibility detection truncated snapshots/pre-releases or guessed a NeoForge
  loader number as a game version. Preserve full vanilla/Fabric/Quilt IDs, inspect
  version libraries for custom loader IDs, and leave unknown NeoForge game versions
  unknown until their inherited JSON is available.
- CurseForge listed only the first 50 matching files. Fetch pages before sorting;
  report the API result limit rather than treating an incomplete list as complete.
- Category responses/actions could belong to a previously selected source. Drop
  mismatched source callbacks and prevent category changes during installations.
- Reused cells could receive icons from old download requests. Cancel the previous
  icon request before configuring the cell, including rows without an icon.

CurseForge pagination contract: https://docs.curseforge.com/rest-api/#get-mod-files

### Validation

- iOS 14 compilation passed (unguarded API availability treated as an error).
- Clang static analysis of the catalog, manager and browser passed without diagnostics.
- Full Actions build, artifact uploads and actual USB copy passed for 0d5d5c5:
  https://github.com/JeffromAltis/Amethyst-iOS-modpack-import/actions/runs/40817472579
- Install Amethyst-latest.ipa through LiveContainer to perform the device checks.
- No automated native runtime regression suite is available here for these controllers.
  Compilation/static analysis do not validate device behavior.

### Device checks

Use a disposable instance; do not launch with deliberately duplicated enabled mods:
1. With example.jar and example.jar.disabled, delete the disabled row and verify
   the enabled file survives. Toggle into an occupied target and verify an error,
   with both files preserved. Refresh and update each row separately.
2. Copy an identical mod under another name; both copies should be recognized.
3. Check a directory named fake.jar is ignored, and install collisions leave its
   contents and unrelated JARs unchanged.
4. Browse a Fabric snapshot/pre-release instance and inspect the full filter ID.
5. Browse a CurseForge project with more than 50 compatible files; check older
   versions are listed. Change sources while categories load and check icons on
   recycled rows without icons.
6. Install required dependencies and run Update All; verify newly installed versions
   are used for later dependency checks and disabled updates remain disabled.

Do not advance to section 3 until the user requests it.


## Section 3: reverted at the user's request

The user requested reverting all modpack import review changes after extraction
and recurring network errors during testing. Restored all production files changed
by section 3 and its follow-ups to e703910, the accepted end-of-section-2 baseline.
Removed the added path validator and its tests. This removes section 3 manifest,
extraction, profile-publication, path/override and naming changes as well as the
subsequent symlink fix and automatic download retry/progress changes.

The accepted section 1/2 fixes remain. Existing iPad instances and files are not
modified by this source rollback. The separate read-only iPad log collector and
ignored diagnostics directory remain available for future diagnosis:
`python3 scripts/collect_ipad_logs.py --crashes`
Raw logs can contain private data; do not commit them.

Do not resume section 3 fixes or advance to section 4 without user direction.
Validation: restored native files passed iOS-targeted compilation; both USB
transfer tests passed. Production code and remaining tests match e703910 exactly.
Full Actions build, uploads and confirmed USB copy passed for 0951ace:
https://github.com/JeffromAltis/Amethyst-iOS-modpack-import/actions/runs/40823361612
Install the fresh Amethyst-latest.ipa through LiveContainer to test the rollback.
Device runtime import behavior remains unverified.
