-- Customer orders: pricing, quotes (service area, max distance, customer role),
-- rate limits and the daily Google cap, creating an order from a quote (no client
-- prices), the active-order limit, the address and price lock, cancelling, who can
-- see orders, quotes and contacts, the contact function, and privileges.
-- Run locally with: supabase db start && supabase test db
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(67);

-- Users
--   c1, c2 = customers      r1 = approved rider (verified bank account)
--   r2 = rider without a customer role      a1 = admin
-- Switching user: set the JWT claims and SET LOCAL ROLE authenticated.
-- Back to server context: RESET ROLE and clear the claims ('{}' => auth.role() is NULL).

-- ---------------------------------------------------------------------------
-- Fixtures (server context)
-- ---------------------------------------------------------------------------
INSERT INTO auth.users (id, phone) VALUES
  ('00000000-0000-0000-0000-00000000a101', '2348000000801'),
  ('00000000-0000-0000-0000-00000000a102', '2348000000802'),
  ('00000000-0000-0000-0000-00000000a103', '2348000000803'),
  ('00000000-0000-0000-0000-00000000a104', '2348000000804'),
  ('00000000-0000-0000-0000-00000000a105', '2348000000805');

INSERT INTO public.user_roles (user_id, role) VALUES
  ('00000000-0000-0000-0000-00000000a101', 'customer'),
  ('00000000-0000-0000-0000-00000000a102', 'customer'),
  ('00000000-0000-0000-0000-00000000a103', 'rider'),
  ('00000000-0000-0000-0000-00000000a104', 'admin'),
  ('00000000-0000-0000-0000-00000000a105', 'rider');

INSERT INTO public.rider_details
  (user_id, full_name, bike_make_model, bike_colour, plate_number, id_photo_path, selfie_path, kyc_status)
VALUES ('00000000-0000-0000-0000-00000000a103', 'Rider One', 'Bajaj', 'Red', 'EDE-O01', 'o/id.jpg', 'o/s.jpg', 'approved');

-- Places inside Ede and one outside (Osogbo).
CREATE FUNCTION pg_temp.quote(p_customer uuid, p_distance integer DEFAULT 2350,
                              p_source public.order_distance_source DEFAULT 'routes')
RETURNS public.order_quotes LANGUAGE sql AS $$
  SELECT public.create_order_quote(p_customer, 'Ede Central Mosque', 7.7350, 4.4360, 'place-a',
                                   'Federal Polytechnic Ede', 7.7450, 4.4450, 'place-b',
                                   p_distance, p_source);
$$;

-- ---------------------------------------------------------------------------
-- Pricing (D1)
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT base_fee_kobo::text || ' ' || per_km_rate_kobo::text || ' ' || max_order_distance_m::text || ' '
          || quote_valid_minutes::text || ' ' || quotes_per_hour::text || ' ' || place_searches_per_hour::text
          || ' ' || google_calls_per_day::text || ' ' || max_active_orders_per_customer::text
     FROM public.app_settings),
  '60000 60000 20000 15 20 300 2000 2',
  'settings: ₦600 base, ₦600/km, 20 km max, 15-minute quotes, rate limits, daily cap, 2 active orders'
);

SELECT is(
  ARRAY[public.price_for_distance(0, 60000, 60000),     -- base fee only
        public.price_for_distance(1, 60000, 60000),     -- 1 started 100 m: ₦660 -> ₦700
        public.price_for_distance(100, 60000, 60000),   -- exactly 100 m: still 1 unit
        public.price_for_distance(101, 60000, 60000),   -- 2 units: ₦720 -> ₦750
        public.price_for_distance(2350, 60000, 60000),  -- 24 units: ₦2,040 -> ₦2,050
        public.price_for_distance(5000, 60000, 60000)], -- 50 units: ₦3,600, already a multiple of ₦50
  ARRAY[60000, 70000, 70000, 75000, 205000, 360000]::bigint[],
  'price = base + per km per started 100 m, rounded up to the nearest ₦50'
);

SELECT is(
  public.price_for_distance(150, 60000, 12345),
  65000::bigint,
  'a per-km rate that is not a multiple of 10 still rounds up correctly'
);

