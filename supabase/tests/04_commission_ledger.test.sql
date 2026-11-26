-- Commission ledger: rounding, one charge per order, which trips count, the 4-trip
-- cycle, the due block, payments (partial, full, overpayment, duplicates), reversals,
-- append-only records, visibility, the company account and its change log, and
-- function privileges.
-- Run locally with: supabase db start && supabase test db
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(72);

-- Users
--   r1, r2 = approved riders with verified bank accounts, online
--   c1 = customer only     a1 = admin
-- Switching user: set the JWT claims and SET LOCAL ROLE authenticated.
-- Back to server context: RESET ROLE and clear the claims ('{}' => auth.role() is NULL).

-- ---------------------------------------------------------------------------
-- Fixtures (server context)
-- ---------------------------------------------------------------------------
INSERT INTO auth.users (id, phone) VALUES
  ('00000000-0000-0000-0000-00000000f001', '2348000000701'),
  ('00000000-0000-0000-0000-00000000f002', '2348000000702'),
  ('00000000-0000-0000-0000-00000000f003', '2348000000703'),
  ('00000000-0000-0000-0000-00000000f004', '2348000000704');

INSERT INTO public.user_roles (user_id, role) VALUES
  ('00000000-0000-0000-0000-00000000f001', 'rider'),
  ('00000000-0000-0000-0000-00000000f002', 'rider'),
  ('00000000-0000-0000-0000-00000000f003', 'customer'),
  ('00000000-0000-0000-0000-00000000f004', 'admin');

INSERT INTO public.rider_details
  (user_id, full_name, bike_make_model, bike_colour, plate_number, id_photo_path, selfie_path, kyc_status)
VALUES
  ('00000000-0000-0000-0000-00000000f001', 'Rider One', 'Bajaj', 'Red', 'EDE-F01', 'f1/id.jpg', 'f1/s.jpg', 'approved'),
  ('00000000-0000-0000-0000-00000000f002', 'Rider Two', 'Bajaj', 'Red', 'EDE-F02', 'f2/id.jpg', 'f2/s.jpg', 'approved');

INSERT INTO public.rider_bank_accounts
  (rider_id, bank_name, account_number, account_name, name_match,
   status, verified_name, verified_name_match, recorded_by, reviewed_at)
SELECT user_id, 'Test Bank', '00000007' || right(user_id::text, 2), full_name, 'match',
       'verified', full_name, 'match', 'test fixture', now()
  FROM public.rider_details WHERE user_id IN ('00000000-0000-0000-0000-00000000f001',
                                              '00000000-0000-0000-0000-00000000f002');

UPDATE public.rider_details SET is_online = true
 WHERE user_id IN ('00000000-0000-0000-0000-00000000f001', '00000000-0000-0000-0000-00000000f002');

-- An order for a rider, priced at ₦1,800 (commission ₦270 at 15%). Created with the
-- rider already set (a rider can hold only one active job, so not "picked_up" here);
-- the tests below end each one directly.
CREATE FUNCTION pg_temp.new_order(p_rider uuid)
RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO public.orders
    (customer_id, rider_id, pickup_address, pickup_lat, pickup_lng,
     dropoff_address, dropoff_lat, dropoff_lng, price_kobo, commission_kobo, status)
  VALUES ('00000000-0000-0000-0000-00000000f003', p_rider, 'Pickup, Ede', 7.73, 4.43,
          'Dropoff, Ede', 7.74, 4.44, 180000, public.commission_for_price(180000, 1500), 'created')
  RETURNING id;
$$;

CREATE TEMP TABLE o (name text PRIMARY KEY, id uuid);
INSERT INTO o
SELECT n, pg_temp.new_order('00000000-0000-0000-0000-00000000f001')
  FROM unnest(ARRAY['o1', 'o2', 'o3', 'o4', 'o5', 'o6', 'o7']) AS n;
