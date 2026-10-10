# connect-prototype

Stripe Connect practice project ("reseller checkout"): Java 21, Spring Boot 3, stripe-java, Postgres, Flyway, JUnit 5 and Testcontainers. The full spec is in `BRIEF.md`.

Keep NOTES.md current: append an entry for every guardrail block, design decision or surprise.

## Ground rules

- **Isolated.** Never touch the Carousel Shop AI codebase, its Stripe account, its webhooks or its cloud projects. The CSAI guardrails plugin is off here (`.claude/csai-guardrails.json`); this repo has its own layer in `.claude/`.
- **Stripe test mode only.** Keys are `sk_test_...` / `whsec_...`. The app refuses to start with any other secret key.
- **Stripe CLI:** every command includes `--project-name connect-prototype` (enforced by `guard-bash.sh`), e.g. `stripe trigger --project-name connect-prototype checkout.session.completed`. **Matt runs `stripe listen` himself** in his own terminal, because it prints the `whsec_` signing secret; `stripe listen` always asks.
- **No secrets in code, prompts, logs, test output or git.** Keys come from env vars or the git-ignored `.env`, which Claude never reads or writes. Placeholders go in `.env.example`.
- **Plan before code.** Propose a plan; Matt reviews and edits it before code is written.
- **Tests first.** Failing test, then the implementation, then the full suite.
- **Small diffs.** One feature per commit. Stop after each so Matt can review.
- **Current Stripe docs.** Check them for Connect APIs; if they differ from `BRIEF.md`, say so and propose the current approach.
- **Never push.** Matt pushes.

## Code conventions

- Base package `dev.matt.connect`. Payments code lives under `payments/`, webhook code under `webhooks/`; `.claude/rules/payments.md` loads for both.
- Migrations: `src/main/resources/db/migration/V<n>__<description>.sql`. Once committed, a migration is immutable; changes go in a new one. No auto-DDL.
- Unit tests: `*Test.java` (Surefire, `mvn test`). Claude runs them inside the sandbox after each change; the post-edit hook only compiles. Testcontainers and Spring-context tests: `*IT.java` (Failsafe, `mvn verify`).
- Formatting: Spotless with google-java-format (`mvn spotless:apply`).

## Commands

- Fast tests: `mvn test`. Full suite including Testcontainers: `mvn verify`.
- Hook tests: `bash .claude/hooks/tests/test-hooks.sh`.
- Postgres: `docker compose up -d` (Matt runs it; `docker compose` always asks and runs outside the sandbox).
- Maven uses a project-local cache (`.mvn/maven.config`: `.m2/repository`, relative to the directory Maven runs in), so always run Maven from the repo root. Dependency downloads happen in Matt's terminal; the sandbox has no route to Maven Central.
- Under the sandbox, Maven's first download needs Maven Central approved as a network domain. Testcontainers needs the Docker socket, which stays out of the sandbox: Matt runs `mvn verify`.

## Before every commit

1. Run `mvn test` and the hook tests. Ask Matt to run `mvn verify` (Testcontainers) in his own terminal; the Docker socket stays out of the sandbox.
2. Run the `payments-reviewer` subagent on the diff.
3. Run `/code-review` on the diff.
4. Show Matt both reports and stop. Matt reads them and approves the commit (`git commit` always asks).
5. Write the commit message as a quoted heredoc (`git commit -F - <<'EOF'`). The Bash guard skips quoted heredoc bodies, so the message can mention `.env`; a `-m "…"` message that does gets blocked.

## Guardrail layer

| Kind | Where | What it covers |
| --- | --- | --- |
| Enforced (OS) | `sandbox` in `.claude/settings.json` | Bash commands and their child processes run in the macOS sandbox. The `Read(...)` denies become OS-level read blocks: `.env`, `.env.*` and `~/.config/stripe` can't be read however the path is spelled (globs, variables, scripts). `STRIPE_SECRET_KEY`/`STRIPE_WEBHOOK_SECRET` are unset for sandboxed commands. `docker compose` and `stripe` run outside it. |
| Enforced | `.claude/settings.json` permissions | Claude's Read/Edit tools are denied `.env`/`.env.*` (not `.env.example`) and `~/.config/stripe/**`. Bash rules deny `git push`, `rm -rf`, live keys, `stripe --live`. Ask for `git commit`, `rm`, `stripe listen`, `docker compose`. Allow-list for Maven build and test, and profile-scoped Stripe CLI. Bypass mode disabled. |
| Enforced | `.claude/hooks/protect-files.sh` (PreToolUse) | Blocks Edit/Write on `.env`/`.env.*` and on committed migrations. |
| Enforced | `.claude/hooks/guard-bash.sh` (PreToolUse) | Blocks Bash commands that name `.env`/`.env.*` or `~/.config/stripe`, `stripe config`, `env`/`printenv`, live keys, and forms the deny rules miss (`git -C . push`, `/bin/rm -Rf`); requires the Stripe CLI profile. Gives a clear reason before the sandbox would. |
| Enforced | `.claude/hooks/post-edit-check.sh` (PostToolUse) | Formats and compiles (`spotless:apply`, `test-compile`) after edits to `src/**/*.java`; failures and timeouts (240 s budget) are fed back. Never runs tests or the app: hooks run outside the sandbox, so project code must not run there. |
| Instructed | `CLAUDE.md`, `.claude/rules/payments.md` | Ground rules; payments rules load only under `payments/` and `webhooks/`. |
| Reviewed | `payments-reviewer` subagent, `/code-review` | Diff review before each commit. The reviewer's Bash is limited by `readonly-git.sh` to `git diff/status/log/show`, allow-listed flags, and plain paths inside the repo other than `.env` (no quotes, escapes, globs or braces). Matt decides. |

All hooks block (exit 2) on any internal error; none can fail open.

**Limits.** The hooks match command text, so globs, escapes, variables and quoting (`cat .en?`, `stripe "config"`, `echo $STRIPE_SECRET_KEY`) can get past them. The sandbox is the control for file reads and env vars, the hooks are the first line and the explanation. Still open: commands excluded from the sandbox (`docker compose` and `stripe` run unsandboxed; `docker compose` always asks, because a compose file can mount and print any file), Claude's own Read tool (covered by permission rules, not the sandbox), and hooks, which run outside the sandbox (so the post-edit hook only formats and compiles). `export -p`, `declare -p` and `set` can dump the environment of an unsandboxed command; heredoc detection can be fooled by multi-line quoted strings. If a guardrail blocks something, don't work around it: explain what was blocked, propose the allowed alternative (e.g. a new migration), and log it in NOTES.md.
