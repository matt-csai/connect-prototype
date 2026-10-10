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

## 2026-10-10: second guardrail commit (`8382f80`), and a process note

Committed at Matt's direction ("then commit and move on to F1"), with 99/99 hook tests passing inside the sandbox and a secret scan of the staged diff. Process note: the round-2 fixes themselves weren't re-run through `payments-reviewer` and `/code-review` before this commit. The two review rounds covered the earlier versions of these files. The commit message's "Reviewed … (two rounds)" refers to that, not to a review of the final diff. The next review (before the F1 commit) can cover the hooks too, if Matt wants.

## 2026-10-10: F1 decision point, Stripe now recommends Accounts v2

Checked the current Stripe docs before planning F1 (ground rule 7). They differ from the brief:
- Stripe presents **Accounts v2** (`POST /v2/core/accounts`) as the main connected-account API and describes v1 as "limited support". v2 uses `configuration.merchant` (capabilities `card_payments`, `stripe_balance.payouts`), `defaults.responsibilities` (`fees_collector`, `losses_collector`, `requirements_collector`) and `dashboard`, instead of v1's `controller`.
- Onboarding status is per-capability `status` (`active`/`pending`/`restricted`/`unsupported`) plus `requirements.entries`. There's no v1-style `charges_enabled`/`payouts_enabled`/`details_submitted`.
- Account changes arrive as **thin events** (`v2.core.account[configuration.merchant].capability_status_updated`, `v2.core.account.updated`). These carry only ids, are parsed with `StripeClient.parseEventNotification(...)`, and the code then fetches the current object. Checkout and payment events can stay v1 snapshot events. Stripe recommends thin events for new integrations.
- v1 endpoints (Checkout Sessions with `transfer_data.destination`) accept v2 account ids.
- The docs' create example sends `Stripe-Version: 2026-09-30.preview`. Whether v2 accounts need a preview version isn't confirmed yet.

**Decision (Matt): v1 Accounts with controller properties**, as in the brief: platform pays Stripe fees, platform owns losses, Express dashboard, Stripe-hosted onboarding, `account.updated` snapshot events, `charges_enabled`/`payouts_enabled`/`details_submitted`. Reasons: lowest risk within the timebox, and most likely to match an existing Java codebase on the trial ticket. SUMMARY.md will say new integrations should use Accounts v2 with thin events, and what would change.

## 2026-10-10: F1 plan approved, with Matt's changes

- **Testcontainers stays outside the sandbox.** Matt runs `mvn verify` in his own terminal before each commit. Claude runs `mvn test` (unit tests) inside the sandbox. The Docker socket isn't opened to the sandbox. Reason: giving sandboxed commands the Docker socket effectively gives them the machine.
- **The `return_url` endpoint refreshes from Stripe.** It calls `retrieveAccount` and updates the stored `charges_enabled`/`payouts_enabled`/`details_submitted`. `account.updated` (F3) stays the source of truth; this is a convenience refresh when the reseller comes back from onboarding.
- **Insert-first account creation with idempotency-key repair**, approved, with a caveat Matt raised: Stripe keeps idempotency keys for 24 hours. A repair attempted after that window can create a **second connected account** for the same reseller. Acceptable for a prototype; it gets a code comment. **For SUMMARY.md's production section:** before creating, search for an existing account by `metadata.reseller_id`, or reconcile orphaned accounts, rather than relying on the idempotency key past 24 h. This is the kind of edge case to raise on a payments ticket.
- **Also approved:** two commits for F1 (scaffold, then endpoints); `JdbcClient` over JPA, so transaction boundaries stay explicit for F3; and the F1a review also covers the guardrail hooks, which closes the review round they skipped.

## 2026-10-10: F1a, Maven meets the sandbox