INSERT INTO o
SELECT n, pg_temp.new_order('00000000-0000-0000-0000-00000000f002')
  FROM unnest(ARRAY['p1', 'p2', 'p3', 'p4']) AS n;
GRANT SELECT ON o TO authenticated;

CREATE FUNCTION pg_temp.oid(p_name text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM o WHERE name = p_name $$;

-- ---------------------------------------------------------------------------
-- Settings and rounding
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT commission_bps::text || ' ' || commission_trips_per_cycle::text FROM public.app_settings),
  '1500 4',
  'settings: 15% (1500 basis points) and 4 trips per cycle'
);

SELECT hasnt_column('public', 'app_settings', 'commission_percent', 'commission_percent is replaced by commission_bps');

SELECT throws_ok(
  $$UPDATE public.app_settings SET commission_bps = 10001$$,
  '23514', NULL,
  'the commission rate cannot be above 100%'
);

SELECT is(
  ARRAY[public.commission_for_price(185000, 1500), public.commission_for_price(9, 1500),
        public.commission_for_price(10, 1500), public.commission_for_price(11, 1500),
        public.commission_for_price(0, 1500)],
  ARRAY[27750, 1, 2, 2, 0]::bigint[],
  'commission is rounded half-up to the kobo (1.35 -> 1, 1.5 -> 2, 1.65 -> 2)'
);

SELECT throws_ok(
  $$SELECT public.commission_for_price(100, 10001)$$,
  'P0001', 'The commission rate must be between 0 and 10000 basis points',
  'commission_for_price rejects an out-of-range rate'
);

-- ---------------------------------------------------------------------------
-- Which trips count (the accrual guard must be reviewed if order_status changes)
-- ---------------------------------------------------------------------------
SELECT enum_has_labels(
  'public', 'order_status',
  ARRAY['created', 'rider_requested', 'accepted', 'picked_up', 'delivered', 'completed',
        'cancelled_by_customer', 'cancelled_by_rider', 'no_rider_found', 'payment_failed'],
  'order_status is exactly the set order_counts_as_trip() was written for: if this fails, review the commission trigger'
);

SELECT is(
  (SELECT array_agg(s::text || '/' || p::text ORDER BY s, p)
     FROM unnest(enum_range(NULL::public.order_status)) AS s,
          unnest(enum_range(NULL::public.payment_status)) AS p
    WHERE public.order_counts_as_trip(s, p)),
  ARRAY['delivered/unpaid', 'delivered/awaiting_payment', 'delivered/paid', 'delivered/failed',
        'completed/unpaid', 'completed/awaiting_payment', 'completed/paid', 'completed/failed',
        'cancelled_by_customer/paid', 'cancelled_by_rider/paid', 'no_rider_found/paid', 'payment_failed/paid'],
  'a trip counts when delivered, or when it ends any other way with a confirmed payment'
);

-- ---------------------------------------------------------------------------
-- r1: accrual and the cycle
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT count(*) FROM public.commission_entries),
  0::bigint,
  'nothing is charged before a trip ends'
);

UPDATE public.orders SET status = 'delivered' WHERE id = pg_temp.oid('o1');

SELECT is(
  (SELECT type::text || ' ' || amount_kobo::text || ' ' || balance_after_kobo::text
     FROM public.commission_entries WHERE order_id = pg_temp.oid('o1')),
  'commission 27000 27000',
  'a delivered trip is charged its commission (₦270)'
);

SELECT is(
  (SELECT cycle_no::text || ' ' || trip_count::text || ' ' || status::text || ' ' || trips_required::text
     FROM public.commission_cycles WHERE rider_id = '00000000-0000-0000-0000-00000000f001'),
  '1 1 open 4',
  'the first trip opens cycle 1 with 1 of 4 trips'
);

SELECT is(
  (SELECT reference_code FROM public.commission_cycles WHERE rider_id = '00000000-0000-0000-0000-00000000f001'),
  'DSP-00000000-C001',
  'the reference code is DSP-<8 characters of the rider id>-C<cycle>'
);

