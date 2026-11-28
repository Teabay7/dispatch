-- Delivery and payment: settings, arrival at the drop-off (fresh and near, admin
-- override), who can confirm payment, "I've paid" is only a claim, the delivery PIN and
-- its lockout, refusal timing and the reported-paid rule, abandons, disputes (window,
-- outcomes, false-dispute counting), the unpaid-order block, commission counting
-- through the existing trigger, no leaks, and function privileges.
-- Run locally with: supabase db start && supabase test db
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(112);

-- ---------------------------------------------------------------------------
-- Fixtures (server context)
--   C1..C4 = customers 901, 902, 904, 905     A = admin 903
--   Riders 11..30 stand about 20 m from the drop-off D (7.7450, 4.4450).
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.u(n integer) RETURNS uuid LANGUAGE sql AS
$$ SELECT ('00000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;

CREATE FUNCTION pg_temp.claims(p uuid) RETURNS text LANGUAGE sql AS
$$ SELECT set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true) $$;

CREATE FUNCTION pg_temp.make_rider(p_n integer) RETURNS void LANGUAGE plpgsql AS $$
DECLARE id uuid := pg_temp.u(p_n);
BEGIN
  INSERT INTO auth.users (id, phone) VALUES (id, '2348000' || lpad(p_n::text, 6, '0'));
  INSERT INTO public.user_roles (user_id, role) VALUES (id, 'rider');
  INSERT INTO public.rider_details (user_id, full_name, bike_make_model, bike_colour, plate_number,
                                    id_photo_path, selfie_path, kyc_status)
  VALUES (id, 'Rider ' || p_n, 'Bajaj Boxer', 'Red', 'EDE-' || p_n, 'x/id.jpg', 'x/s.jpg', 'approved');
  INSERT INTO public.rider_bank_accounts (rider_id, bank_name, account_number, account_name, name_match,
                                          status, verified_name, verified_name_match, recorded_by, reviewed_at)
  VALUES (id, 'OPay', '70000' || lpad(p_n::text, 5, '0'), 'Rider ' || p_n, 'match', 'verified',
          'RIDER ' || p_n, 'match', 'test fixture', now());
  UPDATE public.rider_details SET is_online = true WHERE user_id = id;
  INSERT INTO public.rider_locations (rider_id, lat, lng) VALUES (id, 7.7452, 4.4450);
END $$;

-- A picked-up job for this customer and rider, paid to the rider's verified account.
CREATE FUNCTION pg_temp.job(p_customer uuid, p_rider integer) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE new_id uuid; r uuid := pg_temp.u(p_rider);
BEGIN
  INSERT INTO public.orders (customer_id, rider_id, status, pickup_address, pickup_lat, pickup_lng,
                             dropoff_address, dropoff_lat, dropoff_lng, price_kobo, commission_kobo,
                             distance_m, distance_source, accepted_at, arrived_pickup_at, picked_up_at,
                             payee_account_id)
  VALUES (p_customer, r, 'picked_up', 'TEST pickup, Ede', 7.7350, 4.4360, 'TEST drop-off, Ede', 7.7450, 4.4450,
          205000, 30750, 2350, 'routes', now(), now(), now(),
          (SELECT id FROM public.rider_bank_accounts WHERE rider_id = r AND status = 'verified'))
  RETURNING id INTO new_id;
  INSERT INTO public.order_contacts (order_id, receiver_name, receiver_phone)
  VALUES (new_id, 'Test Receiver', '2348031112222');
  RETURN new_id;
END $$;

-- Moves a rider's last location (the touch trigger would reset the time, so it is paused).
CREATE FUNCTION pg_temp.place(p_rider integer, p_lat double precision, p_lng double precision, p_age interval)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  ALTER TABLE public.rider_locations DISABLE TRIGGER rider_locations_touch;
  UPDATE public.rider_locations SET lat = p_lat, lng = p_lng, updated_at = now() - p_age
   WHERE rider_id = pg_temp.u(p_rider);
  ALTER TABLE public.rider_locations ENABLE TRIGGER rider_locations_touch;
END $$;

CREATE FUNCTION pg_temp.arrive_ago(p_order uuid, p_age interval) RETURNS void LANGUAGE sql AS
$$ UPDATE public.orders SET arrived_dropoff_at = now() - p_age WHERE id = p_order $$;

CREATE FUNCTION pg_temp.server() RETURNS text LANGUAGE sql AS
$$ SELECT set_config('request.jwt.claims', '{}', true) $$;

CREATE FUNCTION pg_temp.pin(p_order uuid) RETURNS text LANGUAGE sql AS
$$ SELECT pin FROM public.order_delivery_pins WHERE order_id = p_order $$;

CREATE FUNCTION pg_temp.charged(p_order uuid) RETURNS bigint LANGUAGE sql AS
$$ SELECT count(*) FROM public.commission_entries WHERE order_id = p_order AND type = 'commission' $$;

INSERT INTO auth.users (id, phone) VALUES
  (pg_temp.u(901), '2348000000901'), (pg_temp.u(902), '2348000000902'), (pg_temp.u(903), '2348000000903'),
  (pg_temp.u(904), '2348000000904'), (pg_temp.u(905), '2348000000905');
INSERT INTO public.user_roles (user_id, role) VALUES
  (pg_temp.u(901), 'customer'), (pg_temp.u(902), 'customer'), (pg_temp.u(903), 'admin'),
  (pg_temp.u(904), 'customer'), (pg_temp.u(905), 'customer');

