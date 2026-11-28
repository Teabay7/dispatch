-- Dispatch: nearest-first offers, eligibility, decline and timeout re-dispatch, no
-- repeat offers, max attempts, radius and search time, retry, race-safe accept, one
-- job per rider, job steps, every cancellation rule and review flags, who can see
-- the rider, their bank details and location, no leaks of phone or account numbers,
-- and function privileges.
-- Run locally with: supabase db start && supabase test db
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(76);

-- ---------------------------------------------------------------------------
-- Fixtures (server context)
--   c1, c2 = customers      a1 = admin
--   P = pickup (7.7350, 4.4360): r1 300 m, r2 800 m, r3 1.5 km, r4 2.5 km, r5 7 km (outside 5 km)
--   Q = pickup (7.6750, 4.4360): r7..r13 100 m away but each ineligible; rok 1 km away
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.u(n integer) RETURNS uuid LANGUAGE sql AS
$$ SELECT ('00000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;

CREATE FUNCTION pg_temp.claims(p uuid) RETURNS text LANGUAGE sql AS
$$ SELECT set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true) $$;

CREATE FUNCTION pg_temp.make_rider(p_n integer, p_name text, p_lat double precision, p_lng double precision,
                                   p_online boolean DEFAULT true)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE id uuid := pg_temp.u(p_n);
BEGIN
  INSERT INTO auth.users (id, phone) VALUES (id, '2348000' || lpad(p_n::text, 6, '0'));
  INSERT INTO public.user_roles (user_id, role) VALUES (id, 'rider');
  INSERT INTO public.rider_details (user_id, full_name, bike_make_model, bike_colour, plate_number,
                                    id_photo_path, selfie_path, kyc_status)
  VALUES (id, p_name, 'Bajaj Boxer', 'Red', 'EDE-' || p_n, 'x/id.jpg', 'x/s.jpg', 'approved');
  INSERT INTO public.rider_bank_accounts (rider_id, bank_name, account_number, account_name, name_match,
                                          status, verified_name, verified_name_match, recorded_by, reviewed_at)
  VALUES (id, 'OPay', '70000' || lpad(p_n::text, 5, '0'), p_name, 'match', 'verified', upper(p_name), 'match',
          'test fixture', now());
  IF p_online THEN
    UPDATE public.rider_details SET is_online = true WHERE user_id = id;
    INSERT INTO public.rider_locations (rider_id, lat, lng) VALUES (id, p_lat, p_lng);
  END IF;
END $$;

CREATE FUNCTION pg_temp.make_order(p_customer uuid, p_lat double precision, p_lng double precision,
                                   p_status public.order_status DEFAULT 'created', p_rider uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE new_id uuid;
BEGIN
  INSERT INTO public.orders (customer_id, rider_id, status, pickup_address, pickup_lat, pickup_lng,
                             dropoff_address, dropoff_lat, dropoff_lng, price_kobo, commission_kobo,
                             distance_m, distance_source)
  VALUES (p_customer, p_rider, p_status, 'TEST pickup, Ede', p_lat, p_lng, 'TEST drop-off, Ede',
          p_lat + 0.01, p_lng + 0.01, 205000, 30750, 2350, 'routes')
  RETURNING id INTO new_id;
  INSERT INTO public.order_contacts (order_id, receiver_name, receiver_phone)
  VALUES (new_id, 'Test Receiver', '2348031112222');
  RETURN new_id;
END $$;

CREATE FUNCTION pg_temp.pending(p_order uuid) RETURNS uuid LANGUAGE sql AS
$$ SELECT rider_id FROM public.dispatch_offers WHERE order_id = p_order AND status = 'pending' $$;

CREATE FUNCTION pg_temp.pending_offer(p_order uuid) RETURNS uuid LANGUAGE sql AS
$$ SELECT id FROM public.dispatch_offers WHERE order_id = p_order AND status = 'pending' $$;

-- Backdates an offer's expiry (offers can't be changed, so the trigger is paused).
CREATE FUNCTION pg_temp.expire_now(p_order uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  ALTER TABLE public.dispatch_offers DISABLE TRIGGER dispatch_offers_protect;
  UPDATE public.dispatch_offers SET expires_at = now() - interval '1 second'
   WHERE order_id = p_order AND status = 'pending';
  ALTER TABLE public.dispatch_offers ENABLE TRIGGER dispatch_offers_protect;
END $$;

INSERT INTO auth.users (id, phone) VALUES
  (pg_temp.u(901), '2348000000901'), (pg_temp.u(902), '2348000000902'), (pg_temp.u(903), '2348000000903');
INSERT INTO public.user_roles (user_id, role) VALUES
  (pg_temp.u(901), 'customer'), (pg_temp.u(902), 'customer'), (pg_temp.u(903), 'admin');

SELECT pg_temp.make_rider(1, 'Rider One', 7.7377, 4.4360);
SELECT pg_temp.make_rider(2, 'Rider Two', 7.7422, 4.4360);
SELECT pg_temp.make_rider(3, 'Rider Three', 7.7485, 4.4360);
SELECT pg_temp.make_rider(4, 'Rider Four', 7.7575, 4.4360);
SELECT pg_temp.make_rider(5, 'Rider Far', 7.7980, 4.4360);

CREATE TEMP TABLE ids (name text PRIMARY KEY, id uuid);
GRANT SELECT ON ids TO authenticated;
CREATE FUNCTION pg_temp.id(p text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM ids WHERE name = p $$;

-- ---------------------------------------------------------------------------
-- Settings and the idle sweep
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT offer_timeout_seconds || ' ' || dispatch_max_attempts || ' ' || dispatch_max_radius_m || ' '
          || dispatch_search_minutes || ' ' || customer_late_cancel_flag_after || ' ' || rider_late_cancel_flag_after
     FROM public.app_settings),
  '30 5 5000 10 3 3',
  'settings: 30 s offers, 5 attempts, 5 km radius, 10-minute search, flag after 3 late cancels'
);