UPDATE public.orders SET status = 'completed' WHERE id = pg_temp.oid('o1');

SELECT is(
  (SELECT count(*) FROM public.commission_entries WHERE order_id = pg_temp.oid('o1')),
  1::bigint,
  'delivered then completed is charged once'
);

SELECT is(
  public.accrue_trip_commission(pg_temp.oid('o1')),
  false,
  'calling the delivered-trip step again does not charge twice'
);

SELECT throws_ok(
  $$SELECT public.accrue_trip_commission(pg_temp.oid('o2'))$$,
  'P0001', 'This order does not count as a trip',
  'an order still on the way cannot be charged'
);

UPDATE public.orders SET status = 'cancelled_by_customer' WHERE id = pg_temp.oid('o2');

SELECT is(
  (SELECT count(*) FROM public.commission_entries WHERE order_id = pg_temp.oid('o2')),
  0::bigint,
  'a cancelled trip with no payment does not count'
);

UPDATE public.orders SET status = 'cancelled_by_rider', payment_status = 'paid' WHERE id = pg_temp.oid('o3');

SELECT is(
  (SELECT count(*) FROM public.commission_entries WHERE order_id = pg_temp.oid('o3')),
  1::bigint,
  'a cancelled trip with a confirmed payment counts'
);

UPDATE public.orders SET status = 'payment_failed' WHERE id = pg_temp.oid('o4');
UPDATE public.orders SET payment_status = 'paid' WHERE id = pg_temp.oid('o4');

SELECT is(
  (SELECT trip_count::text || ' ' || status::text FROM public.commission_cycles
    WHERE rider_id = '00000000-0000-0000-0000-00000000f001'),
  '3 open',
  'a payment confirmed after the trip ended counts then; 3 of 4 trips, still open'
);

SELECT is(
  (SELECT is_online FROM public.rider_details WHERE user_id = '00000000-0000-0000-0000-00000000f001'),
  true,
  'the rider stays online before the 4th trip'
);

UPDATE public.orders SET status = 'delivered' WHERE id = pg_temp.oid('o5');

SELECT is(
  (SELECT trip_count::text || ' ' || status::text || ' ' || (due_at IS NOT NULL)::text
     FROM public.commission_cycles WHERE rider_id = '00000000-0000-0000-0000-00000000f001'),
  '4 due true',
  'the 4th counted trip makes the cycle due'
);

SELECT is(
  (SELECT is_online FROM public.rider_details WHERE user_id = '00000000-0000-0000-0000-00000000f001'),
  false,
  'a due cycle sets the rider offline in the same step'
);

SELECT is(
  public.rider_commission_balance('00000000-0000-0000-0000-00000000f001'),
  108000::bigint,
  '₦1,080 owed for 4 trips'
);

-- A 5th trip that was already under way when the cycle became due.
UPDATE public.orders SET status = 'delivered' WHERE id = pg_temp.oid('o6');

SELECT is(
  (SELECT array_agg(cycle_no::text || ':' || trip_count::text || ':' || status::text ORDER BY cycle_no)
     FROM public.commission_cycles WHERE rider_id = '00000000-0000-0000-0000-00000000f001'),
  ARRAY['1:4:due', '2:1:open'],
  'a trip ending while a cycle is due starts the next cycle'
);

SELECT is(
  (SELECT balance_after_kobo FROM public.commission_entries
    WHERE rider_id = '00000000-0000-0000-0000-00000000f001' ORDER BY entry_no DESC LIMIT 1),
  (SELECT sum(amount_kobo)::bigint FROM public.commission_entries
    WHERE rider_id = '00000000-0000-0000-0000-00000000f001'),
  'the running balance equals the sum of the entries'
);

-- ---------------------------------------------------------------------------
-- r1 (signed in): blocked while due
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000f001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT throws_ok(
  $$UPDATE public.rider_details SET is_online = true WHERE user_id = auth.uid()$$,
  'P0001', 'Commission is due: pay it to go online',
  'a rider with a due cycle cannot go online'
);

