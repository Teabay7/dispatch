-- Rider online/offline and live location: who can read and write locations,
-- the online rules, clearing the location on going offline, and the stale sweep.
-- Run locally with: supabase db start && supabase test db
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(45);

-- Users
--   r1, r2, r3, r4 = approved riders     p1 = pending rider
--   s1 = customer + approved rider, rider role gets suspended
--   c1 = customer with an order assigned to r1     a1 = admin
-- Switching user: set the JWT claims and SET LOCAL ROLE authenticated.
-- Back to server context: RESET ROLE and clear the claims ('{}' => auth.role() is NULL).

-- ---------------------------------------------------------------------------
-- Fixtures (server context)
-- ---------------------------------------------------------------------------
INSERT INTO auth.users (id, phone) VALUES
  ('00000000-0000-0000-0000-00000000b001', '2348000000401'),
  ('00000000-0000-0000-0000-00000000b002', '2348000000402'),
  ('00000000-0000-0000-0000-00000000b003', '2348000000403'),
  ('00000000-0000-0000-0000-00000000b004', '2348000000404'),
  ('00000000-0000-0000-0000-00000000b005', '2348000000405'),
  ('00000000-0000-0000-0000-00000000b006', '2348000000406'),
  ('00000000-0000-0000-0000-00000000b007', '2348000000407'),
  ('00000000-0000-0000-0000-00000000b008', '2348000000408');

INSERT INTO public.user_roles (user_id, role) VALUES
  ('00000000-0000-0000-0000-00000000b001', 'rider'),
  ('00000000-0000-0000-0000-00000000b002', 'rider'),
  ('00000000-0000-0000-0000-00000000b003', 'rider'),
  ('00000000-0000-0000-0000-00000000b004', 'rider'),
  ('00000000-0000-0000-0000-00000000b005', 'rider'),
  ('00000000-0000-0000-0000-00000000b006', 'customer'),
  ('00000000-0000-0000-0000-00000000b006', 'rider'),
  ('00000000-0000-0000-0000-00000000b007', 'customer'),
  ('00000000-0000-0000-0000-00000000b008', 'admin');

INSERT INTO public.rider_details
  (user_id, full_name, bike_make_model, bike_colour, plate_number, id_photo_path, selfie_path, kyc_status)
SELECT u.id, 'Rider ' || right(u.id::text, 4), 'Bajaj Boxer', 'Red', 'EDE-' || right(u.id::text, 3),
       u.id || '/id.jpg', u.id || '/selfie.jpg', u.status::public.kyc_status
FROM (VALUES
  ('00000000-0000-0000-0000-00000000b001'::uuid, 'approved'),
  ('00000000-0000-0000-0000-00000000b002'::uuid, 'approved'),
  ('00000000-0000-0000-0000-00000000b003'::uuid, 'approved'),
  ('00000000-0000-0000-0000-00000000b004'::uuid, 'approved'),
  ('00000000-0000-0000-0000-00000000b005'::uuid, 'pending'),
  ('00000000-0000-0000-0000-00000000b006'::uuid, 'approved')
) AS u(id, status);

INSERT INTO public.orders
  (customer_id, rider_id, pickup_address, pickup_lat, pickup_lng,
   dropoff_address, dropoff_lat, dropoff_lng, price_kobo, commission_kobo, status)
VALUES
  ('00000000-0000-0000-0000-00000000b007', '00000000-0000-0000-0000-00000000b001',
   'Pickup, Ede', 7.73, 4.43, 'Dropoff, Ede', 7.74, 4.44, 0, 0, 'rider_requested');

-- ---------------------------------------------------------------------------
-- r1: offline riders cannot send location; going online; sending location
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT throws_ok(
  $$INSERT INTO public.rider_locations (rider_id, lat, lng)
    VALUES ('00000000-0000-0000-0000-00000000b001', 7.73, 4.43)$$,
  '42501', NULL,
  'An offline rider cannot send a location');

SELECT lives_ok(
  $$UPDATE public.rider_details SET is_online = true
     WHERE user_id = '00000000-0000-0000-0000-00000000b001'$$,
  'An approved rider with an active rider role can go online');

SELECT ok(
  (SELECT online_since = now() FROM public.rider_details
    WHERE user_id = '00000000-0000-0000-0000-00000000b001'),
  'Going online sets online_since');

UPDATE public.rider_details SET online_since = '2000-01-01'
 WHERE user_id = '00000000-0000-0000-0000-00000000b001';