SELECT is(public.run_dispatch_sweep(), 0, 'the sweep does nothing when nothing is searching');

-- ---------------------------------------------------------------------------
-- O1 at P: nearest first, decline, timeout, no repeat offers, search ends
-- ---------------------------------------------------------------------------
INSERT INTO ids VALUES ('O1', pg_temp.make_order(pg_temp.u(901), 7.7350, 4.4360));

SELECT is(public.run_dispatch_sweep(), 1, 'the sweep starts an order created in the SQL Editor');

SELECT is(
  (SELECT status::text || ' round ' || dispatch_round FROM public.orders WHERE id = pg_temp.id('O1')),
  'rider_requested round 1',
  'the order is searching (round 1)'
);

SELECT is(
  (SELECT rider_id::text || ' #' || attempt_no || ' ' || (distance_to_pickup_m BETWEEN 290 AND 310)
     FROM public.dispatch_offers WHERE order_id = pg_temp.id('O1')),
  pg_temp.u(1)::text || ' #1 true',
  'the first offer goes to the nearest rider (about 300 m)'
);

SELECT is(
  (SELECT count(*) FROM public.dispatch_offers WHERE order_id = pg_temp.id('O1') AND status = 'pending'),
  1::bigint,
  'one offer at a time'
);

SELECT pg_temp.claims(pg_temp.u(1));
SET LOCAL ROLE authenticated;

SELECT is(
  (SELECT area_name || ' | ' || direction || ' | ' || price_kobo || ' | ' || trip_distance_m || ' | '
          || (seconds_left BETWEEN 1 AND 30) FROM public.get_my_offer()),
  'Ede, Osun State | south | 205000 | 2350 | true',
  'the offer shows area, direction, price, trip distance and time left, but no address'
);

SELECT is(
  (SELECT count(*) FROM public.orders WHERE id = pg_temp.id('O1')),
  0::bigint,
  'a rider cannot read the order (or its address) before accepting'
);

SELECT throws_ok(
  $$SELECT * FROM public.get_order_contact_details(pg_temp.id('O1'))$$,
  'P0001', 'Contact details are not available for this order',
  'no phone numbers before accepting'
);

SELECT pg_temp.claims(pg_temp.u(2));

SELECT is((SELECT count(*) FROM public.get_my_offer()), 0::bigint, 'other riders have no offer');

SELECT throws_ok(
  $$SELECT public.accept_offer(pg_temp.pending_offer(pg_temp.id('O1')))$$,
  'P0001', 'Offer not found',
  'a rider cannot accept someone else''s offer'
);

SELECT pg_temp.claims(pg_temp.u(1));
SELECT lives_ok($$SELECT public.decline_offer(pg_temp.pending_offer(pg_temp.id('O1')))$$, 'a rider can decline');

RESET ROLE;
SELECT is(pg_temp.pending(pg_temp.id('O1')), pg_temp.u(2), 'a decline goes straight to the next nearest rider');