SELECT throws_ok(
  $$SELECT public.record_commission_payment('DSP-00000000-C001', 108000, 'SELF', now(), 'me', 'paid')$$,
  'P0001', 'Only an admin can record commission payments',
  'a rider cannot record their own payment'
);

SELECT throws_ok(
  $$INSERT INTO public.commission_entries (rider_id, entry_no, cycle_id, type, amount_kobo, balance_after_kobo, bank_reference, paid_at, recorded_by, note)
    SELECT auth.uid(), 99, id, 'payment', -108000, 0, 'X', now(), 'me', 'x' FROM public.commission_cycles LIMIT 1$$,
  '42501', NULL,
  'a rider cannot write to the ledger'
);

SELECT throws_ok(
  $$UPDATE public.commission_cycles SET status = 'paid' WHERE rider_id = auth.uid()$$,
  '42501', NULL,
  'a rider cannot change a cycle'
);

SELECT is(
  (SELECT count(*) FROM public.commission_entries WHERE rider_id <> auth.uid())
  + (SELECT count(*) FROM public.commission_cycles WHERE rider_id <> auth.uid()),
  0::bigint,
  'a rider sees only their own cycles and entries'
);

SELECT ok(
  (SELECT count(*) FROM public.commission_entries) = 5,
  'a rider sees all of their own entries'
);

-- ---------------------------------------------------------------------------
-- Payments (SQL Editor: server context)
-- ---------------------------------------------------------------------------
RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);

SELECT throws_ok(
  $$SELECT public.record_commission_payment('DSP-00000000-C001', 50000, 'TXN-A', now(), 'Admin Ade', '  ')$$,
  'P0001', 'Enter a note',
  'a payment needs a note'
);

SELECT throws_ok(
  $$SELECT public.record_commission_payment('DSP-00000000-C001', 50000, 'TXN-A', now(), '', 'note')$$,
  'P0001', 'Enter who is recording this',
  'a payment needs "recorded by"'
);

SELECT throws_ok(
  $$SELECT public.record_commission_payment('DSP-NOPE-C001', 50000, 'TXN-A', now(), 'Admin Ade', 'note')$$,
  'P0001', 'Unknown commission reference code',
  'an unknown reference code is refused'
);

SELECT is(
  public.record_commission_payment(' dsp-00000000-c001 ', 50000, 'TXN-A', now(), 'Admin Ade', 'Partial transfer'),
  85000::bigint,
  'a partial payment is recorded (₦1,350 owed - ₦500 = ₦850; reference matched case-insensitively)'
);

SELECT is(
  (SELECT status::text FROM public.commission_cycles
    WHERE rider_id = '00000000-0000-0000-0000-00000000f001' AND cycle_no = 1),
  'due',
  'after a partial payment the cycle is still due'
);

SELECT throws_ok(
  $$SELECT public.record_commission_payment('DSP-00000000-C001', 50000, ' txn-a ', now(), 'Admin Ade', 'again')$$,
  'P0001', 'This bank transfer is already recorded',
  'the same bank transfer cannot be recorded twice'
);

SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000f001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT throws_ok(
  $$UPDATE public.rider_details SET is_online = true WHERE user_id = auth.uid()$$,
  'P0001', 'Commission is due: pay it to go online',
  'a partial payment keeps the rider blocked'
);

RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);

SELECT is(
  public.record_commission_payment('DSP-00000000-C001', 95000, 'TXN-B', now(), 'Admin Ade', 'Rest plus ₦100 extra'),
  -10000::bigint,
  'paying more than is owed leaves a credit (₦100)'
);

SELECT is(
  (SELECT status::text || ' ' || (paid_at IS NOT NULL)::text FROM public.commission_cycles
    WHERE rider_id = '00000000-0000-0000-0000-00000000f001' AND cycle_no = 1),
  'paid true',
  'the full amount marks the cycle paid'
);

SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000f001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT lives_ok(
  $$UPDATE public.rider_details SET is_online = true WHERE user_id = auth.uid()$$,
  'after full payment the rider can go online'
);

RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);

UPDATE public.orders SET status = 'delivered' WHERE id = pg_temp.oid('o7');

SELECT is(
  public.rider_commission_balance('00000000-0000-0000-0000-00000000f001'),
  17000::bigint,
  'the credit is used by the next trip (₦270 - ₦100 = ₦170 owed)'
);

-- ---------------------------------------------------------------------------
-- Reversals
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$SELECT public.reverse_commission_entry(
      (SELECT id FROM public.commission_entries WHERE bank_reference = 'TXN-B'), '', 'Admin Ade')$$,
  'P0001', 'A reversal needs a reason',
  'a reversal needs a reason'
);

SELECT is(
  public.reverse_commission_entry(
    (SELECT id FROM public.commission_entries WHERE bank_reference = 'TXN-B'),
    'Recorded the wrong amount', 'Admin Ade'),
  112000::bigint,
  'reversing a payment adds the opposite entry (₦170 + ₦950 = ₦1,120 owed)'
);

SELECT is(
  (SELECT type::text || ' ' || amount_kobo::text || ' ' || (reverses_entry_id IS NOT NULL)::text
     FROM public.commission_entries
    WHERE rider_id = '00000000-0000-0000-0000-00000000f001' ORDER BY entry_no DESC LIMIT 1),
  'reversal 95000 true',
  'the reversal is a new entry pointing at the one it reverses'
);

SELECT is(
  (SELECT c.status::text || ' ' || rd.is_online::text
     FROM public.commission_cycles c JOIN public.rider_details rd ON rd.user_id = c.rider_id
    WHERE c.rider_id = '00000000-0000-0000-0000-00000000f001' AND c.cycle_no = 1),
  'due false',
  'reversing the payment that settled a cycle makes it due again and takes the rider offline'
);

SELECT throws_ok(
  $$SELECT public.reverse_commission_entry(
      (SELECT id FROM public.commission_entries WHERE bank_reference = 'TXN-B'), 'again', 'Admin Ade')$$,
  'P0001', 'This entry is already reversed',
  'an entry can be reversed only once'
);

SELECT throws_ok(
  $$SELECT public.reverse_commission_entry(
      (SELECT id FROM public.commission_entries WHERE type = 'reversal' LIMIT 1), 'undo', 'Admin Ade')$$,
  'P0001', 'A reversal cannot be reversed',
  'a reversal cannot be reversed'
);

SELECT is(
  public.record_commission_payment('DSP-00000000-C001', 112000, 'TXN-B', now(), 'Admin Ade', 'Re-recorded with the correct amount'),
  0::bigint,
  'a reversed transfer can be recorded again with the right amount'
);

SELECT is(
  (SELECT status::text FROM public.commission_cycles
    WHERE rider_id = '00000000-0000-0000-0000-00000000f001' AND cycle_no = 1),
  'paid',
  'the cycle is paid again'
);

SELECT is(
  public.reverse_commission_entry(
    (SELECT id FROM public.commission_entries WHERE order_id = pg_temp.oid('o1')),
    'Trip was a test run', 'Admin Ade'),
  -27000::bigint,
  'reversing a commission credits the rider'
);

SELECT is(
  (SELECT trip_count FROM public.commission_cycles
    WHERE rider_id = '00000000-0000-0000-0000-00000000f001' AND cycle_no = 1),
  4,
  'reversing a commission changes money only, not the trip count'
);

-- ---------------------------------------------------------------------------
-- Append-only, even for the server and the database owner
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$UPDATE public.commission_entries SET amount_kobo = 1 WHERE order_id = pg_temp.oid('o5')$$,
  'P0001', 'commission_entries is append-only: updates and deletes are not allowed',
  'ledger entries cannot be updated'
);