SELECT pg_temp.make_rider(n) FROM generate_series(11, 30) AS n;

CREATE TEMP TABLE ids (name text PRIMARY KEY, id uuid);
GRANT SELECT ON ids TO authenticated;
CREATE FUNCTION pg_temp.id(p text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM ids WHERE name = p $$;

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT awaiting_payment_refuse_after_minutes || ' ' || customer_unpaid_flag_after || ' ' || false_dispute_flag_after
          || ' ' || delivery_pin_max_attempts || ' ' || dispute_window_days || ' ' || dropoff_arrival_radius_m
     FROM public.app_settings),
  '15 2 3 5 7 500',
  'settings: refuse after 15 min, flag after 2 abandons or 3 false disputes, 5 PIN tries, 7-day window, 500 m'
);
SELECT throws_ok($$UPDATE public.app_settings SET dispute_window_days = 0$$, '23514', NULL,
  'the dispute window must be 1 to 30 days');
SELECT throws_ok($$UPDATE public.app_settings SET dropoff_arrival_radius_m = 50$$, '23514', NULL,
  'the drop-off radius must be 100 to 5000 m');
SELECT throws_ok($$UPDATE public.app_settings SET awaiting_payment_refuse_after_minutes = 4$$, '23514', NULL,
  'the refusal wait must be 5 to 120 minutes');
SELECT throws_ok($$UPDATE public.app_settings SET customer_unpaid_flag_after = 0$$, '23514', NULL,
  'the abandon threshold must be 1 to 20');
SELECT throws_ok($$UPDATE public.app_settings SET delivery_pin_max_attempts = 2$$, '23514', NULL,
  'PIN tries must be 3 to 10');

-- ---------------------------------------------------------------------------
-- J1 (C1, rider 11): arrival checks, payment, PIN, delivered
-- ---------------------------------------------------------------------------
INSERT INTO ids VALUES ('J1', pg_temp.job(pg_temp.u(901), 11));
SELECT is((SELECT payment_reference ~ '^DSP-[0-9A-F]{6}$' FROM public.orders WHERE id = pg_temp.id('J1')), true,
  'every order has a payment reference for the transfer narration');

DELETE FROM public.rider_locations WHERE rider_id = pg_temp.u(11);
SELECT pg_temp.claims(pg_temp.u(11));
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.mark_arrived_at_dropoff(pg_temp.id('J1'))$$, 'P0001',
  'We can''t see your current location. Turn on location, keep the app open and try again',
  'arrival is refused when the rider has no location');
RESET ROLE;
INSERT INTO public.rider_locations (rider_id, lat, lng) VALUES (pg_temp.u(11), 7.7452, 4.4450);
SELECT pg_temp.place(11, 7.7452, 4.4450, interval '10 minutes');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.mark_arrived_at_dropoff(pg_temp.id('J1'))$$, 'P0001',
  'We can''t see your current location. Turn on location, keep the app open and try again',
  'arrival is refused when the location is stale');
RESET ROLE;
SELECT pg_temp.place(11, 7.7650, 4.4450, interval '0 seconds');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.mark_arrived_at_dropoff(pg_temp.id('J1'))$$, 'P0001',
  'You are not at the drop-off yet. Move closer and try again',
  'arrival is refused when the rider is about 2 km from the drop-off');
RESET ROLE;
SELECT pg_temp.place(11, 7.7490, 4.4450, interval '0 seconds');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT public.mark_arrived_at_dropoff(pg_temp.id('J1'))$$,
  'arrival is allowed about 450 m from the drop-off (radius 500 m)');
SELECT throws_ok($$SELECT public.mark_arrived_at_dropoff(pg_temp.id('J1'))$$, 'P0001',
  'You can mark arrival at the drop-off only once, after pickup', 'arrival is marked only once');
RESET ROLE;

SELECT is(
  (SELECT status || ' ' || payment_status || ' ' || (arrived_dropoff_at IS NOT NULL) FROM public.orders WHERE id = pg_temp.id('J1')),
  'picked_up awaiting_payment true',
  'arrival makes payment due'
);

SELECT pg_temp.claims(pg_temp.u(12));
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.confirm_payment_received(pg_temp.id('J1'))$$, 'P0001', 'Job not found',
  'another rider cannot confirm payment');
RESET ROLE;

SELECT pg_temp.claims(pg_temp.u(901));
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.confirm_payment_received(pg_temp.id('J1'))$$, 'P0001', 'Job not found',
  'the customer cannot confirm payment');
SELECT throws_ok($$SELECT public.mark_arrived_at_dropoff(pg_temp.id('J1'))$$, 'P0001', 'Job not found',
  'the customer cannot mark arrival');
SELECT is((SELECT account_number IS NOT NULL FROM public.get_order_rider(pg_temp.id('J1'))), true,
  'while payment is due the customer sees the rider''s bank details');
SELECT throws_ok($$SELECT public.get_delivery_pin(pg_temp.id('J1'))$$, 'P0001',
  'The delivery PIN shows after the rider confirms your payment', 'no PIN before payment is confirmed');
SELECT throws_ok($$SELECT * FROM public.get_order_receipt(pg_temp.id('J1'))$$, 'P0001',
  'There is no receipt until the payment is confirmed', 'no receipt before payment is confirmed');