SELECT pg_temp.claims(pg_temp.u(2));
SET LOCAL ROLE authenticated;
SELECT public.decline_offer(pg_temp.pending_offer(pg_temp.id('O1')));
RESET ROLE;

SELECT is(pg_temp.pending(pg_temp.id('O1')), pg_temp.u(3), 'riders who declined are not offered it again');

SELECT pg_temp.expire_now(pg_temp.id('O1'));
SELECT pg_temp.claims(pg_temp.u(3));
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$SELECT public.accept_offer(pg_temp.pending_offer(pg_temp.id('O1')))$$,
  'P0001', 'This offer has expired',
  'an expired offer cannot be accepted, even before the sweep runs'
);
RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);

SELECT public.run_dispatch_sweep();
SELECT is(
  (SELECT string_agg(rider_id::text || ':' || status, ',' ORDER BY attempt_no) FROM public.dispatch_offers
    WHERE order_id = pg_temp.id('O1')),
  pg_temp.u(1) || ':declined,' || pg_temp.u(2) || ':declined,' || pg_temp.u(3) || ':expired,' || pg_temp.u(4) || ':pending',
  'a timeout moves the offer to the next rider'
);

SELECT pg_temp.expire_now(pg_temp.id('O1'));
SELECT public.run_dispatch_sweep();
SELECT is(
  (SELECT status::text || ' ' || (pg_temp.pending(id) IS NULL) FROM public.orders WHERE id = pg_temp.id('O1')),
  'rider_requested true',
  'with nobody else in range (r5 is 7 km away), the order keeps searching'
);

UPDATE public.orders SET dispatch_started_at = now() - interval '11 minutes' WHERE id = pg_temp.id('O1');
SELECT public.run_dispatch_sweep();
SELECT is(
  (SELECT status::text FROM public.orders WHERE id = pg_temp.id('O1')),
  'no_rider_found',
  'when the search time runs out, the order becomes "no rider found"'
);

-- ---------------------------------------------------------------------------
-- Retry and accept
-- ---------------------------------------------------------------------------
SELECT pg_temp.claims(pg_temp.u(901));
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT public.retry_dispatch(pg_temp.id('O1'))$$, 'the customer can retry');
RESET ROLE;

SELECT is(
  (SELECT status::text || ' round ' || dispatch_round || ' ' || pg_temp.pending(id)::text
     FROM public.orders WHERE id = pg_temp.id('O1')),
  'rider_requested round 2 ' || pg_temp.u(1),
  'a retry is a new round: the nearest rider can be offered it again'
);

SELECT pg_temp.claims(pg_temp.u(901));
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.retry_dispatch(pg_temp.id('O1'))$$, 'P0001',
  'This order is not waiting for a retry', 'retry only after no rider was found');

SELECT pg_temp.claims(pg_temp.u(1));
SELECT is(public.accept_offer(pg_temp.pending_offer(pg_temp.id('O1'))), pg_temp.id('O1'), 'the rider accepts');
RESET ROLE;

SELECT is(
  (SELECT o.status::text || ' ' || (o.rider_id = pg_temp.u(1)) || ' ' || (o.accepted_at IS NOT NULL) || ' '
          || (o.payee_account_id = (SELECT id FROM public.rider_bank_accounts WHERE rider_id = pg_temp.u(1) AND status = 'verified'))
     FROM public.orders o WHERE o.id = pg_temp.id('O1')),
  'accepted true true true',
  'accepting assigns the rider and fixes their verified bank account as the payee'
);

SELECT pg_temp.claims(pg_temp.u(1));
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$SELECT public.accept_offer((SELECT id FROM public.dispatch_offers WHERE order_id = pg_temp.id('O1') AND status = 'accepted'))$$,
  'P0001', 'This offer is no longer available',
  'an offer cannot be accepted twice'
);

SELECT is(
  (SELECT customer_phone FROM public.get_order_contact_details(pg_temp.id('O1'))),
  '2348000000901',
  'after accepting, the rider gets the customer''s phone number'
);

-- Customer view of the assigned rider
SELECT pg_temp.claims(pg_temp.u(901));
SELECT is(
  (SELECT rider_name || ' | ' || bike_make_model || ' | ' || bike_colour || ' | ' || plate_number || ' | '
          || coalesce(account_number, 'no bank') FROM public.get_order_rider(pg_temp.id('O1'))),
  'Rider One | Bajaj Boxer | Red | EDE-1 | no bank',
  'the customer sees the rider''s name, bike and plate, but no bank details before payment is due'
);