SELECT throws_ok(
  $$SELECT public.price_for_distance(-1, 60000, 60000)$$,
  'P0001', 'The distance must be zero or more',
  'a negative distance is refused'
);

-- ---------------------------------------------------------------------------
-- Quotes (made by the Edge Function as service_role; here as the server)
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE q1 AS SELECT * FROM pg_temp.quote('00000000-0000-0000-0000-00000000a101');
GRANT SELECT ON q1 TO authenticated, service_role;

SELECT is(
  (SELECT price_kobo::text || ' ' || commission_kobo::text || ' ' || distance_source::text || ' '
          || base_fee_kobo::text || ' ' || per_km_rate_kobo::text || ' ' || commission_bps::text || ' '
          || (expires_at = now() + interval '15 minutes')::text FROM q1),
  '205000 30750 routes 60000 60000 1500 true',
  'a 2.35 km quote is ₦2,050 with ₦307.50 commission, the pricing copied, valid 15 minutes'
);

SELECT is(
  (SELECT distance_source::text FROM pg_temp.quote('00000000-0000-0000-0000-00000000a101', 3000, 'straight_line_fallback')),
  'straight_line_fallback',
  'a quote priced with the straight-line fallback is marked'
);

SELECT throws_ok(
  $$SELECT public.create_order_quote('00000000-0000-0000-0000-00000000a101', 'Osogbo', 7.7710, 4.5560, NULL,
      'Ede', 7.7400, 4.4400, NULL, 9000, 'routes')$$,
  'P0001', 'The pickup point is outside the Dispatch service area',
  'a pickup outside the service area is refused'
);

SELECT throws_ok(
  $$SELECT public.create_order_quote('00000000-0000-0000-0000-00000000a101', 'Ede', 7.7400, 4.4400, NULL,
      'Osogbo', 7.7710, 4.5560, NULL, 9000, 'routes')$$,
  'P0001', 'The drop-off point is outside the Dispatch service area',
  'a drop-off outside the service area is refused'
);

SELECT throws_ok(
  $$SELECT pg_temp.quote('00000000-0000-0000-0000-00000000a101', 20001)$$,
  'P0001', 'This delivery is longer than the maximum distance',
  'a distance over the maximum is refused'
);

SELECT throws_ok(
  $$SELECT pg_temp.quote('00000000-0000-0000-0000-00000000a101', 0)$$,
  'P0001', 'Pickup and drop-off must be different places',
  'a zero distance is refused'
);

SELECT throws_ok(
  $$SELECT pg_temp.quote('00000000-0000-0000-0000-00000000a105')$$,
  'P0001', 'An active customer account is required to order',
  'a user without an active customer role cannot get a quote'
);

UPDATE public.app_settings SET commission_bps = 1000;
SELECT is(
  (SELECT commission_kobo FROM pg_temp.quote('00000000-0000-0000-0000-00000000a101')),
  20500::bigint,
  'the commission rate at quote time is used (10% of ₦2,050)'
);
UPDATE public.app_settings SET commission_bps = 1500;

UPDATE public.service_areas SET active = false;
SELECT throws_ok(
  $$SELECT pg_temp.quote('00000000-0000-0000-0000-00000000a101')$$,
  'P0001', 'The pickup point is outside the Dispatch service area',
  'with no active service area, nothing can be quoted'
);
UPDATE public.service_areas SET active = true;

SELECT throws_ok(
  $$UPDATE public.order_quotes SET price_kobo = 1000 WHERE id = (SELECT id FROM q1)$$,
  'P0001', 'A quote cannot be changed',
  'a quote cannot be changed, even by the server'
);

-- ---------------------------------------------------------------------------
-- Rate limits and the daily Google cap
-- ---------------------------------------------------------------------------
INSERT INTO public.api_usage (user_id, kind, google_calls)
SELECT '00000000-0000-0000-0000-00000000a102', 'quote', 3 FROM generate_series(1, 19);

SELECT lives_ok(
  $$SELECT public.use_api_quota('00000000-0000-0000-0000-00000000a102', 'quote', 3)$$,
  'the 20th quote in an hour is allowed'
);

