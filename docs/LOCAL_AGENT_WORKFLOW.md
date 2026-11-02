# Workflow for local coding agents (OpenCode)

Written 2026-11-02 from the actual commit/build/deploy flow used in this repo. Read this before you
commit, push, build or deploy. For project state and what is parked, read `CLAUDE.md` first.

## Hard rules (a previous local session broke these)
- **A question is not an instruction.** If the user asks "is it ready to merge?" or "isn't it behind main?",
  ANSWER the question. Do not merge, push, reset or delete anything unless the user clearly tells you to.
- **Never push to `main`, and never use `git push -f`/`--force`.** Merging into `main` needs the user's explicit
  approval, given AFTER you have shown what would change. Show `git log --oneline origin/main..<branch>` first.
- **Never run `git reset --hard`, `git clean`, `git checkout -- .`, `rm`, or `git restore` on files you did not
  create yourself.** They destroy the user's uncommitted work. If something looks wrong, stop and ask.
- **Never overwrite `CLAUDE.md` or `AGENTS.md`.** When asked to "remember" something, add a short section to this
  file's folder or ask where it should go; do not replace the existing handoff.
- **Never change git config** (`git config user.name`/`user.email`, remotes, branch tracking). Use the `-c` flags
  in the commit step instead.
- **Work inside this repo** (`amethyst-review`), not the workspace root. Do not read or edit the Actions runner
  checkout (`../actions-runner/_work/...`) or the stale clone under `AI_Stuff/`: they are not this code.
- **Do not claim success you did not observe.** Say exactly which of these happened: inspected, compiled,
  built, copied to the iPad, installed, tested on the device. If a command fails or is confusing, stop and
  report it; do not retry variations in a loop. Do not create summary or "verified" files in the repo.
- For reviews, use the read-only `plan` agent. Review one agreed section at a time (`docs/CODE_REVIEW.md`).