SELECT ok(
  (SELECT distance_to_pickup_m BETWEEN 290 AND 310 FROM public.get_assigned_rider_location(pg_temp.id('O1'))),
  'the customer sees how far the rider is from pickup'
);

SELECT pg_temp.claims(pg_temp.u(902));
SELECT throws_ok($$SELECT * FROM public.get_order_rider(pg_temp.id('O1'))$$, 'P0001',
  'Rider details are not available for this order', 'another customer cannot see the rider');
SELECT throws_ok($$SELECT * FROM public.get_assigned_rider_location(pg_temp.id('O1'))$$, 'P0001',
  'The rider''s location is not available for this order', 'another customer cannot see the rider''s location');
RESET ROLE;

UPDATE public.orders SET payment_status = 'awaiting_payment' WHERE id = pg_temp.id('O1');
SELECT pg_temp.claims(pg_temp.u(901));
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT bank_name || ' ' || account_number || ' ' || account_name FROM public.get_order_rider(pg_temp.id('O1'))),
  'OPay 7000000001 RIDER ONE',
  'while payment is due, the customer sees the rider''s verified bank account'
);
RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);

-- ---------------------------------------------------------------------------
-- One job per rider, and the accept race
-- ---------------------------------------------------------------------------
INSERT INTO ids VALUES ('O2', pg_temp.make_order(pg_temp.u(902), 7.7350, 4.4360));
SELECT public.start_dispatch(pg_temp.id('O2'));

SELECT is(pg_temp.pending(pg_temp.id('O2')), pg_temp.u(2), 'a rider with a job (r1) is not offered another');

SELECT throws_ok(
  $$SELECT pg_temp.make_order(pg_temp.u(902), 7.7350, 4.4360, 'accepted', pg_temp.u(1))$$,
  '23505', NULL,
  'the database refuses a second active job for the same rider'
);

SELECT throws_ok(
  $$INSERT INTO public.dispatch_offers (order_id, round_no, attempt_no, rider_id, distance_to_pickup_m, expires_at)
    VALUES (pg_temp.id('O2'), 1, 9, pg_temp.u(3), 1500, now() + interval '30 seconds')$$,
  '23505', NULL,
  'an order can never have two pending offers'
);

-- r2's offer is withdrawn (as if it timed out) and r3 gets the next one.
UPDATE public.dispatch_offers SET status = 'expired', responded_at = now()
 WHERE order_id = pg_temp.id('O2') AND status = 'pending';
SELECT public.lock_dispatch();
SELECT public.offer_next_rider(pg_temp.id('O2'));

SELECT pg_temp.claims(pg_temp.u(2));
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$SELECT public.accept_offer((SELECT id FROM public.dispatch_offers WHERE order_id = pg_temp.id('O2') AND rider_id = pg_temp.u(2)))$$,
  'P0001', 'This offer is no longer available',
  'the rider whose offer moved on cannot accept it'
);

SELECT pg_temp.claims(pg_temp.u(3));
SELECT lives_ok($$SELECT public.accept_offer(pg_temp.pending_offer(pg_temp.id('O2')))$$, 'the current rider accepts');
RESET ROLE;

INSERT INTO public.dispatch_offers (order_id, round_no, attempt_no, rider_id, distance_to_pickup_m, expires_at)
VALUES (pg_temp.id('O2'), 1, 9, pg_temp.u(4), 2500, now() + interval '30 seconds');
SELECT pg_temp.claims(pg_temp.u(4));
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$SELECT public.accept_offer((SELECT id FROM public.dispatch_offers WHERE order_id = pg_temp.id('O2') AND rider_id = pg_temp.u(4)))$$,
  'P0001', 'This offer is no longer available',
  'a second rider can never be assigned to an order that already has one'
);
RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);
UPDATE public.dispatch_offers SET status = 'withdrawn', responded_at = now()
 WHERE order_id = pg_temp.id('O2') AND status = 'pending';

SELECT is(
  (SELECT rider_id FROM public.orders WHERE id = pg_temp.id('O2')),
  pg_temp.u(3),
  'the order has exactly the rider who won'
);

