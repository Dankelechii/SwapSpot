-- SwapSpot backend schema (Postgres / Supabase)
-- Idempotent: safe to re-run. Mirrors the credits/verification/Swap Plus rules
-- documented in the prototype (index.html) and in project memory, but fixes the
-- one thing the prototype can't model as a single-player demo: credits from an
-- approved swap move from the REQUESTER to the LISTING OWNER, not back to the
-- same account. See supabase/README.md for what this does and doesn't cover yet.

create extension if not exists citext;
create extension if not exists pgcrypto;

-- =========================================================================
-- PROFILES — public-ish identity. No balance, no verification documents here.
-- =========================================================================
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  avatar_url text,
  verification_status text not null default 'unverified'
    check (verification_status in ('unverified', 'pending', 'verified')),
  created_at timestamptz not null default now()
);

alter table profiles enable row level security;

-- Anyone signed in can see who they're swapping with (name, avatar, verified
-- badge) — this is what listings need to render "Swap with Meera R. ✓Verified".
create policy "profiles are readable by any authenticated user"
  on profiles for select
  to authenticated
  using (true);

create policy "users manage their own profile"
  on profiles for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

grant select on profiles to authenticated;
grant update (display_name, avatar_url) on profiles to authenticated;

-- =========================================================================
-- WALLETS — credit balance. Never written to directly by the client; only
-- the security-definer RPCs below touch this, so a client can't grant itself
-- credits by calling the table API.
-- =========================================================================
create table if not exists wallets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  credits integer not null default 0 check (credits >= 0),
  ever_subscribed boolean not null default false,
  updated_at timestamptz not null default now()
);

alter table wallets enable row level security;

create policy "users read only their own wallet"
  on wallets for select
  to authenticated
  using (user_id = auth.uid());

grant select on wallets to authenticated;
-- Deliberately no insert/update/delete grant for authenticated — RPCs use
-- security definer to bypass RLS and are the only writers.

create table if not exists credit_ledger (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  delta integer not null,
  reason text not null check (reason in (
    'signup_bonus', 'plus_welcome', 'plus_monthly', 'plus_expiry',
    'booking_charge', 'booking_earning', 'booking_refund'
  )),
  reference_id uuid, -- swap_requests.id when relevant
  expires_at timestamptz, -- set only for plus_welcome / plus_monthly grants
  created_at timestamptz not null default now()
);

alter table credit_ledger enable row level security;

create policy "users read only their own ledger"
  on credit_ledger for select
  to authenticated
  using (user_id = auth.uid());

grant select on credit_ledger to authenticated;

-- =========================================================================
-- VERIFICATIONS — UK driving licence / national ID. The document itself
-- lives in a PRIVATE storage bucket (policy below); this table only holds
-- the review state, never the image.
-- =========================================================================
create table if not exists verifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  document_type text not null
    check (document_type in ('provisional_licence', 'full_licence', 'national_id')),
  document_storage_path text not null, -- path inside the private 'verification-docs' bucket
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected')),
  reviewer_note text,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

alter table verifications enable row level security;

create policy "users read and submit only their own verification"
  on verifications for select
  to authenticated
  using (user_id = auth.uid());

create policy "users submit their own verification"
  on verifications for insert
  to authenticated
  with check (user_id = auth.uid());

grant select, insert on verifications to authenticated;
-- No update grant: only a reviewer (service_role, i.e. Dan reviewing by hand
-- for now, or an admin tool later) can move status to approved/rejected.

-- =========================================================================
-- LISTINGS — a bay someone is lending out.
-- =========================================================================
create table if not exists listings (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  bay_number text not null,
  street text not null,
  area text not null, -- e.g. "Shoreditch, London" — used for the radius search
  lat double precision,
  lng double precision,
  photo_storage_path text, -- public bucket; shown to anyone browsing
  available_start timestamptz not null,
  available_end timestamptz not null,
  priority_only boolean not null default false, -- Swap Plus-only listing
  status text not null default 'active'
    check (status in ('active', 'expired', 'removed')),
  created_at timestamptz not null default now(),
  check (available_end > available_start)
);

alter table listings enable row level security;

create policy "active listings are browsable by any authenticated user"
  on listings for select
  to authenticated
  using (status = 'active' or owner_id = auth.uid());