SELECT lives_ok($$SELECT public.report_payment_sent(pg_temp.id('J1'))$$, 'the customer can report paying');
DO $$ BEGIN UPDATE public.orders SET payment_status = 'paid' WHERE id = pg_temp.id('J1');
EXCEPTION WHEN OTHERS THEN NULL; END $$;
RESET ROLE;
SELECT is(
  (SELECT payment_status || ' ' || (customer_reported_paid_at IS NOT NULL) FROM public.orders WHERE id = pg_temp.id('J1')),
  'awaiting_payment true',
  '"I''ve paid" is only a claim, and a client cannot set payment_status directly'
);
CREATE TEMP TABLE reported AS SELECT customer_reported_paid_at AS t FROM public.orders WHERE id = pg_temp.id('J1');
SELECT pg_temp.claims(pg_temp.u(901));
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT public.report_payment_sent(pg_temp.id('J1'))$$, 'reporting again is harmless');
RESET ROLE;
SELECT is((SELECT customer_reported_paid_at FROM public.orders WHERE id = pg_temp.id('J1')), (SELECT t FROM reported),
  'reporting again keeps the first time');

SELECT pg_temp.claims(pg_temp.u(11));
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.report_payment_sent(pg_temp.id('J1'))$$, 'P0001', 'Order not found',
  'the rider cannot report the customer''s payment');
SELECT is((SELECT can_raise_dispute FROM public.get_job_payment_info(pg_temp.id('J1'))), true,
  'the rider can raise a dispute while payment is due');
SELECT throws_ok($$SELECT * FROM public.complete_delivery(pg_temp.id('J1'), '0000')$$, 'P0001',
  'Confirm the payment before handing over', 'nothing is handed over before payment is confirmed');
SELECT lives_ok($$SELECT public.confirm_payment_received(pg_temp.id('J1'))$$, 'the order''s rider confirms payment');
SELECT lives_ok($$SELECT public.confirm_payment_received(pg_temp.id('J1'))$$, 'confirming again is harmless');
SELECT throws_ok($$SELECT public.get_delivery_pin(pg_temp.id('J1'))$$, 'P0001', 'Order not found',
  'the rider cannot read the delivery PIN');
SELECT throws_ok($$SELECT * FROM public.order_delivery_pins$$, '42501', NULL,
  'clients cannot read the PIN table');
RESET ROLE;

SELECT is(
  (SELECT payment_status || ' ' || payment_confirmed_by || ' ' || (payment_confirmed_at IS NOT NULL)
     FROM public.orders WHERE id = pg_temp.id('J1')),
  'paid rider true',
  'payment is confirmed by the rider'
);
SELECT is(pg_temp.charged(pg_temp.id('J1')), 0::bigint, 'nothing is charged before the order ends');

SELECT pg_temp.claims(pg_temp.u(901));
SET LOCAL ROLE authenticated;
SELECT is(public.get_delivery_pin(pg_temp.id('J1')) ~ '^[0-9]{4}$', true,
  'after payment the customer sees a 4-digit delivery PIN');
SELECT is((SELECT account_number FROM public.get_order_rider(pg_temp.id('J1'))), NULL,
  'after payment the bank details are hidden again');
RESET ROLE;

SELECT pg_temp.claims(pg_temp.u(11));
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT result || ' ' || attempts_left FROM public.complete_delivery(pg_temp.id('J1'), 'abcd')),
  'wrong_pin 4',
  'a malformed PIN is counted as a wrong try'
);
RESET ROLE;
CREATE TEMP TABLE pins AS SELECT pg_temp.id('J1') AS order_id, pg_temp.pin(pg_temp.id('J1')) AS pin;
GRANT SELECT ON pins TO authenticated;
SELECT pg_temp.claims(pg_temp.u(11));
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT result FROM public.complete_delivery(pg_temp.id('J1'), (SELECT pin FROM pins))),
  'delivered',
  'the receiver''s PIN completes the delivery'
);
SELECT is(
  (SELECT result FROM public.complete_delivery(pg_temp.id('J1'), (SELECT pin FROM pins))),
  'delivered',
  'completing again is harmless'
);
RESET ROLE;

SELECT is(
  (SELECT status || ' ' || payment_status || ' ' || (delivered_at IS NOT NULL) FROM public.orders WHERE id = pg_temp.id('J1')),
  'delivered paid true',
  'the order ends delivered and paid'
);
SELECT is(pg_temp.charged(pg_temp.id('J1')), 1::bigint, 'a delivered, paid trip is charged once (existing trigger)');

SELECT pg_temp.claims(pg_temp.u(901));
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT rider_name || ' | ' || plate_number || ' | ' || account_masked || ' | ' || payment_confirmed_by
     FROM public.get_order_receipt(pg_temp.id('J1'))),
  'Rider 11 | EDE-11 | ••••0011 | rider',
  'the receipt shows the rider, plate and a masked account number'
);
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Admin arrival override (J2: C2, rider 13 with no location)
-- ---------------------------------------------------------------------------
INSERT INTO ids VALUES ('J2', pg_temp.job(pg_temp.u(902), 13));
DELETE FROM public.rider_locations WHERE rider_id = pg_temp.u(13);
SELECT pg_temp.claims(pg_temp.u(13));
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.admin_mark_arrived_at_dropoff(pg_temp.id('J2'), 'GPS off', 'me')$$, 'P0001',
  'Only an admin can mark arrival this way', 'a rider cannot use the admin override');