SELECT throws_ok(
  $$DELETE FROM public.commission_entries WHERE order_id = pg_temp.oid('o5')$$,
  'P0001', 'commission_entries is append-only: updates and deletes are not allowed',
  'ledger entries cannot be deleted'
);

SELECT throws_ok(
  $$TRUNCATE public.commission_entries CASCADE$$,
  'P0001', NULL,
  'the ledger cannot be truncated'
);

SELECT throws_ok(
  $$DELETE FROM public.commission_cycles WHERE rider_id = '00000000-0000-0000-0000-00000000f001'$$,
  'P0001', 'Commission cycles cannot be deleted',
  'cycles cannot be deleted'
);

SELECT throws_ok(
  $$UPDATE public.commission_cycles SET reference_code = 'DSP-X' WHERE cycle_no = 1
     AND rider_id = '00000000-0000-0000-0000-00000000f001'$$,
  'P0001', 'A commission cycle''s identity cannot be changed',
  'a cycle''s reference code cannot be changed'
);

-- ---------------------------------------------------------------------------
-- r2: reference code collision, prepayment covering a whole cycle
-- ---------------------------------------------------------------------------
UPDATE public.orders SET status = 'delivered' WHERE id = pg_temp.oid('p1');

SELECT is(
  (SELECT reference_code FROM public.commission_cycles WHERE rider_id = '00000000-0000-0000-0000-00000000f002'),
  'DSP-000000000000-C001',
  'when the 8-character code is taken, a longer prefix is used and the cycle still opens'
);

SELECT is(
  public.record_commission_payment('DSP-000000000000-C001', 500000, 'TXN-R2', now(), 'Admin Ade', 'Paid in advance'),
  -473000::bigint,
  'a rider can pay in advance'
);

UPDATE public.orders SET status = 'delivered'
 WHERE id IN (pg_temp.oid('p2'), pg_temp.oid('p3'), pg_temp.oid('p4'));

SELECT is(
  (SELECT c.status::text || ' ' || rd.is_online::text
     FROM public.commission_cycles c JOIN public.rider_details rd ON rd.user_id = c.rider_id
    WHERE c.rider_id = '00000000-0000-0000-0000-00000000f002'),
  'paid true',
  'when credit already covers a cycle it is paid at once and the rider stays online'
);

-- ---------------------------------------------------------------------------
-- A settings change does not move an open cycle
-- ---------------------------------------------------------------------------
UPDATE public.app_settings SET commission_trips_per_cycle = 2;

SELECT is(
  (SELECT trips_required FROM public.commission_cycles
    WHERE rider_id = '00000000-0000-0000-0000-00000000f001' AND status = 'open'),
  4,
  'an open cycle keeps the trip count it started with'
);

-- ---------------------------------------------------------------------------
-- c1 (customer) and a1 (admin)
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000f003","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT is(
  (SELECT count(*) FROM public.commission_entries) + (SELECT count(*) FROM public.commission_cycles),
  0::bigint,
  'a customer can see no cycles or ledger entries'
);

SELECT throws_ok(
  $$SELECT * FROM public.get_company_payment_account()$$,
  'P0001', 'Only riders can see the company account',
  'a customer cannot see the company account'
);

SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000f004","role":"authenticated"}', true);

SELECT is(
  (SELECT count(DISTINCT rider_id) FROM public.commission_entries),
  2::bigint,
  'an admin sees every rider''s ledger'
);

-- ---------------------------------------------------------------------------
-- Company account: function-only access, every change logged
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000f001","role":"authenticated"}', true);

SELECT is(
  (SELECT count(*) FROM public.company_payment_account),
  0::bigint,
  'a rider cannot read the company account table directly'
);

SELECT throws_ok(
  $$SELECT public.set_company_payment_account('GTBank', '0123456789', 'X', 'me')$$,
  'P0001', 'Only an admin can change the company account',
  'a rider cannot change the company account'
);

RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);

