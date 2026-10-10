---
paths:
  - "src/**/payments/**"
  - "src/**/webhooks/**"
---

# Payments and webhook rules

These apply to everything under the `payments` and `webhooks` packages, main and test. The `payments-reviewer` subagent checks every diff against them.

- **Every Stripe write call carries an idempotency key.** Pass it with `RequestOptions.builder().setIdempotencyKey(...)`. For `POST /orders`, reuse the client's `Idempotency-Key` header. Why: a retried request must not create a second Checkout Session or charge.
- **Every webhook is signature-verified before anything else.** `Webhook.constructEvent(payload, sigHeader, secret)` is the first thing that touches the raw body: no parsing, logging or DB access before it. On failure return 400 and process nothing. Why: an unverified webhook lets anyone mark orders paid.
- **Webhook processing de-duplicates by event id in the same transaction as the state change.** Insert into `stripe_events` and update `orders`/`resellers` in one `@Transactional` unit; on a duplicate event id, return 200 and do nothing. Why: Stripe delivers at least once, and a dedupe outside the transaction can record the event without applying it, or apply it twice.
- **Connected-account events are matched to records by account id, never by assumption.** Use `event.getAccount()` to find the reseller by `stripe_account_id`. Never fall back to "the only reseller" or an id taken from metadata alone. Why: one account's event must never change another account's records.
- **Test-mode keys only, and no hard-coded amounts in tests without a named constant.** Keys come from the environment (`sk_test_...`, `whsec_...`); the app refuses to start otherwise. Write `ORDER_AMOUNT_CENTS = 2_000`, not a bare `2000`. Why: magic amounts hide fee-calculation mistakes.
- **Never log full Stripe objects.** Log ids and types (`event.getId()`, `event.getType()`, account id, object id), not `event.toJson()` or a whole `Session`/`PaymentIntent`. Why: they can contain customer names, emails and addresses.
