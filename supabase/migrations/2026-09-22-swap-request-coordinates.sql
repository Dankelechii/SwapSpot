-- Adds area, lat and lng to my_swap_requests().
--
-- Why: the app can hand a requested bay off to Google Maps, Apple Maps or
-- Waze, but the RPC never returned coordinates, so "Navigate to this bay"
-- had nothing precise to aim at and fell back to a street-name query.
-- With this applied, the hand-off drops a pin on the bay itself.
--
-- Safe to run on a live project. It replaces one read-only SECURITY DEFINER
-- function and re-applies its grants. No table, policy or data is touched,
-- and the three added columns come from a listing the caller is already
-- entitled to see through this same function.
--
-- Apply: supabase.com/dashboard, project woxumfxyghqpesooobjq, SQL Editor,
-- paste, Run. Deploying the app without this is fine; navigation just uses
-- the street fallback until it lands.

create or replace function my_swap_requests()
returns table (
  id uuid,
  listing_id uuid,
  bay_number text,
  street text,
  area text,
  lat double precision,
  lng double precision,
  owner_id uuid,
  owner_name text,
  duration_hours smallint,
  cost_credits smallint,
  is_hot boolean,
  is_near boolean,
  status text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select s.id, s.listing_id, l.bay_number, l.street, l.area, l.lat, l.lng,
         l.owner_id, p.display_name,
         s.duration_hours, s.cost_credits, s.is_hot, s.is_near, s.status, s.created_at
  from swap_requests s
  join listings l on l.id = s.listing_id
  join profiles p on p.id = l.owner_id
  where s.requester_id = auth.uid()
  order by s.created_at desc;
$$;

revoke execute on function my_swap_requests() from public, anon;
grant execute on function my_swap_requests() to authenticated;
