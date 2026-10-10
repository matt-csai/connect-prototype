# Build log

A running log of notable events while building this prototype: guardrails firing, design decisions, surprises and fixes. Newest entries at the bottom. SUMMARY.md is written from this file.

---

## 2026-10-10: guard-bash.sh blocked the first commit (false positive)

**What happened.** The first `git commit` (settings, protection hooks, hook tests) was blocked by the PreToolUse Bash hook:

```
BLOCKED by guard-bash.sh: --live is not allowed. This project uses the Stripe sandbox in test mode only.
```

This also showed that the hook was already live in the session that created it, before any restart.

**Why.** The commit message went in through a heredoc (`git commit -F - <<'EOF' ... EOF`), and one of its lines mentioned "stripe --live". The hook drops quoted strings before checking, but heredoc bodies aren't quoted. So each heredoc line was checked as a separate command, and the `--live` check ran on every command no matter which program it belonged to. The commit message text matched.

**Failing test first.** Added a case to `.claude/hooks/tests/test-hooks.sh`: "allows '--live' in a heredoc commit message". It's a `git commit -F -` heredoc whose body contains `stripe --live`. Ran it and confirmed it failed (exit 2, wanted 0). Result: 27 passed, 1 failed.

**Fix.** Moved the `--live` check into the `stripe)` branch of `guard-bash.sh`, so it only applies when the command being run is `stripe`. `stripe trigger --project-name connect-prototype --live …` is still blocked, and the existing test for it still passes.

A slip along the way: the edit dropped the space in `[[ ! " $seg " … ]]`, which broke the profile check. The suite caught it right away (two stripe cases failed). After restoring the space: 28 passed, 0 failed. The commit went in as `504b1b2`.

**Still blocked everywhere.** The `sk_live_` check didn't change. It runs on the whole raw command text before any quote-stripping or splitting, so a live key prefix is blocked in any command, including inside quotes, heredocs and commit messages. The `Bash(*sk_live_*)` deny rule in `settings.json` backs it up.

**Lesson.** A denylist that matches command text has two failure modes: it misses things (the reason this hook exists) and it blocks things it shouldn't (this case). Scope each check to the program it's about, and keep a test case for every false positive found.

## 2026-10-10: second guardrail commit, design decisions

- **Testing the PostToolUse hook without a Maven project.** There's no `pom.xml` yet, so `test-hooks.sh` puts a stub `mvn` first on PATH. Its exit code comes from `STUB_MVN_EXIT`, and it prints a fake failing test plus fake key-shaped strings. That covers four behaviours now instead of waiting for the F1 scaffold: skipping when there's no pom, skipping non-Java files, reporting failures back with exit 2, and passing on success.
- **Key-shaped strings are masked in hook output.** `post-edit-check.sh` replaces `sk_/rk_/pk_` test or live keys and `whsec_...` with `[REDACTED]` before sending Maven output to Claude. Brief rule 3 says keys never appear in test output, and this hook is a path from test output into the conversation.
- **Dropped Maven's `-o` (offline) flag** from the PostToolUse hook, which the plan had. On a fresh machine, or after adding a dependency, offline mode fails with a confusing "cannot resolve" error. The time it would save is small.
- **The reviewer's allowlist is narrower than "read-only git".** `readonly-git.sh` requires `git <subcommand>` with the subcommand first, so `git -c diff.external=… diff` (which can run a program) is blocked. It also blocks `--output`, `--ext-diff` and `--textconv`, plus any shell operator. I first had `-o` on the blocked-flag list too, then removed it, because it would have blocked `git ls-files -o` (short for `--others`), which the reviewer needs to see new files.
- **The `.env.example` carve-out works live.** Writing `.env.example` went through even though `Edit(.env.*)` is denied, so the `Edit(!.env.example)` negation behaves as the docs describe.

## 2026-10-10: surprise, the new subagent isn't available until the next session

The first commit's hooks took effect as soon as `settings.json` was written (see the false-positive entry above). Subagent definitions don't: invoking `payments-reviewer` straight after creating `.claude/agents/payments-reviewer.md` failed with "Agent type 'payments-reviewer' not found". Agents load at session start. So the reviewer, and its frontmatter `readonly-git.sh` hook, can only be checked live in a new session. Until then `test-hooks.sh` covers the hook script directly (13 cases).

## 2026-10-10: payments-reviewer's first run found a secrets leak in its own guard

Run from a fresh session, before the second guardrail commit. There's no payments code yet, so it reviewed the guardrail layer. Result: 1 blocking, 5 should-fix. It never read `.env`; it worked the issue out from the hook code and git's documented behaviour.

**Blocking.** `readonly-git.sh` allowed `git diff` with any arguments, including `--no-index`. `git diff --no-index /dev/null .env` prints any file, `.env` and files outside the repo included, such as `~/.config/stripe/config.toml`. That file is real: the earlier Stripe CLI login stored the sandbox secret key there. The `Read(.env)` deny rule only covers Claude's file tools, and `guard-bash.sh` had no `.env` check. So "Claude never reads `.env`" held for the Read tool and not for Bash.