## Ground rules
- Repo: JeffromAltis/Amethyst-iOS-modpack-import (a fork).
- Branches: `ui-rework` (UI work), `codex-review` (SDL/controller work, PR #1 was merged), `main`, `mobilegl`.
  Check `git branch --show-current` before editing.
- Keep changes narrow. The user dislikes long speculative changes. Do not start parked work (see `CLAUDE.md`).
- This Linux machine has no Xcode and cannot link or run the app. It CAN syntax-check one file against the iOS
  SDK: `scripts/check_compile.sh Natives/<File>.m` prints `OK` or the compiler errors. Run it after every
  edit to a `.m`/`.c` file. It catches wrong selectors, undeclared names and bad types, but it does NOT show
  the behaviour is right. The only full build is the CI workflow below.
- Do not run Codex CLI (`codex`): it sends code to OpenAI. Ask first.

## 1. Commit
```
git status --short            # expect ONLY the files you meant to change
git add <specific files>      # never `git add -A` (stray Natives/__pycache__, diagnostics, logs)
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Short imperative subject" -m "Why, in a sentence or two."
```
- No git identity is configured, so the `-c` flags are required. Do not chain commands with `;` after a
  commit: a failed commit followed by a build once built the OLD commit. Use `&&`.
- Follow the style of `git log --oneline -10`.
- Never commit: iPad logs or anything under `diagnostics/ipad/` (may hold private data), the parked
  diagnostic edits (`JavaLauncher.m`, `metal_conversion_trace.m`, `mobilegl_draw_trace.h`, the MobileGL
  submodule), or secrets. The repo is public.

## 2. Push
```
git push origin <branch>      # normal push of a feature branch only; never main, never -f
```
A push does NOT start a build for `ui-rework` or `codex-review` (the workflow only auto-runs on a few feature
branches). The build checks out the branch from GitHub, so the commit must be pushed first.

## 3. Build (GitHub Actions, self-hosted runner `linux-desktop`)
1. Check the runner is online and idle:
   `gh api repos/JeffromAltis/Amethyst-iOS-modpack-import/actions/runners --jq '.runners[] | "\(.name) \(.status) busy=\(.busy)"'`
2. Start the build (inputs: `description` = run title, `upload` = also attach the ipa as an artifact):
   `gh workflow run build-fork.yml --ref <branch> -f upload=true -f description="<what this build contains> (<short sha>)"`
3. Find the run: `gh run list --workflow build-fork.yml --limit 2`
   Wait for it: `gh run view <run-id> --json status,conclusion`. One observed build took about 3 minutes.
4. Confirm success with the summarizer, not by reading the raw log (thousands of lines):
   `scripts/build_summary.py <run-id>` prints about 8 lines: status, duration, whether the ipa was really COPIED
   to the iPad, real compile errors, failed steps, artifacts. `scripts/build_summary.py --wait` waits quietly
   for the latest run to finish and then prints the same summary, so you do not need to poll. Exit code 0 means
   built AND copied; 1 failed; 3 built but NOT copied (for example no iPad connected); 4 still running.
   A green build alone does not prove the copy happened.
- The build runs `scripts/build_linux.sh` (clang + ld64.lld + ldid, SDK in `~/ios-toolchain`, ccache).
- JRE zips: the host `assets.angelauramc.dev` has been resetting connections. Builds reuse
  `depends/java-*-openjdk` or restore them from `~/jre-cache`. NEVER delete `~/jre-cache`.

## 4. Deploy to the iPad
- The build job's last step copies the ipa over USB into LiveContainer's Documents as `Amethyst-latest.ipa`
  (script: `scripts/deploy_usb.sh`; needs `idevice_id`, `ifuse`, `fusermount`). The iPad must be plugged
  into a direct USB 3 port, unlocked and trusted. If no iPad is found, the script exits 2 and the workflow only
  prints the warning "No iPad connected; skipped USB copy" and the job still ends GREEN. So a green build does
  NOT prove the copy happened: always grep the log for the "Copied ... as Amethyst-latest.ipa" line.
- Copying is NOT installing. The USER installs it in LiveContainer (tap "+" and pick `Amethyst-latest.ipa`,
  or use their one-tap Shortcut). You cannot install it; tell the user it is ready.
- With `upload=true` a downloadable copy is also attached to the run as the `amethyst-ios-ipa` artifact.
- Never touch the iPad's storage without asking (it was full once). Never publish an ipa: it embeds the
  CurseForge API key.

## 5. Debugging on the device
- `python3 scripts/collect_ipad_logs.py` (add `--crashes` for crash reports) reads the guest logs over USB into
  the git-ignored `diagnostics/ipad/`. LiveContainer bundle: `com.kdt.livecontainer.W89WFJM5TF`. Verify the
  active guest UUID first. Never paste raw logs anywhere.
- Do NOT read the raw logs (megabytes). Run `scripts/summarize_ipad_logs.py` (newest collection) or
  `scripts/summarize_ipad_logs.py diagnostics/ipad/<folder>`: about 60 redacted lines with the newest log's
  distinct errors (with repeat counts and first stack frames), its last lines, and the newest crash report
  decoded. Add `--all` to include logs from older app installs. Redaction is best effort; do not commit or
  paste its output outside this repo's discussion without a look.
- Host tests (USB deploy script only): `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -v`

## 6. Useful code facts
- Settings screens subclass `PLPrefTableViewController` (`Natives/PLPrefTableViewController.m`). Row types:
  `typeSwitch`, `typePickField`, `typeTextField`, `typeChildPane`. A switch can store custom values with
  `@"customSwitchValue": @[offValue, onValue]`. Row titles come from `item[@"title"]` or
  `preference.title.<key>`; strings live in `Natives/resources/en.lproj/Localizable.strings`.
- Edit Instance page: `Natives/LauncherProfileEditorViewController.m`. Its `getPreference`/`setPreference`
  blocks read and write the profile dictionary. Profile values are STRINGS (e.g. `"true"`/`"false"`), not
  NSNumbers. A key with no value returns nil unless the getter handles it.
- Profiles and defaults: `Natives/PLProfiles.m`. A profile key maps to a global preference
  (e.g. `gamepadPassthrough` -> `control.gamepad_passthrough`). Read global booleans with the C function
  `getPrefBool(@"section.key")` (declared in `LauncherPreferences.h`; it is NOT an Objective-C method).
  `+profile:resolveKey:` is intentionally not exposed in the header.
- SDL3 native code lives in `Natives/` (e.g. `sdl3_hook.m`, `sdl3_gl_layer.m`); these files are already
  tracked on every branch. Details: `docs/NATIVE_SDL3.md`.
- Game directories: each instance lives in `Documents/instances/<name>/`; shared data is in
  `Documents/game_data/`. A profile's `gameDir` is `./instances/<name>`, relative to `AME_HOME`. Always
  resolve it with `[PLProfiles absolutePathForGameDir:]`. Do not build paths like `GAME_DIR/../instances`.
- Retained user decisions: "Delete Instance (Keep files)" was removed; do not reintroduce it. The Section 3
  modpack-import changes were reverted at the user's request; do not reapply.

## 7. Working with limited context
- Read only the files you need (`@file`), not whole directories. Prefer searching with grep over reading
  many files. Start a new session per task and keep notes in git commits, not in the chat.

## 8. Before you say a change is done (lessons from testing local models on this repo)
In a test where local models re-did the Edit Instance "gamepad passthrough" switch, every model's summary said
the work was complete, and most were wrong. Do these checks and report only what they show:
1. Run `scripts/check_compile.sh` on every `.m`/`.c` file you edited. A compile error means you are not done.
2. Trace the changed code by hand for the case that matters. Pick one concrete input (for example "profile has
   no value and the global setting is On") and follow it line by line through every `if/else` and early
   `return`. Adding a branch AFTER a condition that already returns for your case means the branch never runs.
   Example of the exact trap: in `LauncherProfileEditorViewController.m`, `getPreference` begins with
   `if (value.length > 0 || ![self isPickFieldAtSection:...]) return value;`. A switch row is not a pick
   field, so that line always returns first; new code for an unset switch value must go BEFORE it.
3. Remove code your change made unused (for example a title block only the old row used).
4. Keep the edit small. Do not rewrite a shared condition for everyone to fix one row: it can change other
   screens (for example how an empty-string profile value shows on pickers).
5. Your final message must list what you changed, the compile-check result, and anything you did NOT verify.
   Never write "this will work" or "it now shows X" unless step 2 proved it. If you ran out of steps, say so.

## 9. Reviewing code (read-only review tasks)
Local models reviewing this code produced mostly false findings. When asked to review:
- Read the whole function around any suspect line, and grep for callers and guards, before reporting.
- Check the language rules: messaging `nil` in Objective-C is a no-op (not a crash); a function-local `static`
  buffer that is freed and regrown is a cache, not a leak; an existing early `return` or lock may already
  protect the code; a symmetric function that releases/locks something where this one does not IS a real clue.
- Report fewer, confirmed findings: file, line, exact quote, the concrete failing scenario. Zero findings is a
  valid answer. Label anything you could not confirm as "unverified", with low confidence.