RESET ROLE;
SELECT pg_temp.server();
SELECT throws_ok($$SELECT public.admin_mark_arrived_at_dropoff(pg_temp.id('J2'), ' ', 'Admin')$$, 'P0001',
  'A note and who is recording it are required', 'the override needs a note');
SELECT throws_ok($$SELECT public.admin_mark_arrived_at_dropoff(pg_temp.id('J2'), 'Rider phoned from 08031234567', 'Admin')$$,
  'P0001', 'Do not put phone or account numbers in the note', 'the override note refuses long numbers');
SELECT lives_ok($$SELECT public.admin_mark_arrived_at_dropoff(pg_temp.id('J2'), 'Rider phoned: GPS not working', 'Admin')$$,
  'an admin can mark arrival when the location cannot confirm it');
SELECT is(
  (SELECT o.payment_status || ' ' || a.action || ' ' || a.recorded_by
     FROM public.orders o JOIN public.order_admin_actions a ON a.order_id = o.id WHERE o.id = pg_temp.id('J2')),
  'awaiting_payment arrived_dropoff Admin',
  'the override makes payment due and is recorded with who and why'
);

-- ---------------------------------------------------------------------------
-- PIN lockout (J2 continues)
-- ---------------------------------------------------------------------------
SELECT pg_temp.claims(pg_temp.u(13));
SET LOCAL ROLE authenticated;
SELECT public.confirm_payment_received(pg_temp.id('J2'));
SELECT public.complete_delivery(pg_temp.id('J2'), 'abcd') FROM generate_series(1, 4);
SELECT is((SELECT result || ' ' || attempts_left FROM public.complete_delivery(pg_temp.id('J2'), 'abcd')),
  'locked 0', 'the 5th wrong PIN locks handover');
RESET ROLE;
INSERT INTO pins SELECT pg_temp.id('J2'), pg_temp.pin(pg_temp.id('J2'));
SELECT pg_temp.claims(pg_temp.u(13));
SET LOCAL ROLE authenticated;
SELECT is((SELECT result FROM public.complete_delivery(pg_temp.id('J2'), (SELECT pin FROM pins WHERE order_id = pg_temp.id('J2')))),
  'locked', 'once locked, even the right PIN is refused');
SELECT is((SELECT pin_locked FROM public.get_job_payment_info(pg_temp.id('J2'))), true, 'the job screen sees the lock');
RESET ROLE;
SELECT pg_temp.server();
SELECT lives_ok($$SELECT public.admin_complete_delivery(pg_temp.id('J2'), 'Receiver confirmed by phone', 'Admin')$$,
  'an admin can complete a locked delivery');
SELECT is(
  (SELECT status || ' ' || (SELECT count(*) FROM public.order_admin_actions WHERE order_id = pg_temp.id('J2'))
     FROM public.orders WHERE id = pg_temp.id('J2')),
  'delivered 2',
  'the delivery is completed and the admin action recorded'
);
SELECT is(pg_temp.charged(pg_temp.id('J2')), 1::bigint, 'an admin-completed paid delivery is charged once');

-- ---------------------------------------------------------------------------
-- Refusal timing and abandons (C3: J3 rider 15, J4 rider 16)
-- ---------------------------------------------------------------------------
INSERT INTO ids VALUES ('J3', pg_temp.job(pg_temp.u(904), 15));
SELECT pg_temp.claims(pg_temp.u(15));
SET LOCAL ROLE authenticated;
SELECT public.mark_arrived_at_dropoff(pg_temp.id('J3'));
SELECT throws_ok($$SELECT public.mark_payment_refused(pg_temp.id('J3'))$$, 'P0001',
  'Give the customer more time to pay before marking the order unpaid', 'refusal is not allowed straight away');
RESET ROLE;
SELECT pg_temp.arrive_ago(pg_temp.id('J3'), interval '14 minutes');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.mark_payment_refused(pg_temp.id('J3'))$$, 'P0001',
  'Give the customer more time to pay before marking the order unpaid', 'refusal is not allowed at 14 minutes');
RESET ROLE;
SELECT pg_temp.arrive_ago(pg_temp.id('J3'), interval '15 minutes 1 second');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT public.mark_payment_refused(pg_temp.id('J3'))$$, 'refusal is allowed after 15 minutes');
SELECT is(public.get_my_active_job(), NULL, 'a refused order frees the rider');
RESET ROLE;
SELECT is(
  (SELECT status || ' ' || payment_status || ' ' || (payment_failed_at IS NOT NULL) FROM public.orders WHERE id = pg_temp.id('J3')),
  'payment_failed failed true',
  'the order ends refused'
);
SELECT is(pg_temp.charged(pg_temp.id('J3')), 0::bigint, 'a refused, unpaid order is not charged');
SELECT is((SELECT count(*) FROM public.admin_review_flags WHERE user_id = pg_temp.u(904)), 0::bigint,
  'one abandon does not flag the customer');
SELECT is(public.customer_has_unsettled_order(pg_temp.u(904)), false, 'a refused order does not block new orders');

UPDATE public.app_settings SET awaiting_payment_refuse_after_minutes = 30;
INSERT INTO ids VALUES ('J4', pg_temp.job(pg_temp.u(904), 16));
SELECT pg_temp.claims(pg_temp.u(16));
SET LOCAL ROLE authenticated;
SELECT public.mark_arrived_at_dropoff(pg_temp.id('J4'));
RESET ROLE;
SELECT pg_temp.arrive_ago(pg_temp.id('J4'), interval '20 minutes');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.mark_payment_refused(pg_temp.id('J4'))$$, 'P0001',
  'Give the customer more time to pay before marking the order unpaid', 'the refusal wait follows the setting (30 min)');
