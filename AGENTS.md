# Code review workflow

Read `docs/CODE_REVIEW.md` before continuing review work. It records the user's
approved workflow, section boundaries, progress, findings and validation limits.
Review one agreed section at a time. Do not describe a section pass as an audit
of the entire repository.

For the latest cross-agent handoff, also read `CLAUDE.md`. It records retained
changes, explicit reversions and device verification still pending.

Before you commit, push, build or deploy to the iPad, read `docs/LOCAL_AGENT_WORKFLOW.md`
(exact commands). Rules that always apply:
- A question is not an instruction: answer it, do not act on it.
- Never push to `main`, never force-push, never run `git reset --hard`, `git clean` or `rm` on files
  you did not create, never change git config, and never overwrite `CLAUDE.md` or `AGENTS.md`.
- Work only in this repo, not the Actions runner checkout. The iOS app cannot be built or run on this machine,
  but after editing a `.m`/`.c` file run `scripts/check_compile.sh <file>` (syntax check against the iOS SDK).
- Do not claim success you did not observe. Before saying a change is done, follow section 8 of
  `docs/LOCAL_AGENT_WORKFLOW.md` (compile check + trace the changed code by hand). If confused, stop and report.
