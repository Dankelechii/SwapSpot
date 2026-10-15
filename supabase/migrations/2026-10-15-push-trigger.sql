-- Calls the push Edge Function whenever a swap request is created or decided.
--
-- This is the job Supabase's "Database Webhooks" feature does, written out by
-- hand. The dashboard feature is a wrapper around pg_net that installs a
-- supabase_functions schema, and it has to be switched on before that schema
-- exists- on this project it never was, and the toggle has moved around
-- between dashboard versions. Doing it directly removes the dependency on
-- finding a button, and the trigger is then visible in this repo rather than
-- only in a dashboard form.
--
-- The body deliberately matches the shape the function already parses:
--   { type, record, old_record }
-- so supabase/functions/push/index.ts needs no change.
--
-- net.http_post queues the request rather than waiting for it, so a slow or
-- failing function cannot hold up the swap itself. A member's booking must
-- not fail because a notification did.
--
-- BEFORE RUNNING: replace __PUSH_WEBHOOK_SECRET__ with the value of the
-- PUSH_WEBHOOK_SECRET Edge Function secret. It is deliberately not committed-
-- this repo is public, and that string is the only thing stopping anyone from
-- making the function fan out notifications.
--
-- Safe to run on a live project, and safe to run twice.
--
-- Apply: supabase.com/dashboard, project woxumfxyghqpesooobjq, SQL Editor.

create extension if not exists pg_net;

create or replace function public.notify_push_on_swap_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform net.http_post(
    url     := 'https://woxumfxyghqpesooobjq.supabase.co/functions/v1/push',
    headers := '{"Content-Type":"application/json","x-webhook-secret":"__PUSH_WEBHOOK_SECRET__"}'::jsonb,
    body    := jsonb_build_object(
                 'type',       tg_op,
                 'record',     to_jsonb(new),
                 -- the function compares status against the previous row, so
                 -- an INSERT must send null here rather than a copy of new
                 'old_record', case when tg_op = 'UPDATE' then to_jsonb(old) else null end
               )
  );
  return new;
end;
$$;

drop trigger if exists push_on_swap_change on public.swap_requests;
create trigger push_on_swap_change
  after insert or update on public.swap_requests
  for each row
  execute function public.notify_push_on_swap_change();