RESET ROLE;
SELECT pg_temp.arrive_ago(pg_temp.id('J4'), interval '31 minutes');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT public.mark_payment_refused(pg_temp.id('J4'))$$, 'refusal is allowed after the set wait');
RESET ROLE;
UPDATE public.app_settings SET awaiting_payment_refuse_after_minutes = 15;
SELECT is(
  (SELECT string_agg(role || ' ' || reason, ',') FROM public.admin_review_flags
    WHERE user_id = pg_temp.u(904) AND resolved_at IS NULL),
  'customer unpaid_abandons',
  'two abandons open one review flag'
);

-- ---------------------------------------------------------------------------
-- Reported paid: no refusal, the rider disputes, an admin decides (C4: J5 rider 17)
-- ---------------------------------------------------------------------------
INSERT INTO ids VALUES ('J5', pg_temp.job(pg_temp.u(905), 17));
SELECT pg_temp.claims(pg_temp.u(17));
SET LOCAL ROLE authenticated;
SELECT public.mark_arrived_at_dropoff(pg_temp.id('J5'));
RESET ROLE;
SELECT pg_temp.claims(pg_temp.u(905));
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.raise_payment_dispute(pg_temp.id('J5'), 'paid_not_confirmed', NULL)$$, 'P0001',
  'You can''t report a payment problem on this order now', 'the customer can dispute only after reporting paid');
SELECT public.report_payment_sent(pg_temp.id('J5'));
RESET ROLE;
SELECT pg_temp.arrive_ago(pg_temp.id('J5'), interval '20 minutes');
SELECT pg_temp.claims(pg_temp.u(17));
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.mark_payment_refused(pg_temp.id('J5'))$$, 'P0001',
  'The customer says they have paid. Report a problem instead, and Dispatch will decide',
  'a rider cannot mark an order unpaid once the customer has reported paying');
SELECT throws_ok($$SELECT public.raise_payment_dispute(pg_temp.id('J5'), 'payment_not_received', 'Call 08031234567')$$,
  'P0001', 'Do not put phone or account numbers in the details', 'dispute details refuse long numbers');
SELECT throws_ok($$SELECT public.raise_payment_dispute(pg_temp.id('J5'), 'payment_not_received', 'Call 0803 123-4567')$$,
  'P0001', 'Do not put phone or account numbers in the details', 'dispute details refuse numbers typed with spaces');
SELECT throws_ok($$SELECT public.raise_payment_dispute(pg_temp.id('J5'), 'because', NULL)$$, 'P0001', 'Choose a reason',
  'a dispute needs a listed reason');
SELECT lives_ok($$SELECT public.raise_payment_dispute(pg_temp.id('J5'), 'payment_not_received', 'Nothing in my bank app')$$,
  'the rider raises a dispute instead');
RESET ROLE;

SELECT pg_temp.claims(pg_temp.u(905));
SET LOCAL ROLE authenticated;
SELECT is((SELECT reason FROM public.get_my_order_block()), 'rider_dispute',
  'an open dispute raised by the rider blocks the customer');
SELECT throws_ok($$SELECT public.create_order_from_quote(gen_random_uuid(), 'Box', 'Ada', '2348031234567')$$, 'P0001',
  'Settle your unpaid order before placing a new one', 'a blocked customer cannot place a new order');
SELECT throws_ok($$SELECT public.raise_payment_dispute(pg_temp.id('J5'), 'paid_not_confirmed', NULL)$$, 'P0001',
  'A problem is already open on this order. Dispatch will contact you', 'one open dispute per order');
SELECT is((SELECT dispute_status || ' ' || raised_as FROM public.get_order_dispute(pg_temp.id('J5'))), 'open rider',
  'the customer sees that the rider opened a dispute');
SELECT is((SELECT count(*) FROM public.order_payment_disputes), 0::bigint, 'clients cannot read disputes directly');
SELECT throws_ok($$SELECT public.resolve_payment_dispute(
    (SELECT id FROM public.order_payment_disputes LIMIT 1), 'paid', false, 'x', 'me')$$, 'P0001',
  'Only an admin can resolve disputes', 'a customer cannot resolve a dispute');
RESET ROLE;

SELECT pg_temp.claims(pg_temp.u(901));
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.raise_payment_dispute(pg_temp.id('J5'), 'other', NULL)$$, 'P0001', 'Order not found',
  'someone else''s order cannot be disputed');
RESET ROLE;

SELECT pg_temp.server();
SELECT throws_ok($$SELECT public.resolve_payment_dispute(
    (SELECT id FROM public.order_payment_disputes WHERE order_id = pg_temp.id('J5')), 'maybe', false, 'x', 'Admin')$$,
  'P0001', 'The outcome must be paid or not_paid', 'a dispute outcome must be paid or not_paid');
SELECT lives_ok($$SELECT public.resolve_payment_dispute(
    (SELECT id FROM public.order_payment_disputes WHERE order_id = pg_temp.id('J5')), 'not_paid', false,
    'Customer could not show a transfer', 'Admin')$$,
  'an admin resolves the rider''s dispute as not paid');
