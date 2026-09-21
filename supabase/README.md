# SwapSpot backend

`schema.sql` is the Postgres schema behind SwapSpot's real backend, live on its
own dedicated Supabase project (separate from VamOs- see "Getting this live"
below for how that happened). `index.html` is wired to it: sign-up/sign-in,
browsing real listings, sending and approving swap requests, and credits all
go through this database now. Payments and the verification review UI are
still not connected- see "Deliberately not done yet".

## What it does

- **Accounts**- `profiles` (public-ish: name, avatar, verification badge) and
  `wallets` (private: credit balance) are separate tables on purpose, same
  reasoning as the VamOs backend: a listing needs to show who you're swapping
  with without leaking their balance to every browser on the page.
- **Credits are a ledger, not just a number.** `credit_ledger` records every
  grant and charge; `wallets.credits` is a cached total kept in sync by the
  RPCs. This is what the prototype's "credit log" already shows in the UI-
  the real backend just makes it the source of truth instead of an in-memory
  array.
- **Every credit-moving action goes through a `security definer` RPC**
  (`request_swap`, `approve_swap_request`, `decline_swap_request`), never a
  direct table write. A client holding a valid session token still can't
  grant itself credits or approve its own request- Postgres enforces it, not
  app code.
- **Swap cost and "hot"/"near" status are computed server-side** at request
  time, from the real count of existing requests on that listing- not
  trusted from whatever the client sends.
- **One real fix vs. the old single-player demo:** an approved swap now moves
  credits from the requester's wallet to the **listing owner's** wallet-
  that's what "Swap with Meera R." in the UI actually implies once two
  different people are involved.
- **Verification documents never sit in a queryable table.** `verifications`
  holds only the review state; the actual driving-licence/ID photo goes in a
  private Storage bucket (`verification-docs`) that only its owner can read.
  In practice, `index.html` currently uses the **`bay-photos`** bucket
  (public) for the "prove your parking spot" upload instead- see the
  verification note below.
- **Three read-side RPCs make the frontend possible under RLS**:
  `browse_listings()`, `my_swap_requests()`, and `my_listing_requests()`.
  These exist because `swap_requests`' RLS (requester or listing owner only)
  correctly hides individual requests from other members, so the home feed's
  "N offers" badge and the two "my requests" screens each need a
  `security definer` function that returns an aggregate or an already-scoped
  join, rather than a query the client could run directly under RLS.

## Verification is honestly half-wired, on purpose

`index.html`'s "prove your parking spot" step uploads a photo to the public
`bay-photos` Storage bucket (folder-scoped to the uploader, same as the
storage policy already in this file requires). But nothing in this schema
lets a client set `profiles.verification_status` to `verified`- the `update`
grant on `profiles` only covers `display_name` and `avatar_url`- and the
`verifications` table's `document_type` values (`provisional_licence` /
`full_licence` / `national_id`) don't actually match "a photo of an empty
bay", so the app doesn't insert into it. That means:

- A new member can upload a photo and see "Pending review" in the app.
- Nobody actually gets verified until **Dan flips `profiles.verification_status`
  to `'verified'` by hand**, in the Table Editor, after looking at what they
  uploaded (Storage → `bay-photos` → their user-id folder).
- Only a verified owner can list a bay- `enforce_verified_listing_owner()`
  (the trigger below) rejects the insert otherwise. So a brand-new tester who
  wants to test *listing* a bay (not just browsing/requesting one) needs Dan
  to approve them first.

This was a deliberate call over building a fake self-approval flow that would
misrepresent what "verified" means once real people are using it. A proper
fix- matching document types to what's actually collected, and/or a small
admin review screen- is future work, not done here.

## Deliberately not done yet

- **Payments.** `plus_subscriptions` models the *data* (status, billing
  period, first-cycle vs. renewal credit amount) but nothing here takes an
  actual £1.99. That needs Stripe (or similar) wired to a webhook that calls
  a `grant_plus_credits()` RPC (not yet written) on each successful renewal,
  and a cron/scheduled function to expire *unused* monthly Plus credits at
  period end- the app already has the `expires_at` column on
  `credit_ledger` to support that, it just isn't enforced by a job yet.
  Because of this, `request_swap()`'s Swap Plus instant-book path never
  actually triggers today- nobody can have a real `plus_subscriptions` row.
- **Real geosearch.** `is_near` is stubbed to `false` in `request_swap()`.
  The frontend computes a real (if fixed-origin) distance client-side via
  the Haversine formula against a hardcoded "Shoreditch High St" reference
  point, since there's no user geolocation wired up yet.
- **A verification review UI.** See above- it's a Table Editor edit by hand
  for now.
- **Listing expiry.** `status = 'expired'` exists as a value but nothing
  flips it yet; needs a scheduled job comparing `available_end` to `now()`.

## Getting this live

This schema is **applied and live** on a dedicated Supabase project for
SwapSpot (kept separate from VamOs's production project on purpose, so the
two apps' data and auth users never mix). The project's URL and publishable
key are hardcoded in `index.html`- they're safe to expose client-side by
design (that's what RLS + these RPCs are for).

A demo-owner account (`swapspot.demo.owner@gmail.com`, created via the Auth
REST API- not one of Dan's personal accounts) owns the six seeded bays that
show up in the feed on first load, so the app never looks empty for a new
tester. It was marked `verified` by hand the same way any real member would
be.

To make further schema changes: open the project's SQL Editor at
supabase.com/dashboard and paste in whatever changed, or use a Supabase MCP
connection pointed at *this* project (ref `woxumfxyghqpesooobjq`) once one is
available in a future session.