SELECT ok(
  (SELECT online_since = now() FROM public.rider_details
    WHERE user_id = '00000000-0000-0000-0000-00000000b001'),
  'A rider cannot change online_since');

SELECT lives_ok(
  $$INSERT INTO public.rider_locations (rider_id, lat, lng, accuracy_m, updated_at)
    VALUES ('00000000-0000-0000-0000-00000000b001', 7.73, 4.43, 12, '2100-01-01')$$,
  'An online rider can send their location');

SELECT ok(
  (SELECT updated_at = now() FROM public.rider_locations
    WHERE rider_id = '00000000-0000-0000-0000-00000000b001'),
  'updated_at is set by the server on insert (a future time is ignored)');

SELECT lives_ok(
  $$INSERT INTO public.rider_locations (rider_id, lat, lng, accuracy_m)
    VALUES ('00000000-0000-0000-0000-00000000b001', 7.735, 4.435, 8)
    ON CONFLICT (rider_id) DO UPDATE
      SET lat = EXCLUDED.lat, lng = EXCLUDED.lng, accuracy_m = EXCLUDED.accuracy_m,
          updated_at = '2100-01-01'$$,
  'An online rider can update their location (upsert)');

SELECT ok(
  (SELECT updated_at = now() AND lat = 7.735 FROM public.rider_locations
    WHERE rider_id = '00000000-0000-0000-0000-00000000b001'),
  'updated_at is set by the server on update');

SELECT throws_ok(
  $$INSERT INTO public.rider_locations (rider_id, lat, lng)
    VALUES ('00000000-0000-0000-0000-00000000b002', 7.73, 4.43)$$,
  '42501', NULL,
  'A rider cannot send a location for another rider');

SELECT throws_ok(
  $$INSERT INTO public.rider_locations (rider_id, lat, lng)
    VALUES ('00000000-0000-0000-0000-00000000b001', 95, 4.43)
    ON CONFLICT (rider_id) DO UPDATE SET lat = EXCLUDED.lat$$,
  '23514', NULL,
  'An impossible latitude is rejected');

-- ---------------------------------------------------------------------------
-- r2 goes online with a location; riders only see their own
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b002","role":"authenticated"}', true);
UPDATE public.rider_details SET is_online = true
 WHERE user_id = '00000000-0000-0000-0000-00000000b002';
INSERT INTO public.rider_locations (rider_id, lat, lng)
VALUES ('00000000-0000-0000-0000-00000000b002', 7.75, 4.45);

SELECT is(
  (SELECT array_agg(rider_id) FROM public.rider_locations),
  ARRAY['00000000-0000-0000-0000-00000000b002'::uuid],
  'A rider can read only their own location');

SELECT is(
  (SELECT count(*)::int FROM public.rider_locations
    WHERE rider_id = '00000000-0000-0000-0000-00000000b001'),
  0,
  'A rider cannot read another rider''s location');

-- ---------------------------------------------------------------------------
-- p1: pending KYC
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b005","role":"authenticated"}', true);

SELECT throws_ok(
  $$UPDATE public.rider_details SET is_online = true
     WHERE user_id = '00000000-0000-0000-0000-00000000b005'$$,
  'P0001', 'Rider must be KYC approved with an active rider role to go online',
  'A rider with pending KYC cannot go online');

SELECT throws_ok(
  $$INSERT INTO public.rider_locations (rider_id, lat, lng)
    VALUES ('00000000-0000-0000-0000-00000000b005', 7.73, 4.43)$$,
  '42501', NULL,
  'A rider with pending KYC cannot send a location');

-- ---------------------------------------------------------------------------
-- c1: a customer cannot read the rider's location, even with an order
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b007","role":"authenticated"}', true);

SELECT is(
  (SELECT count(*)::int FROM public.rider_locations),
  0,
  'A customer cannot read the rider''s location while the order is rider_requested');

RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);
UPDATE public.orders SET status = 'accepted'
 WHERE customer_id = '00000000-0000-0000-0000-00000000b007';

SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b007","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT is(
  (SELECT count(*)::int FROM public.rider_locations),
  0,
  'A customer cannot read the rider''s location after acceptance either (until dispatch)');

SELECT throws_ok(
  $$INSERT INTO public.rider_locations (rider_id, lat, lng)
    VALUES ('00000000-0000-0000-0000-00000000b007', 7.73, 4.43)$$,
  '42501', NULL,
  'A customer cannot send a location');

-- ---------------------------------------------------------------------------
-- anon and admin
-- ---------------------------------------------------------------------------
RESET ROLE;
SELECT set_config('request.jwt.claims', '{"role":"anon"}', true);
SET LOCAL ROLE anon;