SELECT is(
  (SELECT status || ' ' || payment_status FROM public.orders WHERE id = pg_temp.id('J5')),
  'payment_failed failed',
  'not paid: the order ends refused'
);
SELECT is(public.customer_has_unsettled_order(pg_temp.u(905)), false, 'the block lifts once the dispute is resolved');
SELECT is((SELECT count(*) FROM public.admin_review_flags WHERE user_id = pg_temp.u(17)), 0::bigint,
  'a genuine dispute is not counted against the rider');
SELECT throws_ok($$SELECT public.resolve_payment_dispute(
    (SELECT id FROM public.order_payment_disputes WHERE order_id = pg_temp.id('J5')), 'paid', false, 'x', 'Admin')$$,
  'P0001', 'This dispute is not open', 'a dispute is resolved only once');

-- ---------------------------------------------------------------------------
-- False disputes by a rider (rider 18, three jobs for C2), resolved as paid
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.false_rider_dispute(p_name text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO ids VALUES (p_name, pg_temp.job(pg_temp.u(902), 18));
  PERFORM pg_temp.claims(pg_temp.u(18));
  PERFORM public.mark_arrived_at_dropoff(pg_temp.id(p_name));
  PERFORM public.raise_payment_dispute(pg_temp.id(p_name), 'payment_not_received', 'No credit seen');
  PERFORM pg_temp.server();
  PERFORM public.resolve_payment_dispute(
    (SELECT id FROM public.order_payment_disputes WHERE order_id = pg_temp.id(p_name)), 'paid', true,
    'Customer showed the bank debit; rider had the credit', 'Admin');
END $$;

SELECT pg_temp.false_rider_dispute('F1');
SELECT is(
  (SELECT o.payment_status || ' ' || o.payment_confirmed_by || ' ' || (pg_temp.pin(o.id) IS NOT NULL)
     FROM public.orders o WHERE o.id = pg_temp.id('F1')),
  'paid admin true',
  'resolved as paid before handover: paid by admin and a PIN is created'
);
SELECT is((SELECT count(*) FROM public.admin_review_flags WHERE user_id = pg_temp.u(18)), 0::bigint,
  'one false dispute does not flag the rider');
SELECT public.admin_complete_delivery(pg_temp.id('F1'), 'Handed over', 'Admin');
SELECT pg_temp.false_rider_dispute('F2');
SELECT public.admin_complete_delivery(pg_temp.id('F2'), 'Handed over', 'Admin');
SELECT pg_temp.false_rider_dispute('F3');
SELECT is(
  (SELECT string_agg(role || ' ' || reason, ',') FROM public.admin_review_flags
    WHERE user_id = pg_temp.u(18) AND resolved_at IS NULL),
  'rider false_disputes',
  'three false disputes open one review flag for the rider'
);
SELECT public.admin_complete_delivery(pg_temp.id('F3'), 'Handed over', 'Admin');

-- A false dispute by a customer counts against the customer, not the rider.
INSERT INTO ids VALUES ('J6', pg_temp.job(pg_temp.u(901), 19));
SELECT pg_temp.claims(pg_temp.u(19));
SET LOCAL ROLE authenticated;
SELECT public.mark_arrived_at_dropoff(pg_temp.id('J6'));
RESET ROLE;
SELECT pg_temp.claims(pg_temp.u(901));
SET LOCAL ROLE authenticated;
SELECT public.report_payment_sent(pg_temp.id('J6'));
SELECT lives_ok($$SELECT public.raise_payment_dispute(pg_temp.id('J6'), 'paid_not_confirmed', 'I sent it at noon')$$,
  'the customer can dispute after reporting paid');
SELECT is((SELECT count(*) FROM public.get_my_order_block()), 0::bigint,
  'the customer''s own dispute does not block them');
RESET ROLE;
SELECT pg_temp.server();
SELECT public.resolve_payment_dispute((SELECT id FROM public.order_payment_disputes WHERE order_id = pg_temp.id('J6')),
  'not_paid', true, 'No transfer found', 'Admin');
SELECT is(
  (SELECT count(*) FROM public.order_payment_disputes WHERE raised_by = pg_temp.u(901) AND raised_as = 'customer' AND found_false)
  || ' ' || (SELECT count(*) FROM public.order_payment_disputes WHERE raised_by = pg_temp.u(19) AND found_false),
  '1 0',
  'a false customer dispute counts against the customer only'
);

-- ---------------------------------------------------------------------------
-- The dispute window, and "a confirmed payment counts however it ends"
-- ---------------------------------------------------------------------------
UPDATE public.orders SET payment_failed_at = now() - interval '8 days' WHERE id = pg_temp.id('J3');
SELECT pg_temp.claims(pg_temp.u(904));
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.raise_payment_dispute(pg_temp.id('J3'), 'paid_not_confirmed', NULL)$$, 'P0001',
  'You can''t report a payment problem on this order now', 'no dispute 8 days after the order ended (window 7)');
RESET ROLE;
UPDATE public.app_settings SET dispute_window_days = 10;
SELECT pg_temp.claims(pg_temp.u(904));
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT public.raise_payment_dispute(pg_temp.id('J3'), 'paid_not_confirmed', 'Paid late')$$,
  'the window follows the setting (10 days)');
RESET ROLE;
UPDATE public.app_settings SET dispute_window_days = 7;
SELECT pg_temp.server();
SELECT public.resolve_payment_dispute((SELECT id FROM public.order_payment_disputes WHERE order_id = pg_temp.id('J3')),
  'paid', false, 'Rider found the transfer', 'Admin');