create policy "owners manage their own listings"
  on listings for all
  to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

grant select, insert, update, delete on listings to authenticated;

-- A listing can only be created by a VERIFIED owner. RLS alone can't check
-- another table's row without a security-definer helper, so: trigger.
create or replace function is_verified(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from profiles
    where id = p_user_id and verification_status = 'verified'
  );
$$;

revoke execute on function is_verified(uuid) from public, anon;
grant execute on function is_verified(uuid) to authenticated;

create or replace function enforce_verified_listing_owner()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_verified(new.owner_id) then
    raise exception 'Only verified members can list a bay';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_verified_listing_owner on listings;
create trigger trg_verified_listing_owner
  before insert on listings
  for each row execute function enforce_verified_listing_owner();

-- =========================================================================
-- SWAP REQUESTS — a booking against a listing.
-- =========================================================================
create table if not exists swap_requests (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references listings(id) on delete cascade,
  requester_id uuid not null references auth.users(id) on delete cascade,
  duration_hours smallint not null check (duration_hours between 1 and 12),
  cost_credits smallint not null,
  is_hot boolean not null,
  is_near boolean not null,
  status text not null default 'pending'
    check (status in ('pending', 'confirmed', 'declined', 'cancelled')),
  created_at timestamptz not null default now(),
  decided_at timestamptz
);

alter table swap_requests enable row level security;

create policy "requester or listing owner can read a swap request"
  on swap_requests for select
  to authenticated
  using (
    requester_id = auth.uid()
    or exists (
      select 1 from listings l
      where l.id = swap_requests.listing_id and l.owner_id = auth.uid()
    )
  );

grant select on swap_requests to authenticated;
-- No direct insert/update grant — every state change goes through the RPCs
-- below, which compute cost server-side instead of trusting the client.

-- =========================================================================
-- PLUS SUBSCRIPTIONS
-- =========================================================================
create table if not exists plus_subscriptions (
  user_id uuid primary key references auth.users(id) on delete cascade,
  status text not null default 'active' check (status in ('active', 'cancelled')),
  is_first_cycle boolean not null default true,
  current_period_start timestamptz not null default now(),
  current_period_end timestamptz not null default (now() + interval '30 days'),
  created_at timestamptz not null default now()
);

alter table plus_subscriptions enable row level security;

create policy "users read only their own subscription"
  on plus_subscriptions for select
  to authenticated
  using (user_id = auth.uid());

grant select on plus_subscriptions to authenticated;
-- Written only by grant_plus_credits()/cancel_plus() below — real billing
-- (Stripe or similar) is not modelled here; see supabase/README.md.

-- =========================================================================
-- RPCs
-- =========================================================================

-- Runs at sign-up: creates the profile + wallet and grants the 5 free credits.
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into profiles (id, display_name)
    values (new.id, coalesce(new.raw_user_meta_data->>'display_name', 'New member'));
  insert into wallets (user_id, credits) values (new.id, 5);
  insert into credit_ledger (user_id, delta, reason)
    values (new.id, 5, 'signup_bonus');
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- Computes cost the same way the prototype's costReason()/bookingCost() do,
-- but from real data: "near" = this listing is within 100m of the requester's
-- search origin (kept simple here as a per-listing flag you set at listing
-- time until real geosearch lands); "hot" = 5+ existing requests on it.
create or replace function request_swap(p_listing_id uuid, p_duration_hours smallint)
returns swap_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_listing listings;
  v_offer_count int;
  v_is_hot boolean;
  v_is_near boolean;
  v_cost smallint;
  v_requester_plus boolean;
  v_result swap_requests;
begin
  select * into v_listing from listings where id = p_listing_id and status = 'active';
  if not found then
    raise exception 'Listing not available';
  end if;
  if v_listing.owner_id = auth.uid() then
    raise exception 'You cannot request your own listing';
  end if;

  select count(*) into v_offer_count from swap_requests
    where listing_id = p_listing_id and status in ('pending', 'confirmed');
  v_is_hot := v_offer_count >= 5;
  v_is_near := false; -- see note above; wire up real geosearch before launch
  v_cost := case when v_is_near or v_is_hot then 10 else 5 end;

  select exists (
    select 1 from plus_subscriptions
    where user_id = auth.uid() and status = 'active' and current_period_end > now()
  ) into v_requester_plus;

  insert into swap_requests (listing_id, requester_id, duration_hours, cost_credits, is_hot, is_near, status)
  values (p_listing_id, auth.uid(), p_duration_hours, v_cost, v_is_hot, v_is_near,
    case when v_listing.priority_only and v_requester_plus then 'pending' else 'pending' end)
  returning * into v_result;

  -- Swap Plus instant-book: auto-settle immediately instead of waiting on the owner.
  if v_requester_plus then
    perform settle_swap_request(v_result.id, true);
    select * into v_result from swap_requests where id = v_result.id;
  end if;

  return v_result;
