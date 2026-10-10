-- V1: resellers, one row per Stripe connected account.
-- Once committed, this file is immutable (protect-files.sh enforces it). Changes go in V2+.

create table resellers (
    -- Primary key: its index serves GET /resellers/{id} and the orders.reseller_id foreign key (V2).
    id                  uuid        primary key,
    display_name        text        not null,
    -- Nullable on purpose: the row is inserted before the Stripe account is created, so a failed
    -- Account.create leaves a row we can repair with the same idempotency key (see F1b).
    stripe_account_id   text,
    -- Mirrors of the Stripe account's status, updated from account.updated webhooks (F3) and on
    -- return from onboarding. Stripe is the source of truth; these are a cache.
    charges_enabled     boolean     not null default false,
    payouts_enabled     boolean     not null default false,
    details_submitted   boolean     not null default false,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now(),

    -- Unique: one connected account belongs to exactly one reseller. The unique constraint's
    -- index also serves the hot lookup in F3, where account.updated events are matched to a
    -- reseller by event.account (never by assumption). Postgres treats NULLs as distinct, so
    -- several not-yet-created accounts can coexist.
    constraint resellers_stripe_account_id_key unique (stripe_account_id),
    constraint resellers_stripe_account_id_format check (stripe_account_id like 'acct\_%')
);

-- No index on display_name: nothing looks resellers up by name.

-- Keep updated_at honest without relying on every UPDATE to remember it. Shared by later tables.
create function set_updated_at() returns trigger
language plpgsql as $$
begin
    new.updated_at := now();
    return new;
end;
$$;

create trigger resellers_set_updated_at
    before update on resellers
    for each row execute function set_updated_at();