SELECT is(
  (SELECT status || ' ' || payment_status || ' ' || pg_temp.charged(id) FROM public.orders WHERE id = pg_temp.id('J3')),
  'payment_failed paid 1',
  'a refused order later found paid is charged (counts however it ends)'
);

-- Admin cancel after a confirmed payment still counts.
INSERT INTO ids VALUES ('J7', pg_temp.job(pg_temp.u(902), 20));
SELECT pg_temp.claims(pg_temp.u(20));
SET LOCAL ROLE authenticated;
SELECT public.mark_arrived_at_dropoff(pg_temp.id('J7'));
SELECT public.confirm_payment_received(pg_temp.id('J7'));
RESET ROLE;
SELECT pg_temp.server();
SELECT public.admin_cancel_order(pg_temp.id('J7'), 'customer', 'Package damaged; returned', 'Admin');
SELECT is(
  (SELECT status || ' ' || payment_status || ' ' || pg_temp.charged(id) FROM public.orders WHERE id = pg_temp.id('J7')),
  'cancelled_by_customer paid 1',
  'an admin cancel after a confirmed payment is still charged'
);

-- ---------------------------------------------------------------------------
-- Delivered but unpaid: the rider disputes after handover, then it is settled
-- ---------------------------------------------------------------------------
SELECT pg_temp.claims(pg_temp.u(11));
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT public.raise_payment_dispute(pg_temp.id('J1'), 'payment_not_received', 'Credit was reversed')$$,
  'the rider can dispute a delivered order within the window');
RESET ROLE;
SELECT pg_temp.server();
SELECT public.resolve_payment_dispute((SELECT id FROM public.order_payment_disputes WHERE order_id = pg_temp.id('J1')),
  'not_paid', false, 'Bank reversed the transfer', 'Admin');
SELECT pg_temp.claims(pg_temp.u(901));
SET LOCAL ROLE authenticated;
SELECT is((SELECT reason FROM public.get_my_order_block()), 'unpaid_delivery',
  'a delivered order found unpaid blocks the customer');
RESET ROLE;
SELECT pg_temp.claims(pg_temp.u(11));
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.admin_confirm_payment(pg_temp.id('J1'), 'Paid', 'me')$$, 'P0001',
  'Only an admin can confirm payment this way', 'a rider cannot use admin settlement');
RESET ROLE;
SELECT pg_temp.server();
SELECT lives_ok($$SELECT public.admin_confirm_payment(pg_temp.id('J1'), 'Customer paid again; rider confirmed by phone', 'Admin')$$,
  'an admin can settle the unpaid order');
SELECT is(public.customer_has_unsettled_order(pg_temp.u(901)), false, 'settling lifts the block');
SELECT is(pg_temp.charged(pg_temp.id('J1')), 1::bigint, 'settling does not charge the trip twice');

-- Support opens a dispute for the rider outside the window (no history screen yet).
UPDATE public.orders SET delivered_at = now() - interval '20 days' WHERE id = pg_temp.id('J2');
SELECT lives_ok($$SELECT public.admin_open_payment_dispute(pg_temp.id('J2'), 'rider', 'payment_not_received',
    'Rider called support: credit never arrived', 'Admin')$$,
  'an admin can open a dispute for the rider, outside the window');
SELECT is((SELECT reason FROM public.customer_unsettled_order(pg_temp.u(902))), 'rider_dispute',
  'a dispute opened for the rider blocks the customer');
SELECT public.resolve_payment_dispute((SELECT id FROM public.order_payment_disputes
                                        WHERE order_id = pg_temp.id('J2') AND status = 'open'),
  'paid', false, 'Credit found after all', 'Admin');
SELECT is(public.customer_has_unsettled_order(pg_temp.u(902)), false, 'resolving it as paid lifts the block');

-- ---------------------------------------------------------------------------
-- Order of steps
-- ---------------------------------------------------------------------------
INSERT INTO ids VALUES ('J8', pg_temp.job(pg_temp.u(902), 21));
UPDATE public.orders SET status = 'accepted', picked_up_at = NULL WHERE id = pg_temp.id('J8');
SELECT pg_temp.claims(pg_temp.u(21));
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.mark_arrived_at_dropoff(pg_temp.id('J8'))$$, 'P0001',
  'You can mark arrival at the drop-off only once, after pickup', 'no arrival at the drop-off before pickup');
SELECT throws_ok($$SELECT public.confirm_payment_received(pg_temp.id('J8'))$$, 'P0001',
  'You can confirm payment only at the drop-off, while payment is due', 'no payment confirmation before arrival');
SELECT throws_ok($$SELECT public.mark_payment_refused(pg_temp.id('J8'))$$, 'P0001',
  'You can mark an order unpaid only while payment is due', 'no refusal before arrival');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- No leaks
