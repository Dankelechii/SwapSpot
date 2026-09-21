# SwapSpot backend

`schema.sql` is a ready-to-apply Postgres schema for turning the prototype into a
real, multi-user backend on Supabase. It is **not yet applied anywhere** — see
"Getting this live" below.

## What it does

- **Accounts** — `profiles` (public-ish: name, avatar, verification badge) and
  `wallets` (private: credit balance) are separate tables on purpose, same
  reasoning as the VamOs backend: a listing needs to show who you're swapping
  with without leaking their balance to every browser on the page.
- **Credits are a ledger, not just a number.** `credit_ledger` records every
  grant and charge; `wallets.credits` is a cached total kept in sync by the
  RPCs. This is what the prototype's "credit log" already shows in the UI —
  the real backend just makes it the source of truth instead of an in-memory
  array.
- **Every credit-moving action goes through a `security definer` RPC**
  (`request_swap`, `approve_swap_request`, `decline_swap_request`), never a
  direct table write. A client holding a valid session token still can't
  grant itself credits or approve its own request — Postgres enforces it, not
  app code.
- **Swap cost and "hot"/"near" status are computed server-side** at request
  time, from the real count of existing requests on that listing — not
  trusted from whatever the client sends. The prototype (fairly, for a
  demo) trusts the browser; a real backend can't.
- **One real fix vs. the prototype:** in the single-player demo, an approved
  swap both charges *and* credits the same account, because there's only one
  real user in a browser tab. Here, credits move from the requester's wallet
  to the **listing owner's** wallet — that's what "Swap with Meera R." in the
  UI actually implies once two different people are involved.
- **Verification documents never sit in a queryable table.** `verifications`
  holds only the review state; the actual driving-licence/ID photo goes in a
  private Storage bucket (`verification-docs`) that only its owner can read,
  policy included at the bottom of the file.

## Deliberately not done yet

- **Payments.** `plus_subscriptions` models the *data* (status, billing
  period, first-cycle vs. renewal credit amount) but nothing here takes an
  actual £1.99. That needs Stripe (or similar) wired to a webhook that calls
  a `grant_plus_credits()` RPC (not yet written) on each successful renewal,
  and a cron/scheduled function to expire *unused* monthly Plus credits at
  period end — the app already has the `expires_at` column on
  `credit_ledger` to support that, it just isn't enforced by a job yet.
- **Real geosearch.** `is_near` is stubbed to `false` in `request_swap()`.
  `listings` has `lat`/`lng` columns ready for it, but computing "within
  100m of the requester's search" needs either PostGIS or a simpler
  Haversine calculation once the app knows the requester's location —
  the prototype fakes this with a static `mi` field per listing.
- **A verification review UI.** Right now, moving a `verifications` row from
  `pending` to `approved`/`rejected` needs the `service_role` key (i.e. done
  by hand from the Supabase dashboard, or a small internal tool later) —
  there's no RLS policy letting anyone else do it, on purpose.
- **Listing expiry.** `status = 'expired'` exists as a value but nothing
  flips it yet; needs a scheduled job comparing `available_end` to `now()`.

## Getting this live

This schema has **not been applied to any Supabase project.** The Supabase
connection available when this was written is already bound to VamOs's
production project — running SwapSpot's schema there would mix two unrelated
apps' data (and auth users) in one database, so it deliberately wasn't done.

To make this real:

1. Create a **new, separate** Supabase project for SwapSpot at
   supabase.com/dashboard (a couple of minutes — pick an org, a name, a
   region, a database password).
2. In its SQL Editor, paste and run `schema.sql` (or `supabase db push` with
   the Supabase CLI once a local project is linked).
3. Create the two Storage buckets referenced by the policies at the bottom
   of the file: `verification-docs` (private) and `bay-photos` (public).
4. Grab the project URL and the `anon`/publishable key from Settings → API,
   and wire them into the front end the same way VamOs does it — a config
   file that no-ops to local-only behaviour when the credentials are absent,
   so a broken or missing backend never breaks the app, it just degrades to
   the current prototype.

Once that project exists, a future session with a Supabase connector pointed
at *that* project (rather than VamOs's) can apply and iterate on this schema
directly.