**Root cause.** The reviewer's guard used a denylist of dangerous flags inside an allowlist of subcommands. Git's surface is too big for a denylist: `--no-index` wasn't on it, and git also accepts abbreviated flags (`--ext` for `--ext-diff`).

**Should-fix:** abbreviated flags get past the denylist; no tests for `--no-index`, abbreviated flags or paths outside the repo; the `CLAUDE.md` table overstated what's enforced ("deny .env read" covers Read/Edit only); the 120 s PostToolUse timeout could silently kill the hook once Spring tests exist; Spotless rewriting the just-edited file may trigger "file modified since read".

**Lesson.** This is the reviewer doing its job: the human-reviewed layer caught a gap in the enforced layer before it was committed. Also, a guard written for one purpose (keep the reviewer read-only) needed a second property (don't print secrets) that nobody had asked it to have.

## 2026-10-10: fixes for the reviewer's findings

All tests first: 26 new cases, of which 21 failed before the fix (52 passed, 21 failed). The other 5 are "must still allow" cases that passed throughout. After the fix: 73 passed, 0 failed.

- **`readonly-git.sh` is now an allowlist.** Only `git diff/status/log/show`, each with a short list of permitted flags (plus `-U<n>` and `-<n>`). Any other flag is refused, which covers `--no-index`, `--output`, and abbreviations like `--no-ind` and `--ext`. Path arguments, including the path in `rev:path`, are refused if absolute, `~`-relative, containing `..`, or naming `.env`/`.env.*`. That also covers git's *implied* `--no-index`: `git diff /etc/hosts README.md` compares the files even without the flag. `$` is refused too, so `$HOME/...` can't get through. `git ls-files` was dropped; `git status --porcelain --untracked-files=all` lists new files instead, and the reviewer's prompt now uses it.
- **`guard-bash.sh` now blocks secrets on disk.** Any command naming `.env`/`.env.*` (other than `.env.example`, and including `.env.local.bak`-style copies) or `.config/stripe`, plus `stripe config` (`--list` prints stored keys). Quote characters are removed before matching, so `cat ".env"` is caught.
- **Avoiding a repeat of the first false positive.** The body of a *quoted* heredoc (`<<'EOF'`) is skipped, because bash expands nothing in it, so commit messages and this log can mention `.env`. An *unquoted* heredoc is still checked, because `$(cat .env)` inside it would run (there's a test for that). Accepted trade-off: `git commit -m "… .env …"` is blocked; CLAUDE.md now says to write commit messages as quoted heredocs. This entry was appended through a quoted heredoc that mentions `.env`, which tested the carve-out live.
- **Read and Edit tool rules for `~/.config/stripe/**`** were added to `settings.json`. Without them, the Read tool could open the Stripe config, the same gap one layer over.
- **The PostToolUse hook fails loudly.** macOS has no `timeout`, so the hook keeps its own 240 s budget across both Maven runs and reports "timed out … result is unknown" with exit 2. The settings timeout went up to 300 s so the hook's own budget always fires first. Maven output goes to a temp file, not a pipe: with a pipe, the killed process's children keep it open and the hook would hang until they finish. Test: a stub `mvn` that sleeps for 10 s with a 1 s budget must report a timeout in under 5 s.
- **CLAUDE.md table** now says exactly which layer covers what (the Read/Edit tools vs. Bash vs. the reviewer), and has a **Limits** line: indirect reads (a program that opens `.env` itself, or `docker compose config`) need an OS sandbox.

**Watch item (not fixed).** `post-edit-check.sh` runs `spotless:apply`, which can rewrite the file Claude just edited, so the next Edit may fail with "file modified since read". It's harmless, since Claude re-reads the file. Fix it only if it actually happens; if it does, log it here.

## 2026-10-10: second review round (payments-reviewer + /code-review) on the fixed diff

**A guardrail fired on a reviewer.** `/code-review` tried to probe `guard-bash.sh` with sample commands, and the hook blocked its own Bash call because the command text named `.env`. It didn't work around the block; it reviewed that hook by reading the code instead. It reproduced the `readonly-git.sh` findings by running the hook script directly.

**Both reviewers agree the fixes close the plain-text cases but not the shell-syntax ones.** The tests (73/73) only used literal, unquoted forms. The shell sees a different command than the hook does:
- **readonly-git.sh fails open.** A quoted flag such as `git diff '--output=x'` skips the flag check, then `basename` errors on it. Under `set -e` the hook exits 1, which Claude Code treats as a non-blocking error, so the command runs. A hook that can exit with anything other than 0 or 2 is a hole.
- **readonly-git.sh misses expansion.** Quotes, backslashes, braces and globs hide flags and paths: `"--no-index"`, `\--no-index`, `{--no-index,a,b}`, `.en[v]`. The shell turns them back into `--no-index` and `.env`.
- **guard-bash.sh skips too much in heredocs.** A quoted heredoc body still runs when it's fed to `bash`/`sh`/`python3`. Here-strings (`<<<'X'`) also trigger the skip.
- **guard-bash.sh matches literal text only.** `.en?`, `~/.config/str*` and `stripe "config"` get through.

**New issues raised:** secrets already in the environment (`env`, `printenv`, `echo $STRIPE_SECRET_KEY`); `stripe listen`, which is auto-allowed, prints the `whsec_` signing secret into the conversation; and parallel edits starting concurrent Maven runs on `target/`.

**False positives found:** `.envrc`/`.environment` blocked as `.env` (the regex has no right boundary); `git log main..HEAD` blocked by the `..` path check; and program checks still running on heredoc body lines.

**Lesson.** Matching command text is whack-a-mole against the shell's own parser: quoting, escaping, globbing and brace expansion each reopen a hole. Hooks need to fail closed on any internal error. For "never read this file" the reliable control is OS-level (the Claude Code sandbox), with the hooks as a first line and a source of clear messages.

## 2026-10-10: round-2 fixes, and the sandbox turned on

Matt's call: fix fail-open, tighten the reviewer's guard, fix the false positives, two cheap wins, write down the rest, and give the sandbox a 15-minute timebox.

**Tests first.** 26 new cases; 23 failed before the fix (76 passed, 23 failed), reproducing the fail-open bugs as real exit codes: 1 for a quoted flag, 127 for a missing helper tool, 1 for a missing project dir. After the fix: 99 passed, 0 failed, under macOS's bash 3.2, which is the bash the hooks actually run with.

- **No hook can fail open.** All four hooks have an EXIT trap that turns any status other than 0 or 2 into exit 2 with "internal error, blocking to be safe". The hooks use `${path##*/}` instead of `basename`, which had errored on words starting with `-` and, once errors blocked, would have caused a new false positive.
- **`readonly-git.sh` takes plain characters only.** The whole command must match `[A-Za-z0-9 ._/:@^~=-]`, so quotes, backslashes, globs, braces and `$` are refused before anything else. What the hook checks is exactly what git receives. `..` is refused only as a path segment, so `main..HEAD` and `HEAD~2...HEAD` work.
- **Heredoc skipping narrowed.** A body is skipped only if the heredoc is quoted, ends its line, and feeds `git commit` or `cat > file`. Bodies fed to `bash`, `python3` or `| bash` are checked, and here-strings no longer start a skip. The skipped text is also excluded from the per-command checks, which fixes the false positive where commit message lines starting with "stripe" were treated as commands.
- **`.env` end-of-name boundary.** `.envrc` and `.environment` pass; `.env`, `.env.local` and `.env.local.bak` are blocked.
- **`env` and `printenv` are blocked.**
- **`stripe listen` now asks.** It prints the `whsec_` signing secret, so Matt runs it in his own terminal and the secret never enters the conversation.

**Sandbox (timebox met, about 5 minutes).** Added `sandbox.enabled` with `autoAllowBashIfSandboxed: false`, which keeps the existing approve/ask model; a `credentials.envVars` deny for both Stripe keys; and `excludedCommands` for `docker compose` and `stripe`, since the Stripe CLI must read its own config. The existing `Read(...)` deny rules became OS-level read denies automatically, with no new path lists needed.
- **Live proof.** `d=stri; cat ~/.config/${d}pe/config.toml >/dev/null` gets past `guard-bash.sh` (the variable hides the path), and the OS refuses it: `Operation not permitted`. Output went to `/dev/null` throughout, so nothing secret was printed. This is the demo for the recording; with a `.env` that Matt creates, `cat .en?` shows the same thing.
- **Surprise 1: the sandbox doesn't understand `!` negations.** `!.env.example` came through as a literal pattern, so `.env.example` became unreadable, which broke `git status` and `git add` on it. Fixed with `sandbox.filesystem.allowRead: ["./.env.example"]`, a narrower allow that reopens one path inside the denied area.
- **Surprise 2: the hook test harness was unsafe.** Inside the sandbox, `mktemp -d` with no template fell back to a system temp dir it can't write. `$repo` came back empty, and the setup ran `git -C "" init/add/commit`, which points at **the real repository**. The sandbox's write protection on `.git` refused it, and a check of `git log` and `git status` confirmed nothing was committed or staged. Fixed: the harness makes its temp dir explicitly under `$TMPDIR`, aborts if it can't, and runs setup under `set -e`. `post-edit-check.sh` got the same `mktemp` fix. Lesson: test setup that falls back to "current directory" on failure is a hazard; check it before trusting the results.
- **Not yet known:** whether Maven (network to Maven Central) and Testcontainers (Docker socket) work inside the sandbox. That gets settled in F1.

**Written down, not fixed (CLAUDE.md "Limits").** The hooks can still be evaded by globs, escapes, variables and quoting (`cat .en?`, `stripe "config"`, `echo $STRIPE_SECRET_KEY`); the sandbox now covers file reads and the two env vars. Still open: commands excluded from the sandbox (`docker compose config` prints interpolated `.env` values, and it asks), and hooks themselves run outside the sandbox.

**Watch items.** (1) Two edits in parallel can start two post-edit Maven runs on the same `target/`, which could cause flaky failures. Add a lock only if it happens. (2) Spotless rewriting the just-edited file, as noted above.
