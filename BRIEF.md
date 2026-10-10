# Brief: Stripe Connect prototype ("reseller checkout")

**For:** Claude Code, working with Matt
**Timebox:** about 4 hours total (3–4 for the app, about 30 minutes for the guardrail layer). Stop at the definition of done; do not gold-plate.
**Purpose:** Hands-on practice with Stripe Connect, Postgres migrations and agent-first guardrails, ahead of a paid trial on a Stripe Connect ticket (Java Spring Boot, Postgres). The finished run also becomes a 2–3 minute screen recording of the workflow.

---

## 1. Ground rules (read first, follow throughout)

1. **Isolated project.** A new, standalone repo at `~/projects/connect-prototype` (outside `~/github`, so the CSAI workspace CLAUDE.md does not load). Do NOT touch the Carousel Shop AI codebase, its Stripe account, its webhooks or its cloud projects. The CSAI guardrails plugin is switched off here with `.claude/csai-guardrails.json` (`{"enabled": false}`); this repo gets its own guardrail layer (section 1A).
2. **Stripe test mode only.** Use a Stripe sandbox or test-mode keys (`sk_test_...`, `whsec_...`). The app must refuse to start if the secret key does not begin with `sk_test_`.
3. **No secrets in code, prompts or git.** Keys come from environment variables or a local `.env` that is git-ignored. Provide a `.env.example` with placeholder values only. Never print keys in logs or test output.
4. **Plan before code.** Start in plan mode and propose a plan. Matt reviews and edits it before any code is written.
5. **Tests first.** For each feature, write the failing test, then the implementation, then run the full suite.
6. **Small, reviewable diffs.** One feature per commit. Pause after each one so Matt can review the diff before moving on.
7. **Use current Stripe docs.** Stripe's Connect APIs evolve (account types and controller settings, Accounts v2). Check the current docs for the recommended way to create a platform-controlled, Stripe-hosted-onboarding connected account. If the recommendation differs from this brief, say so and propose the current approach.
8. **Write a `CLAUDE.md`** for the repo that captures these rules (keep it short, under ~100 lines). This is part of the deliverable.
9. **Enforce, don't just instruct.** Rules that must always hold go in settings, hooks and review agents (section 1A), not only in CLAUDE.md.

## 1A. Guardrail layer (build this FIRST, before any app code)

This is the enforcement layer a cautious team needs to trust agents. Build it, show it working, then build the app under it. Check all of it into git under `.claude/`.

1. **`.claude/settings.json` permissions** (project-level, checked in):
   - deny reading or editing `.env` and `.env.*` (allow `.env.example`)
   - deny `git push` (Matt pushes)
   - deny `rm -rf` and any command containing a live key prefix (`sk_live_`)
   - require approval for other shell commands not on an allow list; allow the common safe ones (build, test, docker compose, Stripe CLI in test mode)
   Check the current permissions docs for exact syntax: https://code.claude.com/docs/en/permissions

2. **A `PreToolUse` hook** (`.claude/hooks/protect-files.sh`, registered in settings) that blocks Edit/Write on:
   - `.env` and `.env.*` (except `.env.example`)
   - any Flyway migration that has already been committed (`src/main/resources/db/migration/V*.sql` tracked in git). New migrations are allowed; applied ones are immutable.
   - The hook prints a clear reason when it blocks. Check the hooks docs for the input format and exit codes: https://code.claude.com/docs/en/hooks-guide

3. **A `PostToolUse` hook** that runs the formatter and the fast unit tests after edits to `src/**`, and feeds failures back to Claude. Keep it fast; skip Testcontainers tests here.

4. **A path-scoped rule file**, `.claude/rules/payments.md`, that loads only when working under the payments and webhook packages. It should say:
   - every Stripe write call carries an idempotency key;
   - every webhook is signature-verified before anything else;
   - webhook processing de-duplicates by event id in the same transaction as the state change;
   - connected-account events are matched to records by account id, never by assumption;
   - test-mode keys only, and no amounts hard-coded in tests without a named constant;
   - never log full Stripe objects (they can contain personal data).