SELECT throws_ok(
  $$UPDATE public.company_payment_account SET account_number = '9999999999'$$,
  'P0001', 'Use set_company_payment_account() to change the company account',
  'the company account cannot be changed directly, even in the SQL Editor'
);

SELECT lives_ok(
  $$SELECT public.set_company_payment_account('GTBank', '0123 456 789', 'TESNEEM LOGISTICS LTD', 'Admin Ade')$$,
  'an admin can set the company account'
);

SELECT public.set_company_payment_account('GTBank', '0123456789', 'TESNEEM LOGISTICS LIMITED', 'Admin Bisi');

SELECT is(
  (SELECT array_agg(changed_by || ':' || field || ':' || coalesce(old_value, '-') || '>' || new_value
                    ORDER BY changed_by, field)
     FROM public.company_payment_account_changes),
  ARRAY['Admin Ade:account_name:->TESNEEM LOGISTICS LTD',
        'Admin Ade:account_number:->0123456789',
        'Admin Ade:bank_name:->GTBank',
        'Admin Bisi:account_name:TESNEEM LOGISTICS LTD>TESNEEM LOGISTICS LIMITED'],
  'every change is logged with who, the old value and the new value (unchanged fields are not)'
);

SELECT throws_ok(
  $$UPDATE public.company_payment_account_changes SET new_value = 'x'$$,
  'P0001', 'company_payment_account_changes is append-only: updates and deletes are not allowed',
  'the change log cannot be edited'
);

SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000f001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT is(
  (SELECT bank_name || ' ' || account_number || ' ' || account_name FROM public.get_company_payment_account()),
  'GTBank 0123456789 TESNEEM LOGISTICS LIMITED',
  'a rider sees the company account through the function'
);

RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);

-- ---------------------------------------------------------------------------
-- Function privileges and search_path
-- ---------------------------------------------------------------------------
SELECT ok(
  NOT has_function_privilege('authenticated', 'public.accrue_trip_commission(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.accrue_trip_commission(uuid)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.accrue_trip_commission(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.commission_for_price(bigint, integer)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.rider_commission_balance(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.rider_has_commission_due(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.settle_commission_cycles(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.take_rider_offline_for_commission(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.commission_reference_code(uuid, integer)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.lock_rider_commission(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated',
        'public.append_commission_entry(uuid, uuid, public.commission_entry_type, bigint, uuid, text, timestamptz, uuid, text, text)', 'EXECUTE'),
  'the delivered-trip step is server-only and the ledger helpers are not callable by API roles'
);

SELECT ok(
  NOT has_function_privilege('anon', 'public.record_commission_payment(text, bigint, text, timestamptz, text, text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.reverse_commission_entry(uuid, text, text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.get_company_payment_account()', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.set_company_payment_account(text, text, text, text)', 'EXECUTE')
  AND NOT has_table_privilege('anon', 'public.commission_entries', 'SELECT')
  AND NOT has_table_privilege('anon', 'public.commission_cycles', 'SELECT')
  AND NOT has_table_privilege('anon', 'public.company_payment_account', 'SELECT'),
  'anonymous users cannot call the commission functions or read the tables'
);

SELECT is(
  (SELECT array_agg(p.proname::text ORDER BY p.proname)
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('commission_for_price', 'reject_ledger_mutation', 'company_payment_account_protect',
                        'set_company_payment_account', 'get_company_payment_account', 'commission_cycles_protect',
                        'rider_commission_balance', 'rider_has_commission_due', 'lock_rider_commission',
                        'append_commission_entry', 'commission_reference_code', 'take_rider_offline_for_commission',
                        'settle_commission_cycles', 'order_counts_as_trip', 'accrue_trip_commission',
                        'orders_accrue_commission', 'record_commission_payment', 'reverse_commission_entry',
                        'protect_rider_details')
      AND NOT coalesce(p.proconfig @> ARRAY['search_path=""'], false)),
  NULL,
  'every new or replaced function sets an empty search_path'
);

SELECT * FROM finish();
ROLLBACK;
