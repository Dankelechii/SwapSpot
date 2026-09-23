-- Saved bays and saved members, so a member can find both again.
--
-- The app keeps favourites in local state and works without this table. What
-- the table adds is that they follow you to another device, which is the
-- whole point of saving something.
--
-- label, sublabel and owner_label are deliberately denormalised copies of the
-- bay number, street and lender's name, or the member's name, taken when you
-- saved it. A bookmark should still read as "BAY 14A, Rivington St, Meera R."
-- while nobody is lending that bay and it is nowhere in the feed, and joining
-- listings would show nothing in exactly that case. The live feed overwrites
-- them on screen when it knows better.
--
-- target_id is not a foreign key on purpose. It points at a listing or at a
-- member depending on `kind`, and a delisted bay should stay in your saved
-- list rather than vanish from it.
--
-- Safe to run on a live project, and safe to run twice.
--
-- Apply: supabase.com/dashboard, project woxumfxyghqpesooobjq, SQL Editor.

create table if not exists favourites (
  user_id    uuid not null references auth.users(id) on delete cascade,
  kind       text not null check (kind in ('listing', 'member')),
  target_id  uuid not null,
  label       text not null default '',
  sublabel    text,
  owner_label text,
  created_at timestamptz not null default now(),
  primary key (user_id, kind, target_id)
);

-- for anyone who applied an earlier copy of this file, before owner_label
alter table favourites add column if not exists owner_label text;

create index if not exists favourites_user_idx on favourites (user_id, created_at desc);

alter table favourites enable row level security;

-- Your saved list is yours. Nobody else can read what you saved, and nobody
-- can see how often a bay or a member has been saved, which would leak the
-- popularity of a member's spot to everyone else.
drop policy if exists "members manage only their own favourites" on favourites;
create policy "members manage only their own favourites"
  on favourites for all
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

revoke all on favourites from anon;
grant select, insert, update, delete on favourites to authenticated;