-- ---------------------------------------------------------------------------
-- Eligibility at Q: seven ineligible riders 100 m away, one good rider 1 km away
-- ---------------------------------------------------------------------------
SELECT pg_temp.make_rider(7, 'Offline', 7.6759, 4.4360, false);
SELECT pg_temp.make_rider(8, 'Stale', 7.6759, 4.4360);
SELECT pg_temp.make_rider(9, 'Suspended', 7.6759, 4.4360);
SELECT pg_temp.make_rider(10, 'Revoked Bank', 7.6759, 4.4360);
SELECT pg_temp.make_rider(11, 'Commission Due', 7.6759, 4.4360);
SELECT pg_temp.make_rider(12, 'On A Job', 7.6759, 4.4360);
SELECT pg_temp.make_rider(13, 'Has Offer', 7.6759, 4.4360);
SELECT pg_temp.make_rider(14, 'Good Rider', 7.6840, 4.4360);

ALTER TABLE public.rider_locations DISABLE TRIGGER rider_locations_touch;
UPDATE public.rider_locations SET updated_at = now() - interval '10 minutes' WHERE rider_id = pg_temp.u(8);
ALTER TABLE public.rider_locations ENABLE TRIGGER rider_locations_touch;
UPDATE public.user_roles SET status = 'suspended', suspended_reason = 'Test' WHERE user_id = pg_temp.u(9) AND role = 'rider';
SELECT public.revoke_rider_bank_account(
  (SELECT id FROM public.rider_bank_accounts WHERE rider_id = pg_temp.u(10)), 'Test revoke', 'test');
INSERT INTO public.commission_cycles (rider_id, cycle_no, trips_required, trip_count, status, reference_code, due_at)
VALUES (pg_temp.u(11), 1, 1, 1, 'due', 'DSP-TEST-R11-C001', now());
SELECT pg_temp.make_order(pg_temp.u(902), 7.70, 4.43, 'accepted', pg_temp.u(12));
INSERT INTO ids VALUES ('O7', pg_temp.make_order(pg_temp.u(902), 7.70, 4.43, 'rider_requested'));
INSERT INTO public.dispatch_offers (order_id, round_no, attempt_no, rider_id, distance_to_pickup_m, expires_at)
VALUES (pg_temp.id('O7'), 1, 1, pg_temp.u(13), 100, now() + interval '30 seconds');

SELECT is(
  ARRAY(SELECT public.rider_is_dispatchable(pg_temp.u(n)) FROM unnest(ARRAY[7, 8, 9, 10, 11, 12, 13, 14]) AS n),
  ARRAY[false, false, false, false, false, false, false, true],
  'offline, stale, suspended, no verified bank, commission due, on a job and holding an offer are all excluded'
);

INSERT INTO ids VALUES ('O6', pg_temp.make_order(pg_temp.u(901), 7.6750, 4.4360));
SELECT public.start_dispatch(pg_temp.id('O6'));
SELECT is(pg_temp.pending(pg_temp.id('O6')), pg_temp.u(14), 'the offer skips every ineligible rider for the good one 1 km away');

UPDATE public.rider_details SET is_online = false WHERE user_id = pg_temp.u(14);
SELECT public.run_dispatch_sweep();
SELECT is(
  (SELECT status::text FROM public.dispatch_offers WHERE order_id = pg_temp.id('O6') AND rider_id = pg_temp.u(14)),
  'expired',
  'an offer to a rider who went offline is expired by the sweep'
);

-- ---------------------------------------------------------------------------
-- Max attempts
-- ---------------------------------------------------------------------------
UPDATE public.app_settings SET dispatch_max_attempts = 2;
INSERT INTO ids VALUES ('O8', pg_temp.make_order(pg_temp.u(902), 7.7350, 4.4360));
SELECT public.start_dispatch(pg_temp.id('O8'));
SELECT pg_temp.claims(pg_temp.u(2));
SET LOCAL ROLE authenticated;
SELECT public.decline_offer(pg_temp.pending_offer(pg_temp.id('O8')));
SELECT pg_temp.claims(pg_temp.u(4));
SELECT public.decline_offer(pg_temp.pending_offer(pg_temp.id('O8')));
RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);

SELECT is(
  (SELECT status::text || ' after ' || (SELECT count(*) FROM public.dispatch_offers WHERE order_id = o.id) || ' offers'
     FROM public.orders o WHERE o.id = pg_temp.id('O8')),
  'no_rider_found after 2 offers',
  'after the maximum number of attempts, no rider found'
);
UPDATE public.app_settings SET dispatch_max_attempts = 5;