SELECT throws_ok(
  $$SELECT public.use_api_quota('00000000-0000-0000-0000-00000000a102', 'quote', 3)$$,
  'P0001', 'Too many requests. Try again later.',
  'the 21st quote in an hour is refused'
);

SELECT lives_ok(
  $$SELECT public.use_api_quota('00000000-0000-0000-0000-00000000a102', 'place_search', 1)$$,
  'place searches have their own limit'
);

INSERT INTO public.api_usage (user_id, kind, google_calls, created_at)
SELECT '00000000-0000-0000-0000-00000000a101', 'quote', 0, now() - interval '61 minutes'
  FROM generate_series(1, 30);

SELECT lives_ok(
  $$SELECT public.use_api_quota('00000000-0000-0000-0000-00000000a101', 'quote', 3)$$,
  'quotes older than an hour do not count'
);

UPDATE public.app_settings SET google_calls_per_day =
  coalesce((SELECT sum(google_calls) FROM public.api_usage
             WHERE created_at >= date_trunc('day', now() AT TIME ZONE 'Africa/Lagos') AT TIME ZONE 'Africa/Lagos'), 0)
  + 3;

SELECT lives_ok(
  $$SELECT public.use_api_quota('00000000-0000-0000-0000-00000000a101', 'quote', 3)$$,
  'a request that reaches the daily cap exactly is allowed'
);

SELECT throws_ok(
  $$SELECT public.use_api_quota('00000000-0000-0000-0000-00000000a101', 'place_search', 1)$$,
  'P0001', 'Dispatch is busy right now. Try again later.',
  'once the daily cap on Google calls is reached, every user is refused'
);

UPDATE public.app_settings SET google_calls_per_day = 2000;

-- ---------------------------------------------------------------------------
-- Who may insert orders directly
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000a101","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT throws_ok(
  $$INSERT INTO public.orders (customer_id, pickup_address, pickup_lat, pickup_lng,
      dropoff_address, dropoff_lat, dropoff_lng, price_kobo, commission_kobo)
    VALUES (auth.uid(), 'A', 7.73, 4.43, 'B', 7.75, 4.45, 100, 0)$$,
  '42501', NULL,
  'a signed-in client cannot insert an order directly'
);

SELECT throws_ok(
  $$INSERT INTO public.order_quotes (customer_id, pickup_address, pickup_lat, pickup_lng,
      dropoff_address, dropoff_lat, dropoff_lng, distance_m, distance_source, base_fee_kobo,
      per_km_rate_kobo, commission_bps, price_kobo, commission_kobo, expires_at)
    VALUES (auth.uid(), 'A', 7.73, 4.43, 'B', 7.75, 4.45, 100, 'routes', 0, 0, 0, 100, 0, now() + interval '1 hour')$$,
  '42501', NULL,
  'a client cannot make its own quote'
);

SET LOCAL ROLE anon;
SELECT throws_ok(
  $$INSERT INTO public.orders (customer_id, pickup_address, pickup_lat, pickup_lng,
      dropoff_address, dropoff_lat, dropoff_lng, price_kobo, commission_kobo)
    VALUES ('00000000-0000-0000-0000-00000000a101', 'A', 7.73, 4.43, 'B', 7.75, 4.45, 100, 0)$$,
  '42501', NULL,
  'an anonymous client cannot insert an order'
);

-- Even if insert privileges were granted by mistake, the trigger refuses API clients.
RESET ROLE;
GRANT INSERT ON public.orders TO authenticated;
CREATE POLICY tmp_orders_insert ON public.orders FOR INSERT TO authenticated WITH CHECK (true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$INSERT INTO public.orders (customer_id, pickup_address, pickup_lat, pickup_lng,
      dropoff_address, dropoff_lat, dropoff_lng, price_kobo, commission_kobo)
    VALUES (auth.uid(), 'A', 7.73, 4.43, 'B', 7.75, 4.45, 100, 0)$$,
  'P0001', 'Orders are created from a quote',
  'the order trigger refuses inserts from API clients'
);
RESET ROLE;
DROP POLICY tmp_orders_insert ON public.orders;
REVOKE INSERT ON public.orders FROM authenticated;