-- ---------------------------------------------------------------------------
SELECT pg_temp.server();
SELECT is(
  (SELECT count(*) FROM (
     SELECT to_jsonb(e)::text AS t FROM public.order_events e
     UNION ALL SELECT to_jsonb(d)::text FROM public.order_payment_disputes d
     UNION ALL SELECT to_jsonb(a)::text FROM public.order_admin_actions a
     UNION ALL SELECT to_jsonb(f)::text FROM public.admin_review_flags f) rows
   WHERE EXISTS (
     SELECT 1 FROM (
       SELECT phone AS secret FROM public.profiles WHERE phone IS NOT NULL
       UNION SELECT receiver_phone FROM public.order_contacts
       UNION SELECT account_number FROM public.rider_bank_accounts) s
     WHERE rows.t LIKE '%' || s.secret || '%')),
  0::bigint,
  'no phone or account number appears in order events, disputes, admin actions or flags'
);
SELECT throws_ok(
  $$INSERT INTO public.order_payment_disputes (order_id, raised_by, raised_as, reason, details)
    VALUES (pg_temp.id('J8'), pg_temp.u(902), 'customer', 'other', 'Account 7000000021')$$,
  '23514', NULL, 'the database refuses dispute details with a long number'
);
SELECT is(
  (SELECT array_agg(table_name || '.' || column_name ORDER BY table_name) FROM information_schema.columns
    WHERE table_schema = 'public' AND column_name ILIKE '%pin%' AND column_name NOT ILIKE '%ping%'
      AND table_name <> 'app_settings'),
  ARRAY['order_delivery_pins.pin'],
  'the delivery PIN is stored in one place only'
);
SELECT is(
  (SELECT array_agg(table_name || '.' || column_name) FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name IN ('order_payment_disputes', 'order_admin_actions', 'order_delivery_pins')
      AND (column_name ILIKE '%phone%' OR column_name ILIKE '%account%' OR column_name ILIKE '%address%')),
  NULL,
  'disputes, admin actions and PINs have no phone, account or address columns'
);
SELECT is(
  (SELECT array_agg(p.proname::text ORDER BY p.proname)
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('mark_arrived_at_dropoff', 'confirm_payment_received', 'mark_payment_refused',
                        'complete_delivery', 'get_job_payment_info', 'report_payment_sent', 'get_delivery_pin',
                        'get_order_receipt', 'get_my_order_block', 'raise_payment_dispute', 'get_order_dispute',
                        'resolve_payment_dispute', 'admin_confirm_payment', 'admin_complete_delivery',
                        'admin_mark_arrived_at_dropoff', 'admin_open_payment_dispute', 'create_order_from_quote',
                        'check_admin_text', 'apply_payment_confirmed', 'apply_payment_refused')
      AND EXISTS (SELECT 1 FROM regexp_matches(p.prosrc, 'RAISE EXCEPTION ''([^'']*)''', 'g') m
                   WHERE m[1] ~ '[0-9]' AND m[1] !~ '^Describe the package')),
  NULL,
  'no error message in the delivery and payment functions contains a number'
);

-- ---------------------------------------------------------------------------
-- RLS and function privileges
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT array_agg(c.relname::text ORDER BY c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname IN ('order_delivery_pins', 'order_payment_disputes', 'order_admin_actions')
      AND c.relrowsecurity),
  ARRAY['order_admin_actions', 'order_delivery_pins', 'order_payment_disputes'],
  'RLS is on for the new tables'
);

SELECT ok(
  NOT has_function_privilege('authenticated', 'public.apply_payment_confirmed(uuid, text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.apply_payment_refused(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.customer_has_unsettled_order(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.customer_unsettled_order(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.new_delivery_pin()', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.open_review_flag(uuid, text, text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.flag_after_unpaid_abandons(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.flag_after_false_disputes(uuid, text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.can_raise_dispute(public.orders, text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.order_ended_at(public.orders)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.is_admin_caller()', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.check_admin_text(text, text)', 'EXECUTE'),
  'helpers are not callable by signed-in users'
);

SELECT ok(
  NOT has_function_privilege('anon', 'public.mark_arrived_at_dropoff(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.confirm_payment_received(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.mark_payment_refused(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.complete_delivery(uuid, text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.report_payment_sent(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.get_delivery_pin(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.raise_payment_dispute(uuid, text, text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.resolve_payment_dispute(uuid, text, boolean, text, text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.admin_confirm_payment(uuid, text, text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.admin_mark_arrived_at_dropoff(uuid, text, text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.get_my_order_block()', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.confirm_payment_received(uuid)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.complete_delivery(uuid, text)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.report_payment_sent(uuid)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.get_my_order_block()', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.resolve_payment_dispute(uuid, text, boolean, text, text)', 'EXECUTE'),
  'rider and customer functions are for signed-in users only; admin functions check the caller inside'
);

SELECT is(
  (SELECT array_agg(p.proname::text ORDER BY p.proname)
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('is_admin_caller', 'open_review_flag', 'flag_after_unpaid_abandons', 'flag_after_false_disputes',
                        'customer_unsettled_order', 'customer_has_unsettled_order', 'order_ended_at',
                        'can_raise_dispute', 'new_delivery_pin', 'apply_payment_confirmed', 'apply_payment_refused',
                        'check_admin_text', 'mark_arrived_at_dropoff', 'confirm_payment_received',
                        'mark_payment_refused', 'complete_delivery', 'get_job_payment_info', 'report_payment_sent',
                        'get_delivery_pin', 'get_order_receipt', 'get_my_order_block', 'raise_payment_dispute',
                        'get_order_dispute', 'resolve_payment_dispute', 'admin_confirm_payment',
                        'admin_complete_delivery', 'admin_mark_arrived_at_dropoff', 'admin_open_payment_dispute',
                        'create_order_from_quote')
      AND NOT coalesce(p.proconfig @> ARRAY['search_path=""'], false)),
  NULL,
  'every new or replaced function sets an empty search_path'
);

SELECT * FROM finish();
ROLLBACK;