SELECT is(
  (SELECT count(*)::int FROM public.rider_locations),
  0,
  'Signed-out users cannot read any location');

RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b008","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT is(
  (SELECT count(*)::int FROM public.rider_locations),
  2,
  'An admin can read every rider''s location');

-- ---------------------------------------------------------------------------
-- Going offline deletes the location; offline riders cannot send again
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b001","role":"authenticated"}', true);

SELECT lives_ok(
  $$UPDATE public.rider_details SET is_online = false
     WHERE user_id = '00000000-0000-0000-0000-00000000b001'$$,
  'A rider can go offline');

SELECT is(
  (SELECT count(*)::int FROM public.rider_locations),
  0,
  'Going offline deletes the rider''s location');

SELECT ok(
  (SELECT online_since IS NULL FROM public.rider_details
    WHERE user_id = '00000000-0000-0000-0000-00000000b001'),
  'Going offline clears online_since');

SELECT throws_ok(
  $$INSERT INTO public.rider_locations (rider_id, lat, lng)
    VALUES ('00000000-0000-0000-0000-00000000b001', 7.73, 4.43)$$,
  '42501', NULL,
  'After going offline, the rider cannot send a location');

-- ---------------------------------------------------------------------------
-- Suspension: s1 is online with a location, then the rider role is suspended
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b006","role":"authenticated"}', true);
UPDATE public.rider_details SET is_online = true
 WHERE user_id = '00000000-0000-0000-0000-00000000b006';
INSERT INTO public.rider_locations (rider_id, lat, lng)
VALUES ('00000000-0000-0000-0000-00000000b006', 7.76, 4.46);

RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);
UPDATE public.user_roles SET status = 'suspended', suspended_reason = 'Test'
 WHERE user_id = '00000000-0000-0000-0000-00000000b006' AND role = 'rider';

SELECT ok(
  (SELECT NOT is_online FROM public.rider_details
    WHERE user_id = '00000000-0000-0000-0000-00000000b006'),
  'Suspending the rider role takes the rider offline');

SELECT is(
  (SELECT count(*)::int FROM public.rider_locations
    WHERE rider_id = '00000000-0000-0000-0000-00000000b006'),
  0,
  'Suspending the rider role deletes their location');

SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b006","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT throws_ok(
  $$UPDATE public.rider_details SET is_online = true
     WHERE user_id = '00000000-0000-0000-0000-00000000b006'$$,
  'P0001', 'Rider must be KYC approved with an active rider role to go online',
  'A suspended rider cannot go online');

SELECT throws_ok(
  $$INSERT INTO public.rider_locations (rider_id, lat, lng)
    VALUES ('00000000-0000-0000-0000-00000000b006', 7.76, 4.46)$$,
  '42501', NULL,
  'A suspended rider cannot send a location');

-- ---------------------------------------------------------------------------
-- Rejecting an online rider takes them offline and deletes the location
-- ---------------------------------------------------------------------------
RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);
UPDATE public.rider_details
   SET kyc_status = 'rejected', rejection_reason = 'Plate number does not match'
 WHERE user_id = '00000000-0000-0000-0000-00000000b002';

SELECT ok(
  (SELECT NOT is_online FROM public.rider_details
    WHERE user_id = '00000000-0000-0000-0000-00000000b002'),
  'Rejecting an online rider takes them offline');

SELECT is(
  (SELECT count(*)::int FROM public.rider_locations
    WHERE rider_id = '00000000-0000-0000-0000-00000000b002'),
  0,
  'Rejecting an online rider deletes their location');

-- ---------------------------------------------------------------------------
-- Stale rule
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT rider_stale_after_minutes FROM public.app_settings),
  5,
  'Riders go stale after 5 minutes by default');

SELECT throws_ok(
  $$UPDATE public.app_settings SET rider_stale_after_minutes = 0$$,
  '23514', NULL,
  'The stale setting must be at least 1 minute');

SELECT throws_ok(
  $$UPDATE public.app_settings SET rider_stale_after_minutes = 61$$,
  '23514', NULL,
  'The stale setting is at most 60 minutes');

-- Reinstate and re-approve for the stale scenarios (server context).
UPDATE public.rider_details SET kyc_status = 'approved'
 WHERE user_id = '00000000-0000-0000-0000-00000000b002';