-- ---------------------------------------------------------------------------
-- Customer cancellations
-- ---------------------------------------------------------------------------
SELECT pg_temp.claims(pg_temp.u(901));
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT public.cancel_order(pg_temp.id('O6'))$$, 'the customer cancels a searching order for free');
RESET ROLE;

SELECT is(
  (SELECT stage::text || ' counted=' || counted FROM public.cancellation_events WHERE order_id = pg_temp.id('O6')),
  'before_accept counted=false',
  'a cancel before acceptance is not counted'
);

CREATE TEMP TABLE late (n integer, id uuid);
GRANT SELECT ON late TO authenticated;
INSERT INTO late SELECT n, pg_temp.make_order(pg_temp.u(902), 7.7350, 4.4360, 'accepted', pg_temp.u(4))
  FROM generate_series(1, 1) AS n;

SELECT pg_temp.claims(pg_temp.u(902));
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT public.cancel_order((SELECT id FROM late WHERE n = 1))$$,
  'the customer can cancel after a rider accepts');
RESET ROLE;

SELECT is(
  (SELECT stage::text || ' counted=' || counted FROM public.cancellation_events WHERE order_id = (SELECT id FROM late WHERE n = 1)),
  'after_accept counted=true',
  'a cancel after acceptance is counted'
);

INSERT INTO late SELECT 2, pg_temp.make_order(pg_temp.u(902), 7.7350, 4.4360, 'accepted', pg_temp.u(4));
SELECT pg_temp.claims(pg_temp.u(902));
SET LOCAL ROLE authenticated;
SELECT public.cancel_order((SELECT id FROM late WHERE n = 2));
RESET ROLE;

SELECT is(
  (SELECT count(*) FROM public.admin_review_flags WHERE user_id = pg_temp.u(902)),
  0::bigint,
  'two late cancels: no review flag yet'
);

INSERT INTO late SELECT 3, pg_temp.make_order(pg_temp.u(902), 7.7350, 4.4360, 'accepted', pg_temp.u(4));
SELECT pg_temp.claims(pg_temp.u(902));
SET LOCAL ROLE authenticated;
SELECT public.cancel_order((SELECT id FROM late WHERE n = 3));
RESET ROLE;

SELECT is(
  (SELECT role || ' ' || reason FROM public.admin_review_flags WHERE user_id = pg_temp.u(902) AND resolved_at IS NULL),
  'customer late_cancels',
  'the third late cancel flags the customer for admin review'
);

INSERT INTO ids VALUES ('O9', pg_temp.make_order(pg_temp.u(901), 7.7350, 4.4360, 'picked_up', pg_temp.u(4)));
SELECT pg_temp.claims(pg_temp.u(901));
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.cancel_order(pg_temp.id('O9'))$$, 'P0001',
  'After pickup, only Dispatch support can cancel', 'the customer cannot cancel after pickup');

SELECT pg_temp.claims(pg_temp.u(4));
SELECT throws_ok($$SELECT public.rider_cancel_job(pg_temp.id('O9'), 'other')$$, 'P0001',
  'After pickup, only Dispatch support can cancel', 'the rider cannot cancel after pickup');

SELECT throws_ok(
  $$SELECT public.admin_cancel_order(pg_temp.id('O9'), 'rider', 'Accident', 'Me')$$,
  'P0001', 'Only an admin can cancel this way', 'a rider cannot use the admin cancel');

SELECT pg_temp.claims(pg_temp.u(903));
SELECT throws_ok(
  $$SELECT public.admin_cancel_order(pg_temp.id('O9'), 'rider', 'Call 08031234567', 'Admin Ade')$$,
  'P0001', 'Do not put phone or account numbers in the reason', 'an admin reason cannot hold a phone number');

SELECT lives_ok(
  $$SELECT public.admin_cancel_order(pg_temp.id('O9'), 'rider', 'Bike broke down after pickup', 'Admin Ade')$$,
  'an admin can cancel after pickup');
RESET ROLE;

SELECT is(
  (SELECT o.status::text || ' | ' || e.role || ' ' || e.stage || ' counted=' || e.counted
     FROM public.orders o JOIN public.cancellation_events e ON e.order_id = o.id WHERE o.id = pg_temp.id('O9')),
  'cancelled_by_rider | admin after_pickup counted=false',
  'the admin cancel is recorded and not counted against anyone'
);

