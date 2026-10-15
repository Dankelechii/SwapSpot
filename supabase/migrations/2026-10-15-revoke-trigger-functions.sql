-- Stops three trigger functions being callable as REST endpoints.
--
-- Supabase exposes every function in the `public` schema at
-- /rest/v1/rpc/<name>. These three are trigger functions- they are meant to
-- run from a trigger and nowhere else- but they were reachable by anyone,
-- signed in or not, because nothing had revoked EXECUTE from them:
--
--   enforce_verified_listing_owner()   guards who may create a listing
--   handle_new_user()                  sets up a profile and wallet on signup
--   notify_push_on_swap_change()       fires the push notification
--
-- The practical impact is small, because plpgsql refuses to run a trigger
-- function outside a trigger, so a direct call errors. But they are
-- SECURITY DEFINER, they are published API surface nobody intended to
-- publish, and the cost of closing them is one statement each. Security
-- that depends on a caller hitting an error first is not security.
--
-- Deliberately NOT revoked: browse_listings, request_swap,
-- approve_swap_request, decline_swap_request, my_swap_requests,
-- my_listing_requests, member_rating and is_verified. The linter flags those
-- too, but they are the app's actual API- SECURITY DEFINER on purpose, so
-- RLS can stay strict while these do the one job they are each allowed to
-- do. They are already revoked from anon and granted only to authenticated.
--
-- Safe to run on a live project, and safe to run twice.

revoke execute on function public.enforce_verified_listing_owner() from public, anon, authenticated;
revoke execute on function public.handle_new_user()                from public, anon, authenticated;
revoke execute on function public.notify_push_on_swap_change()     from public, anon, authenticated;
