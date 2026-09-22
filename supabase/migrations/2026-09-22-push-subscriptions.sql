-- Stores one Web Push subscription per browser, so the push Edge Function
-- knows where to send.
--
-- A subscription is a capability: anyone holding the endpoint and keys can
-- push a notification to that device. So RLS scopes every row to its owner,
-- and nothing is granted to anon. The Edge Function reads these with the
-- service role, which bypasses RLS by design.
--
-- Safe to run on a live project, and safe to run twice.
--
-- Apply: supabase.com/dashboard, project woxumfxyghqpesooobjq, SQL Editor.

create table if not exists push_subscriptions (
  endpoint    text primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  p256dh      text not null,
  auth        text not null,
  user_agent  text,
  created_at  timestamptz not null default now()
);

create index if not exists push_subscriptions_user_id_idx
  on push_subscriptions (user_id);

alter table push_subscriptions enable row level security;

drop policy if exists "users manage only their own push subscriptions" on push_subscriptions;
create policy "users manage only their own push subscriptions"
  on push_subscriptions for all
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

revoke all on push_subscriptions from anon;
grant select, insert, update, delete on push_subscriptions to authenticated;
