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
| 1 | Instances and saved data | Creation, profiles, directories, upgrades, editing, deletion | Code pass complete; device tests pending |
| 2 | Mod management | Scanning, recognition, browsing, updates, dependencies, enable/disable | Partial earlier coverage |
| 3 | Modpack importing | Modrinth, CurseForge, MultiMC/Prism, manifests, extraction, overrides | Partial earlier coverage |
| 4 | Downloads and installation | Queues, progress, cancellation, checksums, caching, recovery | Not started |
| 5 | Mod loaders | Fabric, Quilt, Forge, NeoForge, processors, lwjgl3ify | Not started |
| 6 | Java and game launching | Runtimes, arguments, classpaths, inheritance, startup failures | Partial earlier coverage |
| 7 | Accounts and authentication | Login, token storage, refresh, logout, errors | Not started |
| 8 | Rendering and input | Graphics, native bridges, touch, keyboard, mouse, controllers | Not started |
| 9 | UI and preferences | Navigation, settings, lifecycle, accessibility, compatibility | Partial earlier coverage |
| 10 | Build and deployment | Makefiles, CMake, Actions, packaging, signing, USB | Partial earlier coverage |

External libraries need a separate pass, starting with local patches and integration.
The user approved starting with section 1; do not automatically advance to section 2.

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

Section 2 remains pending user direction. Do not start it automatically.


### Follow-up: deletion option removed

The user decided against implementing restoration and requested removal of
“Delete Instance (Keep files)”. Removed that dashboard action and the profile-list
swipe action, which also deleted metadata while keeping files. Deletion now goes
through the dashboard's explicit delete-with-files confirmation and existing
shared/legacy-folder and last-instance protections. Existing orphaned folders are
not touched. Restore support remains out of scope.

Validation: pending build and deployment of this follow-up.