SET LOCAL ROLE service_role;
SELECT lives_ok(
  $$INSERT INTO public.orders (customer_id, pickup_address, pickup_lat, pickup_lng,
      dropoff_address, dropoff_lat, dropoff_lng, price_kobo, commission_kobo)
    VALUES ('00000000-0000-0000-0000-00000000a102', 'A', 7.73, 4.43, 'B', 7.75, 4.45, 0, 0)$$,
  'service_role can still insert an order directly'
);
RESET ROLE;

SELECT set_config('request.jwt.claims', '{}', true);
SELECT lives_ok(
  $$INSERT INTO public.orders (customer_id, pickup_address, pickup_lat, pickup_lng,
      dropoff_address, dropoff_lat, dropoff_lng, price_kobo, commission_kobo, status)
    VALUES ('00000000-0000-0000-0000-00000000a102', 'A', 7.73, 4.43, 'B', 7.75, 4.45, 0, 0, 'cancelled_by_customer')$$,
  'the database owner (SQL Editor) can still insert an order directly'
);

-- ---------------------------------------------------------------------------
-- c1: create from a quote
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000a101","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE o1 (id uuid);
GRANT ALL ON o1 TO authenticated;
INSERT INTO o1 SELECT public.create_order_from_quote((SELECT id FROM q1), '  Box of   documents ',
                                                     ' Ada  Okafor ', '+2348031234567');

SELECT is(
  (SELECT row(o.price_kobo, o.commission_kobo, o.distance_m, o.distance_source, o.base_fee_kobo,
              o.per_km_rate_kobo, o.commission_bps, o.pickup_address, o.pickup_lat, o.pickup_lng,
              o.pickup_place_id, o.dropoff_address, o.dropoff_lat, o.dropoff_lng, o.dropoff_place_id)::text
     FROM public.orders o WHERE o.id = (SELECT id FROM o1)),
  (SELECT row(q.price_kobo, q.commission_kobo, q.distance_m, q.distance_source, q.base_fee_kobo,
              q.per_km_rate_kobo, q.commission_bps, q.pickup_address, q.pickup_lat, q.pickup_lng,
              q.pickup_place_id, q.dropoff_address, q.dropoff_lat, q.dropoff_lng, q.dropoff_place_id)::text
     FROM q1 q),
  'the order copies its price, commission, distance and addresses from the quote'
);

SELECT is(
  (SELECT o.status::text || ' | ' || o.package_description || ' | ' || o.quote_id::text || ' | ' || o.priced_with_fallback::text
     FROM public.orders o WHERE o.id = (SELECT id FROM o1)),
  'rider_requested | Box of documents | ' || (SELECT id FROM q1)::text || ' | false',
  'a new order starts searching for a rider at once, with the package and its quote'
);

SELECT is(
  (SELECT receiver_name || ' ' || receiver_phone FROM public.order_contacts WHERE order_id = (SELECT id FROM o1)),
  'Ada Okafor 2348031234567',
  'the receiver is stored separately, phone in stored format'
);

SELECT is(
  (SELECT order_id FROM public.order_quotes WHERE id = (SELECT id FROM q1)),
  (SELECT id FROM o1),
  'the quote is marked as used'
);

SELECT throws_ok(
  $$SELECT public.create_order_from_quote((SELECT id FROM q1), 'Box', 'Ada Okafor', '2348031234567')$$,
  'P0001', 'This price has already been used for an order',
  'a quote can be used only once'
);

SELECT is(
  (SELECT count(*) FROM public.order_events WHERE order_id = (SELECT id FROM o1) AND status = 'created'
      AND actor_id = auth.uid()),
  1::bigint,
  'creating the order logs a created event by the customer'
);

RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);
CREATE TEMP TABLE spare AS SELECT * FROM pg_temp.quote('00000000-0000-0000-0000-00000000a101');
-- An expired quote (inserted directly: quotes cannot be changed after creation).
INSERT INTO public.order_quotes (customer_id, pickup_address, pickup_lat, pickup_lng, dropoff_address,
  dropoff_lat, dropoff_lng, distance_m, distance_source, base_fee_kobo, per_km_rate_kobo, commission_bps,
  price_kobo, commission_kobo, created_at, expires_at)
