-- Publishes swap_requests over Supabase Realtime.
--
-- Why: nothing told anyone when a swap changed hands. The owner did not know
-- a request had arrived, and the requester did not know it had been approved
-- until they happened to reopen the app. With the table published, both sides
-- get the change pushed to them while the app is open.
--
-- No new policy is needed. Realtime applies the existing RLS SELECT policy
-- per subscriber, and that policy already scopes rows to
--   requester_id = auth.uid()  OR  the caller owns the listing
-- so one subscription serves both sides and leaks nothing to anyone else.
--
-- Safe to run on a live project, and safe to run twice: it only adds the
-- table to a publication, and skips if it is already there.
--
-- Apply: supabase.com/dashboard, project woxumfxyghqpesooobjq, SQL Editor,
-- paste, Run. The app degrades quietly without it; the subscription simply
-- never fires and members keep refreshing by hand.

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'swap_requests'
  ) then
    alter publication supabase_realtime add table public.swap_requests;
  end if;
end
$$;

-- Realtime sends only the primary key in the old record on UPDATE unless the
-- table has a full replica identity. The app needs the previous status to
-- tell "approved just now" from "already approved", so send the whole row.
alter table public.swap_requests replica identity full;