-- r1: fresh location (now)
-- r2: location last updated 10 minutes ago
-- r3: online 10 minutes ago, never sent a location
-- r4: online 1 minute ago, no location yet
UPDATE public.rider_details SET is_online = true
 WHERE user_id IN ('00000000-0000-0000-0000-00000000b001', '00000000-0000-0000-0000-00000000b002',
                   '00000000-0000-0000-0000-00000000b003', '00000000-0000-0000-0000-00000000b004');
INSERT INTO public.rider_locations (rider_id, lat, lng) VALUES
  ('00000000-0000-0000-0000-00000000b001', 7.73, 4.43),
  ('00000000-0000-0000-0000-00000000b002', 7.75, 4.45);

-- Backdate the server-set timestamps (the triggers would otherwise reset them).
ALTER TABLE public.rider_locations DISABLE TRIGGER rider_locations_touch;
ALTER TABLE public.rider_details DISABLE TRIGGER rider_details_stamp_online_since;
UPDATE public.rider_locations SET updated_at = now() - interval '10 minutes'
 WHERE rider_id = '00000000-0000-0000-0000-00000000b002';
UPDATE public.rider_details SET online_since = now() - interval '10 minutes'
 WHERE user_id IN ('00000000-0000-0000-0000-00000000b002', '00000000-0000-0000-0000-00000000b003');
UPDATE public.rider_details SET online_since = now() - interval '1 minute'
 WHERE user_id = '00000000-0000-0000-0000-00000000b004';
ALTER TABLE public.rider_locations ENABLE TRIGGER rider_locations_touch;
ALTER TABLE public.rider_details ENABLE TRIGGER rider_details_stamp_online_since;

UPDATE public.app_settings SET rider_stale_after_minutes = 15;
SELECT is(public.expire_stale_riders(), 0,
  'With a 15-minute setting, riders last seen 10 minutes ago are not stale');

UPDATE public.app_settings SET rider_stale_after_minutes = 5;
SELECT is(public.expire_stale_riders(), 2,
  'With a 5-minute setting, the two riders last seen 10 minutes ago are expired');

SELECT is(
  (SELECT array_agg(user_id ORDER BY user_id) FROM public.rider_details WHERE is_online),
  ARRAY['00000000-0000-0000-0000-00000000b001'::uuid, '00000000-0000-0000-0000-00000000b004'::uuid],
  'Fresh riders stay online; a stale location and a rider who never sent one go offline');

SELECT is(
  (SELECT count(*)::int FROM public.rider_locations
    WHERE rider_id = '00000000-0000-0000-0000-00000000b002'),
  0,
  'An expired rider''s location is deleted');

SELECT is(public.expire_stale_riders(), 0, 'Running the sweep again changes nothing');

-- ---------------------------------------------------------------------------
-- Clients cannot run the sweep or the trigger functions
-- ---------------------------------------------------------------------------
SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT public.expire_stale_riders()$$, '42501', NULL,
  'anon cannot call expire_stale_riders()');
RESET ROLE;

SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.expire_stale_riders()$$, '42501', NULL,
  'A signed-in user cannot call expire_stale_riders()');
RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);

SELECT ok(has_function_privilege('service_role', 'public.expire_stale_riders()', 'EXECUTE'),
  'service_role can call expire_stale_riders()');
SELECT ok(NOT has_function_privilege('public', 'public.expire_stale_riders()', 'EXECUTE'),
  'PUBLIC cannot call expire_stale_riders()');
SELECT ok(NOT has_function_privilege('authenticated', 'public.clear_rider_location_when_offline()', 'EXECUTE')
      AND NOT has_function_privilege('anon', 'public.clear_rider_location_when_offline()', 'EXECUTE'),
  'Clients cannot call clear_rider_location_when_offline()');
SELECT ok(NOT has_function_privilege('authenticated', 'public.stamp_rider_online_since()', 'EXECUTE')
      AND NOT has_function_privilege('anon', 'public.stamp_rider_online_since()', 'EXECUTE'),
  'Clients cannot call stamp_rider_online_since()');
SELECT ok(NOT has_function_privilege('anon', 'public.rider_stale_cutoff()', 'EXECUTE'),
  'anon cannot call rider_stale_cutoff()');

SELECT is(
  (SELECT array_agg(p.proname::text ORDER BY p.proname)
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('clear_rider_location_when_offline', 'expire_stale_riders')
      AND p.prosecdef
      AND p.proconfig @> ARRAY['search_path=""']),
  ARRAY['clear_rider_location_when_offline', 'expire_stale_riders'],
  'New SECURITY DEFINER functions set an explicit empty search_path');

SELECT * FROM finish();
ROLLBACK;