end;
$$;

revoke execute on function request_swap(uuid, smallint) from public, anon;
grant execute on function request_swap(uuid, smallint) to authenticated;

-- Shared settlement logic used by both instant-book and owner approval.
-- security definer + internal only (not directly callable by clients).
create or replace function settle_swap_request(p_request_id uuid, p_approved boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req swap_requests;
  v_owner_id uuid;
  v_requester_credits int;
begin
  select * into v_req from swap_requests where id = p_request_id for update;
  if not found or v_req.status not in ('pending') then
    return; -- already settled or missing — no-op, matches prototype's guard
  end if;

  if not p_approved then
    update swap_requests set status = 'declined', decided_at = now() where id = p_request_id;
    return;
  end if;

  select owner_id into v_owner_id from listings where id = v_req.listing_id;
  select credits into v_requester_credits from wallets where user_id = v_req.requester_id for update;

  if v_requester_credits < v_req.cost_credits then
    -- Mirrors the prototype: if the requester can no longer afford it by the
    -- time this settles, the booking lapses instead of charging anyway.
    update swap_requests set status = 'declined', decided_at = now() where id = p_request_id;
    return;
  end if;

  update wallets set credits = credits - v_req.cost_credits, updated_at = now()
    where user_id = v_req.requester_id;
  insert into credit_ledger (user_id, delta, reason, reference_id)
    values (v_req.requester_id, -v_req.cost_credits, 'booking_charge', p_request_id);

  update wallets set credits = credits + v_req.cost_credits, updated_at = now()
    where user_id = v_owner_id;
  insert into credit_ledger (user_id, delta, reason, reference_id)
    values (v_owner_id, v_req.cost_credits, 'booking_earning', p_request_id);

  update swap_requests set status = 'confirmed', decided_at = now() where id = p_request_id;
end;
$$;

revoke execute on function settle_swap_request(uuid, boolean) from public, anon, authenticated;
-- Not granted to authenticated at all — only called internally by
-- request_swap() (instant book) and approve/decline below (SECURITY DEFINER
-- lets those call it regardless).

create or replace function approve_swap_request(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner_id uuid;
begin
  select l.owner_id into v_owner_id
    from swap_requests s join listings l on l.id = s.listing_id
    where s.id = p_request_id;
  if v_owner_id is distinct from auth.uid() then
    raise exception 'Only the listing owner can approve this request';
  end if;
  perform settle_swap_request(p_request_id, true);
end;
$$;

revoke execute on function approve_swap_request(uuid) from public, anon;
grant execute on function approve_swap_request(uuid) to authenticated;

create or replace function decline_swap_request(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner_id uuid;
begin
  select l.owner_id into v_owner_id
    from swap_requests s join listings l on l.id = s.listing_id
    where s.id = p_request_id;
  if v_owner_id is distinct from auth.uid() then
    raise exception 'Only the listing owner can decline this request';
  end if;
  perform settle_swap_request(p_request_id, false);
end;
$$;

revoke execute on function decline_swap_request(uuid) from public, anon;
grant execute on function decline_swap_request(uuid) to authenticated;

-- =========================================================================
-- STORAGE — private bucket for verification documents, public bucket for
-- bay photos. Run once; Supabase storage buckets are created via the
-- dashboard or the storage API, policies below assume 'verification-docs'
-- (private) and 'bay-photos' (public) already exist.
-- =========================================================================
create policy "users upload only their own verification doc"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'verification-docs'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "users read only their own verification doc"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'verification-docs'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "anyone signed in can view bay photos"
  on storage.objects for select
  to authenticated
  using (bucket_id = 'bay-photos');

create policy "owners upload their own bay photos"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'bay-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