-- ---------------------------------------------------------------------------
-- Rider cancellations (O1: accepted by r1, payment due)
-- ---------------------------------------------------------------------------
SELECT pg_temp.claims(pg_temp.u(1));
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.rider_cancel_job(pg_temp.id('O1'), 'because')$$, 'P0001', 'Choose a reason',
  'a rider must choose a listed reason');
SELECT lives_ok($$SELECT public.rider_cancel_job(pg_temp.id('O1'), 'pickup_problem')$$,
  'a rider can cancel after accepting, before pickup');
RESET ROLE;

SELECT is(
  (SELECT o.status::text || ' ' || (o.rider_id IS NULL) || ' ' || (o.payee_account_id IS NULL) || ' ' || pg_temp.pending(o.id)::text
     FROM public.orders o WHERE o.id = pg_temp.id('O1')),
  'rider_requested true true ' || pg_temp.u(2),
  'the order goes back to searching and is offered to the next rider, not the one who cancelled'
);

SELECT is(
  (SELECT stage::text || ' counted=' || counted || ' ' || reason FROM public.cancellation_events
    WHERE order_id = pg_temp.id('O1') AND role = 'rider'),
  'after_accept counted=true pickup_problem',
  'the rider''s cancel is counted against them'
);

UPDATE public.app_settings SET rider_late_cancel_flag_after = 2;
INSERT INTO late SELECT 4, pg_temp.make_order(pg_temp.u(901), 7.7350, 4.4360, 'accepted', pg_temp.u(1));
SELECT pg_temp.claims(pg_temp.u(1));
SET LOCAL ROLE authenticated;
SELECT public.rider_cancel_job((SELECT id FROM late WHERE n = 4), 'vehicle_problem');
RESET ROLE;

SELECT is(
  (SELECT role FROM public.admin_review_flags WHERE user_id = pg_temp.u(1) AND resolved_at IS NULL),
  'rider',
  'a rider reaching the threshold is flagged for admin review'
);

SELECT set_config('request.jwt.claims', '{}', true);
SELECT lives_ok(
  $$SELECT public.resolve_review_flag((SELECT id FROM public.admin_review_flags WHERE user_id = pg_temp.u(1)),
      'Spoke to the rider', 'Admin Ade')$$,
  'an admin can resolve a review flag'
);

-- ---------------------------------------------------------------------------
-- Job steps (O2: accepted by r3)
-- ---------------------------------------------------------------------------
SELECT pg_temp.claims(pg_temp.u(3));
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.mark_picked_up(pg_temp.id('O2'))$$, 'P0001',
  'Mark that you have arrived at pickup first', 'pickup needs arrival first');
SELECT pg_temp.claims(pg_temp.u(2));
SELECT throws_ok($$SELECT public.mark_arrived_at_pickup(pg_temp.id('O2'))$$, 'P0001', 'Job not found',
  'another rider cannot move the job');
SELECT pg_temp.claims(pg_temp.u(3));
SELECT lives_ok($$SELECT public.mark_arrived_at_pickup(pg_temp.id('O2'))$$, 'the rider marks arrival at pickup');
SELECT lives_ok($$SELECT public.mark_picked_up(pg_temp.id('O2'))$$, 'the rider marks the package picked up');
SELECT is(public.get_my_active_job(), pg_temp.id('O2'), 'the rider''s active job');
RESET ROLE;

SELECT is(
  (SELECT status::text || ' ' || (arrived_pickup_at IS NOT NULL) || ' ' || (picked_up_at IS NOT NULL)
     FROM public.orders WHERE id = pg_temp.id('O2')),
  'picked_up true true',
  'the order is picked up, with both times recorded'
);

UPDATE public.orders SET payment_status = 'paid', status = 'delivered' WHERE id = pg_temp.id('O2');
SELECT pg_temp.claims(pg_temp.u(902));
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM public.get_assigned_rider_location(pg_temp.id('O2'))$$, 'P0001',
  'The rider''s location is not available for this order', 'the rider''s location is hidden once delivered');
SELECT throws_ok($$SELECT * FROM public.get_order_rider(pg_temp.id('O2'))$$, 'P0001',
  'Rider details are not available for this order', 'the rider''s details are hidden once delivered');

-- ---------------------------------------------------------------------------
-- Who sees offers, cancellations and flags
-- ---------------------------------------------------------------------------
SELECT pg_temp.claims(pg_temp.u(4));
SELECT is(
  (SELECT count(*) FROM public.dispatch_offers WHERE rider_id <> auth.uid()),
  0::bigint,
  'a rider sees only their own offers'
);