- **Versions** (from `repo1.maven.org` metadata; the search.maven.org index was stale and topped out at Boot 3.5.3): Spring Boot **3.5.16** (newest 3.x; Boot 4.1 exists, but the brief says 3.x), stripe-java **34.0.0**, Spotless **3.10.4**. Flyway, Testcontainers and the Postgres driver come from Boot's managed versions.
- **The sandbox blocked writes to `~/.m2`** (`Operation not permitted` on the cached parent POM). I deliberately didn't open `~/.m2` to the sandbox, because unsandboxed Maven runs (Matt's `mvn verify`, the post-edit hook) use that cache, so a sandboxed command could plant a jar that later runs outside the sandbox. Instead, `.mvn/maven.config` sets `-Dmaven.repo.local=.m2/repository`, a project-local cache (git-ignored). The working directory is already sandbox-writable and its code already runs in Matt's `mvn verify`, so this adds no new exposure.
- **Network: the JVM ignores the sandbox proxy.** Maven failed with "Unknown host repo.maven.apache.org". The sandbox routes traffic through an authenticated local proxy set in `HTTPS_PROXY`, and Java and Maven don't read that variable.
- **A guardrail fired on me, correctly.** Investigating the proxy, my `env | grep …` was blocked by `guard-bash.sh` ("env is not allowed"). I didn't work around it; I printed only named variables instead. **My mistake:** that printed the proxy URLs, which embed the sandbox proxy's per-session `user:password`. It's a localhost-only token for this session, not a Stripe key, but I should have masked the userinfo part. Lesson: treat any URL with userinfo as a secret, even "infrastructure" ones.
- **Unsandboxed dependency download, denied.** I asked to run `mvn test` once outside the sandbox (no project Java code existed yet) to fill the cache, and the auto-mode classifier denied it as a safety bypass. I stopped there. Writing Java files would trigger the post-edit hook, which runs Maven **outside** the sandbox (hooks aren't sandboxed), so that would have been a back door around the same denial. No Java files were written. Waiting on Matt.
- **Resolved:** Matt ran `mvn -q verify spotless:check -Dspring-boot.repackage.skip=true` in his own terminal. Repackaging had to be skipped because there was no main class yet. That filled the project-local cache (132 MB), and sandboxed `mvn test` has worked offline since. Pattern from here: dependency downloads happen in Matt's terminal; code runs in the sandbox.

## 2026-10-10: post-edit hook, first live run

- **TDD through the hook.** Writing `StripeConfigTest` and `MigrationsIT` first made the PostToolUse hook report the compile failure ("cannot find symbol StripeConfig") straight back to Claude: the red step, delivered automatically. Each new main class shrank the error list, and after `StripeConfig` the hook was silent (green). Then `mvn test` showed 5/5, and `spotless:check` was clean.
- **The Spotless watch item happened, harmlessly.** The hook reformatted `MigrationsIT.java` and `StripeConfig.java` after they were written. Claude Code noticed ("PostToolUse hook modified … after your edit") and the next edit didn't fail. Still no fix needed.
- **Fake keys in tests are assembled at runtime** (`"sk_" + "live_" + suffix`), so the source never contains a key-shaped literal. That keeps it clean for secret scanners (GitHub push protection), for the `Bash(*sk_live_*)` deny rule and for `guard-bash.sh`, for example when grepping the file.
- **`StripeProperties` overrides `toString()`.** A Java record prints every component by default, which would put the key into any log line that prints the config object. A test checks this.

## 2026-10-10: F1a review (payments-reviewer + /code-review), including the hooks' missed round

**The big one: the post-edit hook was a sandbox bypass (payments-reviewer, blocking).** Hooks run *outside* the sandbox, so `mvn test` in the PostToolUse hook ran Claude-written test code with Matt's full privileges after every edit, with no prompt, and fed the output back to Claude. Test code could read `.env` and print it base64-encoded, which the key-shape redaction wouldn't catch. My earlier "the project-local `.m2` adds no new exposure" reasoning missed this automatic unsandboxed path. **Matt's decision:** the hook now only formats and compiles (`spotless:apply`, `test-compile`). Maven's own plugins run, but no project code does. Claude runs `mvn test` inside the sandbox. A new hook test records the Maven goals the hook calls and fails if `test`, `verify`, `package` or `spring-boot:run` appear. It failed first (it caught `-q test`), then passed: 100/100. Lesson: "where does this code run, and with whose privileges?" applies to the guardrails themselves. A safety hook that executes untrusted code is a hole in the sandbox.

**Also blocking: `docker compose` auto-allowed and unsandboxed.** `docker-compose.yml` is an ordinary editable file, so a compose file that mounts `~/.config/stripe` plus an allow-listed `docker compose up`/`logs` could print the key with no prompt. Fixed: `docker compose` moved from allow to ask, and Matt runs it.

**F1a fixes (tests first; the two webhook-secret tests failed before the fix, then 7/7 passed):**
- **Webhook secret checked at startup** (raised by both reviewers): it must start with `whsec_`, because an empty secret makes signature checks worthless (anyone can compute an HMAC with an empty key). Both checks run in `StripeConfig`'s constructor.
- **`StripeConfigTest` isolated from the shell environment.** Every case sets both properties explicitly, because a `STRIPE_SECRET_KEY` exported in Matt's shell would otherwise make "missing key" tests fail falsely. Failures now assert *which* check failed and that the value isn't echoed. The empty-string case (what `${STRIPE_SECRET_KEY:}` produces) is covered.
- **V1 gained a `set_updated_at()` trigger**, so `updated_at` can't silently stay at the creation time. `MigrationsIT` tests it, along with the `acct_` format check (`''` and `cus_…` are rejected). Done before V1 is committed, because afterwards V1 is immutable.
- `MigrationsIT` keys are assembled at runtime (`@DynamicPropertySource`), matching the convention. Postgres is bound to `127.0.0.1`. `DB_PASSWORD` has no default, so a missing value fails with a clear error. `mvn verify` now runs `spotless:check`. The duplicate failsafe config and the unused `app.base-url` were removed; `app.base-url` comes back with its consumer in F1b.

**Deferred to F3:** out-of-order `account.updated` events could roll a reseller's status backwards. Plan: F3 re-fetches the account from Stripe on every `account.updated` instead of trusting the snapshot, which is Stripe's own guidance for snapshot events, so no ordering column is needed in V1.

**Deferred hook should-fixes (Matt: "F1a + B2 only"), to do later or list as known gaps in SUMMARY.md:**
- `cp .env.example .env` *may* get past `guard-bash.sh`: `grep -o` consumes the boundary character between adjacent names. Unverified, and my own guard blocks testing it from the shell. Add a test case first.
- `rk_live_` (live restricted keys) isn't blocked; only `sk_live_` is.
- `.env` and migration-name matching is case-sensitive, but APFS usually isn't (`.ENV`, `v1__…sql`).
- `post-edit-check.sh` exits 0 silently if `jq` fails.
- Written into CLAUDE.md Limits instead: `export -p`, `declare -p` and `set` dump the environment; heredoc detection can be fooled by multi-line quoted strings.

**Where I disagreed with the reviewer (with evidence):**
- `Read(!.env.example)` isn't a no-op: the permissions docs document `!` carve-outs within a deny list, and writing `.env.example` worked live.
- A compound command containing an excluded program isn't run unsandboxed as a whole: the sandbox docs say every command in the call must match an exclusion.
- The reviewer's git can't be redirected through a tampered `.git/config`, because sandboxed commands can't write `.git/config` (seen live).
