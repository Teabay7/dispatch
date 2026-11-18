-- Baseline schema guarantees that are true today and must stay true.
-- Run locally with: npx supabase db start && npx supabase test db
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(14);

-- ---------------------------------------------------------------------------
-- Row Level Security: every table in public must have it, including future ones
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT array_agg(tablename::text ORDER BY tablename)
     FROM pg_tables
    WHERE schemaname = 'public' AND NOT rowsecurity),
  NULL,
  'RLS is enabled on every table in public'
);

SELECT tables_are(
  'public',
  ARRAY[
    'profiles', 'user_roles', 'rider_details', 'rider_locations', 'orders',
    'order_events', 'payments', 'wallet_entries', 'withdrawals', 'ratings',
    'app_settings'
  ],
  'public schema has exactly the expected tables'
);

-- ---------------------------------------------------------------------------
-- Money is stored as integer kobo
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT array_agg(table_name || '.' || column_name ORDER BY table_name, column_name)
     FROM information_schema.columns
    WHERE table_schema = 'public'
      AND column_name LIKE '%\_kobo'
      AND data_type <> 'bigint'),
  NULL,
  'every *_kobo column is bigint'
);

-- ---------------------------------------------------------------------------
-- Fixtures (as postgres: triggers treat this as a trusted server context)
-- ---------------------------------------------------------------------------
INSERT INTO auth.users (id, phone)
VALUES ('00000000-0000-0000-0000-0000000000c1', '2348000000001'),
       ('00000000-0000-0000-0000-0000000000d1', '2348000000002');

SELECT is(
  (SELECT count(*) FROM public.profiles
    WHERE id IN ('00000000-0000-0000-0000-0000000000c1',
                 '00000000-0000-0000-0000-0000000000d1')),
  2::bigint,
  'signing up creates a profile row'
);

INSERT INTO public.user_roles (user_id, role)
VALUES ('00000000-0000-0000-0000-0000000000c1', 'customer'),
       ('00000000-0000-0000-0000-0000000000d1', 'rider');

INSERT INTO public.wallet_entries (id, rider_id, type, amount_kobo, balance_after_kobo)
VALUES ('00000000-0000-0000-0000-0000000000e1',
        '00000000-0000-0000-0000-0000000000d1', 'credit', 100000, 100000);

-- ---------------------------------------------------------------------------
-- Wallet ledger is append-only, even for the database owner
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$UPDATE public.wallet_entries SET amount_kobo = 999999
     WHERE id = '00000000-0000-0000-0000-0000000000e1'$$,
  'P0001', NULL,
  'wallet_entries rows cannot be updated'
);

SELECT throws_ok(
  $$DELETE FROM public.wallet_entries
     WHERE id = '00000000-0000-0000-0000-0000000000e1'$$,
  'P0001', NULL,
  'wallet_entries rows cannot be deleted'
);

-- ---------------------------------------------------------------------------
-- app_settings is a single row
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$INSERT INTO public.app_settings
      (id, base_fee_kobo, per_km_rate_kobo, commission_percent, min_withdrawal_kobo)
    VALUES (2, 0, 0, 0, 0)$$,
  '23514', NULL,
  'app_settings cannot have a second row'
);

-- ---------------------------------------------------------------------------
-- Trigger rules for a signed-in customer.
-- The triggers read the JWT claims, so setting them is enough to exercise the
-- rules independently of table privileges and RLS.
-- ---------------------------------------------------------------------------
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated"}',
  true
);

SELECT throws_ok(
  $$INSERT INTO public.orders (customer_id, pickup_address, pickup_lat, pickup_lng,
      dropoff_address, dropoff_lat, dropoff_lng, price_kobo, commission_kobo)
    VALUES (auth.uid(), 'A', 7.73, 4.43, 'B', 7.75, 4.45, 50000, 0)$$,
  'P0001', 'price_kobo and commission_kobo must be set server-side',
  'a client cannot set the order price'
);

SELECT lives_ok(
  $$INSERT INTO public.orders (id, customer_id, pickup_address, pickup_lat, pickup_lng,
      dropoff_address, dropoff_lat, dropoff_lng, price_kobo, commission_kobo)
    VALUES ('00000000-0000-0000-0000-0000000000f1', auth.uid(), 'A', 7.73, 4.43,
            'B', 7.75, 4.45, 0, 0)$$,
  'a customer can create an unpriced order'
);

SELECT throws_ok(
  $$UPDATE public.orders SET payment_status = 'paid'
     WHERE id = '00000000-0000-0000-0000-0000000000f1'$$,
  'P0001', 'Cannot change order money or payment fields',
  'a client cannot mark an order paid'
);

SELECT throws_ok(
  $$INSERT INTO public.user_roles (user_id, role) VALUES (auth.uid(), 'admin')$$,
  'P0001', 'Cannot assign this role or status',
  'a client cannot grant themselves admin'
);

SELECT is(
  (SELECT count(*) FROM public.order_events
    WHERE order_id = '00000000-0000-0000-0000-0000000000f1'
      AND status = 'created'),
  1::bigint,
  'creating an order logs a created event'
);

-- ---------------------------------------------------------------------------
-- As the real API role
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;

SELECT throws_ok(
  $$INSERT INTO public.wallet_entries (rider_id, type, amount_kobo, balance_after_kobo)
    VALUES (auth.uid(), 'credit', 100, 100)$$,
  '42501', NULL,
  'a client cannot write to the wallet ledger'
);

RESET ROLE;

-- The migration has no explicit GRANTs and relies on Supabase's default
-- privileges for the API roles. If a Supabase/CLI upgrade stops granting new
-- public tables automatically, this fails: add explicit GRANTs to a migration.
SELECT ok(
  has_table_privilege('authenticated', 'public.orders', 'SELECT')
  AND has_table_privilege('authenticated', 'public.orders', 'INSERT'),
  'authenticated can select and insert orders (RLS then decides which rows)'
);

SELECT * FROM finish();
ROLLBACK;