VALUES ('00000000-0000-0000-0000-00000000a101', 'A', 7.735, 4.436, 'B', 7.745, 4.445, 2350, 'routes',
  60000, 60000, 1500, 205000, 30750, now() - interval '20 minutes', now() - interval '5 minutes');
GRANT SELECT ON spare TO authenticated;

SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000a101","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT throws_ok(
  $$SELECT public.create_order_from_quote(
      (SELECT id FROM public.order_quotes WHERE expires_at < now()), 'Box', 'Ada Okafor', '2348031234567')$$,
  'P0001', 'This price has expired. Get a new price.',
  'an expired quote is refused'
);

SELECT throws_ok(
  $$SELECT public.create_order_from_quote((SELECT id FROM spare), 'Box', 'Ada Okafor', '08031234567')$$,
  'P0001', 'Enter the receiver''s Nigerian mobile number',
  'the receiver phone must be a Nigerian mobile number in international form'
);

SELECT throws_ok(
  $$SELECT public.create_order_from_quote((SELECT id FROM spare), ' ', 'Ada Okafor', '2348031234567')$$,
  'P0001', 'Describe the package (2 to 200 characters)',
  'a package description is required'
);

SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000a102","role":"authenticated"}', true);

SELECT throws_ok(
  $$SELECT public.create_order_from_quote((SELECT id FROM spare), 'Box', 'Ada Okafor', '2348031234567')$$,
  'P0001', 'Quote not found',
  'another customer''s quote cannot be used'
);

-- Active-order limit (2): c1 has one active order.
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000a101","role":"authenticated"}', true);

INSERT INTO o1 SELECT public.create_order_from_quote((SELECT id FROM spare), 'Phone charger', 'Bayo Ade', '2348031234568');

RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);
CREATE TEMP TABLE spare2 AS SELECT * FROM pg_temp.quote('00000000-0000-0000-0000-00000000a101');
GRANT SELECT ON spare2 TO authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000a101","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT throws_ok(
  $$SELECT public.create_order_from_quote((SELECT id FROM spare2), 'Box', 'Ada Okafor', '2348031234567')$$,
  'P0001', 'You have reached the limit of active orders. Wait for one to finish or cancel it.',
  'a third active order is refused (limit 2)'
);

-- ---------------------------------------------------------------------------
-- Cancelling before a rider accepts
-- ---------------------------------------------------------------------------
SELECT lives_ok(
  $$SELECT public.cancel_order((SELECT id FROM public.orders WHERE package_description = 'Box of documents'))$$,
  'a customer can cancel a waiting order'
);

SELECT is(
  (SELECT count(*) FROM public.orders WHERE id IN (SELECT id FROM o1) AND status = 'cancelled_by_customer'),
  1::bigint,
  'the order is cancelled by the customer'
);

SELECT lives_ok(
  $$SELECT public.create_order_from_quote((SELECT id FROM spare2), 'Box', 'Ada Okafor', '2348031234567')$$,
  'after cancelling, the customer is under the limit again'
);

SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000a102","role":"authenticated"}', true);

SELECT throws_ok(
  $$SELECT public.cancel_order((SELECT id FROM o1 LIMIT 1))$$,
  'P0001', 'Order not found',
  'a customer cannot cancel someone else''s order'
);

-- ---------------------------------------------------------------------------
-- Server moves c1's second order along (dispatch is the next feature)
-- ---------------------------------------------------------------------------
RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);
CREATE TEMP TABLE o2 AS SELECT id FROM public.orders WHERE package_description = 'Phone charger';
GRANT SELECT ON o2 TO authenticated, service_role;

UPDATE public.orders SET status = 'rider_requested' WHERE id = (SELECT id FROM o2);

SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000a103","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT is(
  (SELECT count(*) FROM public.orders),
  0::bigint,
  'a rider sees no order before one is assigned to them'
);

RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);
UPDATE public.orders SET rider_id = '00000000-0000-0000-0000-00000000a103' WHERE id = (SELECT id FROM o2);

SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000a103","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT is(
  (SELECT count(*) FROM public.orders WHERE id = (SELECT id FROM o2)),
  1::bigint,
  'the assigned rider sees the order'
);

SELECT is(
  (SELECT count(*) FROM public.order_contacts) + (SELECT count(*) FROM public.order_quotes),
  0::bigint,
  'a rider never reads the contacts or quotes tables'
);

SELECT throws_ok(
  $$SELECT * FROM public.get_order_contact_details((SELECT id FROM o2))$$,
  'P0001', 'Contact details are not available for this order',
  'contact details are not available to the rider before acceptance'
);

SELECT throws_ok(
  $$UPDATE public.orders SET pickup_address = 'Somewhere else' WHERE id = (SELECT id FROM o2)$$,
  '42501', NULL,
  'the assigned rider cannot change the order'
);

RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);
UPDATE public.orders SET status = 'accepted' WHERE id = (SELECT id FROM o2);

SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000a103","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT is(
  (SELECT customer_phone || ' ' || receiver_name || ' ' || receiver_phone
     FROM public.get_order_contact_details((SELECT id FROM o2))),
  '2348000000801 Bayo Ade 2348031234568',
  'after acceptance the assigned rider gets the customer and receiver phone numbers'
);

SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000a105","role":"authenticated"}', true);

SELECT throws_ok(
  $$SELECT * FROM public.get_order_contact_details((SELECT id FROM o2))$$,
  'P0001', 'Contact details are not available for this order',
  'another rider cannot get the contact details'
);


-- ---------------------------------------------------------------------------
-- Address and price lock, for everyone
-- ---------------------------------------------------------------------------
RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);

SELECT throws_ok(
  $$UPDATE public.orders SET pickup_address = 'Elsewhere' WHERE id = (SELECT id FROM o2)$$,
  'P0001', 'An order''s addresses, price and package are fixed once it is created',
  'the pickup address cannot be changed, even by the database owner'
);

SELECT throws_ok(
  $$UPDATE public.orders SET price_kobo = 100 WHERE id = (SELECT id FROM o2)$$,
  'P0001', 'An order''s addresses, price and package are fixed once it is created',
  'the price cannot be changed, even by the database owner'
);

SET LOCAL ROLE service_role;
SELECT throws_ok(
  $$UPDATE public.orders SET dropoff_lat = 7.9 WHERE id = (SELECT id FROM o2)$$,
  'P0001', 'An order''s addresses, price and package are fixed once it is created',
  'the drop-off coordinates cannot be changed by service_role'
);
RESET ROLE;

SELECT throws_ok(
  $$UPDATE public.order_contacts SET receiver_phone = '2348099999999' WHERE order_id = (SELECT id FROM o2)$$,
  'P0001', 'Order contact details cannot be changed or deleted',
  'the receiver contact cannot be changed'
);

SELECT lives_ok(
  $$UPDATE public.orders SET status = 'picked_up' WHERE id = (SELECT id FROM o2)$$,
  'the server can still move the order along'
);

SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000a101","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$SELECT public.cancel_order((SELECT id FROM o2))$$,
  'P0001', 'After pickup, only Dispatch support can cancel',
  'a customer cannot cancel after pickup'
);
RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);

-- ---------------------------------------------------------------------------
-- Delivering charges the commission fixed at quote time
-- ---------------------------------------------------------------------------
UPDATE public.orders SET status = 'delivered' WHERE id = (SELECT id FROM o2);

SELECT is(
  (SELECT amount_kobo FROM public.commission_entries WHERE order_id = (SELECT id FROM o2)),
  (SELECT commission_kobo FROM public.order_quotes WHERE order_id = (SELECT id FROM o2)),
  'delivering the order charges exactly the commission from its quote'
);

SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000a103","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT throws_ok(
  $$SELECT * FROM public.get_order_contact_details((SELECT id FROM o2))$$,
  'P0001', 'Contact details are not available for this order',
  'contact details stop being available after delivery'
);