SELECT pg_temp.claims(pg_temp.u(901));
SELECT is(
  (SELECT count(*) FROM public.dispatch_offers) + (SELECT count(*) FROM public.cancellation_events)
  + (SELECT count(*) FROM public.admin_review_flags),
  0::bigint,
  'a customer sees no offers, cancellation records or review flags'
);

SELECT throws_ok(
  $$INSERT INTO public.dispatch_offers (order_id, round_no, attempt_no, rider_id, distance_to_pickup_m, expires_at)
    VALUES (pg_temp.id('O8'), 9, 1, pg_temp.u(4), 1, now())$$,
  '42501', NULL,
  'a client cannot create offers'
);

SELECT pg_temp.claims(pg_temp.u(903));
SELECT ok(
  (SELECT count(*) FROM public.admin_review_flags) = 2 AND (SELECT count(*) FROM public.cancellation_events) > 0,
  'an admin sees the flags and cancellations'
);
RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);

-- ---------------------------------------------------------------------------
-- No phone or account numbers in events, offers or flags
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT count(*) FROM (
     SELECT to_jsonb(e)::text AS t FROM public.order_events e
     UNION ALL SELECT to_jsonb(c)::text FROM public.cancellation_events c
     UNION ALL SELECT to_jsonb(d)::text FROM public.dispatch_offers d
     UNION ALL SELECT to_jsonb(f)::text FROM public.admin_review_flags f) rows
   WHERE EXISTS (
     SELECT 1 FROM (
       SELECT phone AS secret FROM public.profiles WHERE phone IS NOT NULL
       UNION SELECT receiver_phone FROM public.order_contacts
       UNION SELECT account_number FROM public.rider_bank_accounts) s
     WHERE rows.t LIKE '%' || s.secret || '%')),
  0::bigint,
  'no customer phone, receiver phone or rider account number appears in order events, cancellations, offers or flags'
);

SELECT throws_ok(
  $$INSERT INTO public.cancellation_events (order_id, role, stage, counted, reason)
    VALUES (pg_temp.id('O8'), 'admin', 'before_accept', false, 'Customer 2348031234567')$$,
  '23514', NULL,
  'a cancellation reason with a long number is refused by the database'
);

SELECT is(
  (SELECT array_agg(table_name || '.' || column_name) FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name IN ('dispatch_offers', 'cancellation_events', 'order_events', 'admin_review_flags')
      AND (column_name ILIKE '%phone%' OR column_name ILIKE '%account%' OR column_name ILIKE '%address%')),
  NULL,
  'offers, cancellations, order events and flags have no phone, account or address columns'
);

-- ---------------------------------------------------------------------------
-- Function privileges and search_path
-- ---------------------------------------------------------------------------
SELECT ok(
  NOT has_function_privilege('authenticated', 'public.run_dispatch_sweep()', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.run_dispatch_sweep()', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.offer_next_rider(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.begin_dispatch(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.rider_is_dispatchable(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.rider_can_take_job(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.lock_dispatch()', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.flag_after_late_cancels(uuid, text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.accept_offer(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.get_my_offer()', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.get_order_rider(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.cancel_order(uuid)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.accept_offer(uuid)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.get_assigned_rider_location(uuid)', 'EXECUTE'),
  'matching is server-only; rider and customer functions are for signed-in users only'
);

SELECT is(
  (SELECT array_agg(p.proname::text ORDER BY p.proname)
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('dispatch_offers_protect', 'lock_dispatch', 'rider_can_take_job', 'rider_is_dispatchable',
                        'compass_direction', 'flag_after_late_cancels', 'end_search_no_rider', 'offer_next_rider',
                        'begin_dispatch', 'withdraw_pending_offers', 'run_dispatch_sweep', 'start_dispatch',
                        'admin_cancel_order', 'resolve_review_flag', 'get_my_offer', 'get_my_active_job',
                        'accept_offer', 'decline_offer', 'mark_arrived_at_pickup', 'mark_picked_up',
                        'rider_cancel_job', 'cancel_order', 'retry_dispatch', 'get_order_rider',
                        'get_assigned_rider_location', 'create_order_from_quote')
      AND NOT coalesce(p.proconfig @> ARRAY['search_path=""'], false)),
  NULL,
  'every new or replaced function sets an empty search_path'
);

SELECT * FROM finish();
ROLLBACK;