5. **A `payments-reviewer` subagent** (`.claude/agents/payments-reviewer.md`) with read-only tools (no edit, no shell writes). Its job is to review the current diff against the payments rules and report findings as: blocking / should-fix / fine, with file and line. It does not fix anything; Matt decides.

6. **Review step before every commit:** run the `payments-reviewer` subagent and the built-in `/code-review` on the diff. Matt reads both, then approves the commit.

7. **Prove the guardrails work** (and capture this for the recording):
   - ask Claude to "add my Stripe key to .env" → permission or hook blocks it with a reason
   - ask Claude to edit an already-committed migration → hook blocks it, Claude proposes a new migration instead
   - introduce a deliberate bug (remove the signature check) → the payments-reviewer flags it as blocking

## 2. The scenario

Carousel Shop–shaped, but standalone:
- A **reseller** (connected account) onboards through the platform with Stripe-hosted onboarding.
- A **buyer** purchases an item from that reseller.
- The payment goes to the reseller via a **destination charge**. The platform keeps an **application fee** (for example, 10%).
- The platform tracks onboarding status, orders and payment status in **its own Postgres database**, driven by **webhooks**.

## 3. Stack

- Java 17 or 21 (whichever JDK is installed; CSAI services use 17), Spring Boot 3.x, the official `stripe-java` SDK
- PostgreSQL in Docker (docker-compose for local runs)
- Flyway for schema migrations
- JUnit 5 and Testcontainers (Postgres) for tests
- Stripe CLI for local webhook forwarding and triggers
- A minimal UI is optional; a few REST endpoints plus Stripe-hosted pages are enough.

## 4. Data model (Flyway migrations)

Write explicit, versioned migrations (`V1__...sql`, `V2__...sql`). No auto-DDL.

- `resellers`: id (uuid PK), display_name, stripe_account_id (unique), charges_enabled, payouts_enabled, details_submitted, created_at, updated_at
- `orders`: id (uuid PK), reseller_id (FK), amount_cents, currency, application_fee_cents, status (`pending`, `paid`, `failed`, `refunded`), stripe_checkout_session_id (unique), stripe_payment_intent_id (unique, nullable), idempotency_key (unique), created_at, updated_at
- `stripe_events`: event_id (PK), type, account_id (nullable; set for connected-account events), received_at, processed_at

Index the foreign key and any column used in lookups. Explain each index choice in the migration as a comment.

## 5. Features (in order)

### F1. Reseller onboarding
- `POST /resellers` with `{ displayName }` creates the connected account in Stripe, stores it, and returns an onboarding link (Account Link) to Stripe-hosted onboarding.
- `GET /resellers/{id}` returns status (charges_enabled, payouts_enabled, details_submitted).
- `GET /resellers/{id}/onboarding-link` returns a fresh link (links expire).

### F2. Checkout with a platform fee
- `POST /orders` with `{ resellerId, amountCents, currency }` and an `Idempotency-Key` header.
  - Reject if the reseller cannot accept charges yet (charges_enabled = false).
  - Create a Stripe Checkout Session as a **destination charge** to the reseller with an **application fee** of 10%.
  - Pass the same idempotency key to Stripe. A repeated request with the same key must return the same order and must not create a second Checkout Session.
  - Return the Checkout URL.

### F3. Webhooks (the heart of it)
- One endpoint, `POST /webhooks/stripe`, that:
  - **Verifies the signature** with the webhook secret; returns 400 on failure and processes nothing.
  - **De-duplicates** by `event_id` in `stripe_events`, inside the same database transaction as the state change. A redelivered event is acknowledged (200) but not processed twice.
  - Handles at least:
    - `checkout.session.completed`: mark the order `paid` and store the payment intent id
    - `payment_intent.payment_failed`: mark `failed`
    - `account.updated` (a connected-account event): update the reseller's charges_enabled, payouts_enabled and details_submitted
    - `charge.refunded`: mark `refunded`
  - Records which account an event belongs to (platform vs. connected account) and never applies one account's event to another's records.
  - Returns 200 quickly; unknown event types are logged and acknowledged.