-- ---------------------------------------------------------------------------
-- Who sees what
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000a101","role":"authenticated"}', true);

SELECT is(
  (SELECT count(*) FROM public.orders WHERE customer_id <> auth.uid())
  + (SELECT count(*) FROM public.order_quotes WHERE customer_id <> auth.uid()),
  0::bigint,
  'a customer sees only their own orders and quotes'
);

SELECT is(
  (SELECT count(*) FROM public.order_contacts),
  3::bigint,
  'a customer sees the contacts of their own orders'
);

SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000a102","role":"authenticated"}', true);

SELECT is(
  (SELECT count(*) FROM public.orders WHERE customer_id = '00000000-0000-0000-0000-00000000a101')
  + (SELECT count(*) FROM public.order_quotes WHERE customer_id = '00000000-0000-0000-0000-00000000a101')
  + (SELECT count(*) FROM public.order_contacts),
  0::bigint,
  'another customer sees none of c1''s orders, quotes or contacts'
);

SELECT is(
  (SELECT count(*) FROM public.api_usage),
  0::bigint,
  'a customer cannot read the usage counter'
);

SELECT ok(
  (SELECT count(*) FROM public.service_areas WHERE active) = 1,
  'signed-in users can read the service areas'
);

SELECT throws_ok(
  $$INSERT INTO public.service_areas (name, center_lat, center_lng, radius_m) VALUES ('Mine', 0, 0, 1000)$$,
  '42501', NULL,
  'a client cannot add a service area'
);

SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000a104","role":"authenticated"}', true);

SELECT ok(
  (SELECT count(DISTINCT customer_id) FROM public.orders) = 2
  AND (SELECT count(*) FROM public.order_contacts) = 3
  AND (SELECT count(*) FROM public.api_usage) > 0,
  'an admin sees every order, contact and usage row'
);

RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);

SELECT is(
  (SELECT array_agg(column_name::text) FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'orders' AND column_name ILIKE '%phone%'),
  NULL,
  'no phone number is stored on orders'
);

-- ---------------------------------------------------------------------------
-- Function privileges and search_path
-- ---------------------------------------------------------------------------
SELECT ok(
  NOT has_function_privilege('authenticated', 'public.use_api_quota(uuid, text, integer)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.use_api_quota(uuid, text, integer)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated',
        'public.create_order_quote(uuid, text, double precision, double precision, text, text, double precision, double precision, text, integer, public.order_distance_source)', 'EXECUTE')
  AND has_function_privilege('service_role',
        'public.create_order_quote(uuid, text, double precision, double precision, text, text, double precision, double precision, text, integer, public.order_distance_source)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.price_for_distance(integer, bigint, bigint)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.point_in_service_area(double precision, double precision)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.customer_role_is_active(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.protect_order_fields()', 'EXECUTE'),
  'quotes and usage are server-only; the helpers are not callable by API roles'
);

SELECT ok(
  has_function_privilege('authenticated', 'public.create_order_from_quote(uuid, text, text, text)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.cancel_order(uuid)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.get_order_contact_details(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.create_order_from_quote(uuid, text, text, text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.cancel_order(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.get_order_contact_details(uuid)', 'EXECUTE')
  AND NOT has_table_privilege('anon', 'public.order_quotes', 'SELECT')
  AND NOT has_table_privilege('anon', 'public.order_contacts', 'SELECT'),
  'signed-in users can create, cancel and (when allowed) get contacts; anonymous users cannot'
);

SELECT is(
  (SELECT array_agg(p.proname::text ORDER BY p.proname)
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('distance_between_m', 'point_in_service_area', 'price_for_distance', 'use_api_quota',
                        'order_quotes_protect', 'protect_order_fields', 'order_contacts_protect',
                        'customer_role_is_active', 'create_order_quote', 'create_order_from_quote',
                        'cancel_order', 'get_order_contact_details')
      AND NOT coalesce(p.proconfig @> ARRAY['search_path=""'], false)),
  NULL,
  'every new or replaced function sets an empty search_path'
);

SELECT * FROM finish();
ROLLBACK;
