-- Member ratings, one per swap per direction.
--
-- Both sides of a completed swap can rate each other, the way a ride app
-- does. A rating is only meaningful if it came from a real swap, so the
-- table keys on the swap request and the insert policy checks that the
-- rater was actually party to it and that it was confirmed.
--
-- Individual scores are deliberately not readable by other members: you see
-- someone's average, not who gave them a two. member_rating() is the only
-- way out, and it returns an aggregate.
--
-- Safe to run on a live project, and safe to run twice.
--
-- Apply: supabase.com/dashboard, project woxumfxyghqpesooobjq, SQL Editor.

create table if not exists swap_ratings (
  swap_request_id uuid not null references swap_requests(id) on delete cascade,
  rater_id        uuid not null references auth.users(id) on delete cascade,
  ratee_id        uuid not null references auth.users(id) on delete cascade,
  stars           smallint not null check (stars between 1 and 5),
  created_at      timestamptz not null default now(),
  primary key (swap_request_id, rater_id)
);

create index if not exists swap_ratings_ratee_idx on swap_ratings (ratee_id);

alter table swap_ratings enable row level security;

-- You can read only the rows you wrote. Everyone else's scores come through
-- member_rating() as an average.
drop policy if exists "raters read only their own ratings" on swap_ratings;
create policy "raters read only their own ratings"
  on swap_ratings for select
  to authenticated
  using (rater_id = auth.uid());

-- You may rate a swap only if you were part of it, it was confirmed, and you
-- are not rating yourself.
drop policy if exists "rate only a confirmed swap you were part of" on swap_ratings;
create policy "rate only a confirmed swap you were part of"
  on swap_ratings for insert
  to authenticated
  with check (
    rater_id = auth.uid()
    and ratee_id <> auth.uid()
    and exists (
      select 1
      from swap_requests s
      join listings l on l.id = s.listing_id
      where s.id = swap_ratings.swap_request_id
        and s.status = 'confirmed'
        and (
          -- the borrower rating the bay's owner
          (s.requester_id = auth.uid() and l.owner_id = swap_ratings.ratee_id)
          -- or the owner rating the borrower
          or (l.owner_id = auth.uid() and s.requester_id = swap_ratings.ratee_id)
        )
    )
  );

revoke all on swap_ratings from anon;
grant select, insert on swap_ratings to authenticated;

-- Average and count for one member. Security definer so it can aggregate
-- rows the caller cannot read individually, which is the whole point.
create or replace function member_rating(p_user_id uuid)
returns table (average numeric, ratings_count integer)
language sql
stable
security definer
set search_path = public
as $$
  select round(avg(stars)::numeric, 2) as average,
         count(*)::integer            as ratings_count
  from swap_ratings
  where ratee_id = p_user_id;
$$;

revoke execute on function member_rating(uuid) from public, anon;
grant execute on function member_rating(uuid) to authenticated;