### F4. Refund (stretch, only if time allows)
- `POST /orders/{id}/refund` refunds the charge, reverses the transfer and refunds the application fee. Explain in a comment what each option does to who ends up paying.

## 6. Tests (must exist and pass)

1. Migrations apply cleanly to an empty Postgres (Testcontainers).
2. Startup fails with a non-test secret key.
3. `POST /orders` with the same Idempotency-Key twice → one order, one Stripe session.
4. `POST /orders` for a reseller with charges_enabled = false → 409, nothing created.
5. Webhook with a bad signature → 400, no state change.
6. The same webhook event delivered twice → state changes once, and `stripe_events` has one row.
7. `account.updated` for reseller A never changes reseller B.
8. `checkout.session.completed` → order `paid`, with the fee amount recorded.
9. The protect-files hook script, run directly with sample inputs, blocks `.env` and committed migrations and allows a new migration (a small shell or JUnit test is fine).

Mock the Stripe API in unit tests. Use the Stripe CLI for the manual end-to-end run below.

## 7. Manual end-to-end run (for the recording)

0. Guardrails demo (about 45 seconds): show `.claude/` (settings, hooks, rules, agents), then the three "prove it works" moments from section 1A, step 7.
1. `docker compose up` for Postgres, then start the app with test keys from `.env`.
2. `stripe listen --forward-to localhost:8080/webhooks/stripe --forward-connect-to localhost:8080/webhooks/stripe`
3. Create a reseller and complete Stripe-hosted onboarding with Stripe's test data.
4. Watch `account.updated` flip charges_enabled to true.
5. Create an order, pay with test card 4242 4242 4242 4242, and watch the order go to `paid`.
6. In the Stripe dashboard (test mode), show the destination charge, the transfer to the connected account and the application fee.
7. Resend the same event from the dashboard or CLI and show it is ignored the second time.

## 8. Definition of done

- F1–F3 work end to end in test mode; F4 only if time allows
- All tests in section 6 pass
- Guardrail layer from section 1A checked in under `.claude/`, with the three "prove it works" checks demonstrated
- `CLAUDE.md`, `.env.example`, `.gitignore` (covering `.env`) and a short `README.md` with run steps
- `SUMMARY.md`, half a page in Matt's voice, covering:
  - what was built;
  - which charge type was chosen, and why;
  - how duplicate webhooks and retries are handled;
  - the guardrail layer: what is enforced (settings, hooks) vs. instructed (CLAUDE.md, rules) vs. reviewed (subagent, /code-review), and why;
  - what would change for production (e.g. separate Connect webhook endpoint and secret, retries and alerting, reconciliation against Stripe, refunds and disputes policy, negative balances)
- No secrets anywhere in the git history (check before finishing)

## 9. Out of scope

- Real money, live mode or real business details
- Production deployment
- Frontend polish
- Subscriptions (already covered by Carousel Shop AI)
- Separate charges and transfers / multi-party splits: mention in SUMMARY.md as the next step, don't build

## 10. What Matt wants to learn (keep these in mind and explain as you go)

- The Connect vocabulary in practice: connected accounts, account links, capabilities and requirements, destination charges, application fees, transfers, payouts
- How connected-account webhook events differ from platform events, and how to route them safely
- Postgres schema, migration and index decisions, and transaction boundaries for webhook processing
- Where agent-written payments code most often goes wrong, and what review should catch
- How to roll a guardrail layer like this out to a cautious team: what goes in a shared plugin vs. each repo
