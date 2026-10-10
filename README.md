# connect-prototype

A Stripe Connect prototype ("reseller checkout") built agent-first with Claude Code, under a guardrail layer designed for payments work.

Resellers onboard as connected accounts through Stripe-hosted onboarding. Buyers pay through Stripe Checkout as a destination charge, and the platform keeps a 10% application fee. The platform tracks onboarding, orders and payment status in its own Postgres database, driven by webhooks.

**Stripe test mode only.** The app refuses to start unless the secret key is `sk_test_...` and the webhook secret is `whsec_...`. No real money, no live keys.

## Why this repo is interesting

The app is small on purpose. The point is the way it is built: an AI agent writes the code, and layered controls decide what it can do, check what it did, and leave a record.

- **`.claude/`**: the guardrail layer, checked in and reviewed like any other code.
  - `settings.json`: permissions (deny, ask, allow) plus the OS-level sandbox for shell commands. Stripe keys are unset inside the sandbox, and `.env` can't be read however the path is spelled.
  - `hooks/`: PreToolUse hooks that block edits to `.env` and to committed migrations, and Bash commands that would touch secrets or live mode, each with a plain-English reason. A PostToolUse hook formats and compiles after every edit. All hooks fail closed, and `hooks/tests/test-hooks.sh` covers them (100 cases).
  - `rules/payments.md`: payments rules (idempotency keys, webhook signature checks, de-duplication, account routing) that load only for payments and webhook code.
  - `agents/payments-reviewer.md`: a read-only reviewer subagent that checks every diff against those rules before commit.
- **`NOTES.md`**: the build log. Every guardrail that fired, every review finding, every design decision and mistake, written as it happened. Highlights:
  - the payments-reviewer found that its own read-only git guard could print `.env` through `git diff --no-index`;
  - a second review found that the post-edit hook ran agent-written test code outside the sandbox, so the hook now only formats and compiles;
  - a variable-hidden read of the Stripe CLI config got past the text-matching hook and was stopped by the OS sandbox.
- **`CLAUDE.md`**: the working agreement for the agent, including a table of what is enforced, instructed and reviewed, and an honest list of known limits.
- **`BRIEF.md`**: the original spec the agent worked from.

How the work flows: the agent proposes a plan and I review and edit it before any code is written. Tests come first. Before each commit, the payments-reviewer and `/code-review` run on the diff, and I read both reports and every line of the diff before approving.

## Status

| Step | What | State |
| --- | --- | --- |
| Guardrails | Permissions, sandbox, hooks, rules, reviewer | Done |
| F1a | Spring Boot skeleton, Stripe config guard, `resellers` migration | Done |
| F1b | Reseller onboarding endpoints (Account Links, return-URL refresh) | Next |
| F2 | Checkout with destination charge, application fee, idempotency | Planned |
| F3 | Webhook endpoint: signature check, de-duplication, `account.updated` routing | Planned |

Design notes so far: v1 connected accounts with controller properties (the platform pays Stripe fees and owns losses, Express dashboard). Stripe now recommends Accounts v2 with thin events for new integrations; the trade-off is written up in `NOTES.md`.

## Stack

Java 21, Spring Boot 3.5, stripe-java, PostgreSQL 16, Flyway, `JdbcClient` (no JPA, so transaction boundaries stay explicit), JUnit 5, Testcontainers, Spotless (google-java-format).

## Running it

Prerequisites: JDK 21, Maven, Docker, and the Stripe CLI logged in to a Stripe sandbox.

```bash
cp .env.example .env        # fill in sk_test_... and whsec_... from your Stripe sandbox
set -a; source .env; set +a # export the values to your shell
docker compose up -d        # local Postgres on 127.0.0.1:5432

mvn test                    # unit tests
mvn verify                  # full suite: Testcontainers, Spotless check
bash .claude/hooks/tests/test-hooks.sh   # guardrail hook tests
```

Maven uses a project-local repository (`.mvn/maven.config`), so run it from the repo root.

## Author

Matt Salafia, co-founder and CTO of Carousel Shop AI.
