-- Rider KYC: row and file isolation, review rules, and the "go online" rule.
-- Run locally with: supabase db start && supabase test db
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(38);

-- Users
--   r1 = new rider (submits in this test)        r2 = rider with a pending submission
--   s1 = customer + rider, rider gets suspended   c1 = customer only
--   a1 = admin
-- Switching user: set the JWT claims and SET LOCAL ROLE authenticated.
-- Back to server context: RESET ROLE and clear the claims ('{}' => auth.role() is NULL).

-- ---------------------------------------------------------------------------
-- Fixtures (server context)
-- ---------------------------------------------------------------------------
INSERT INTO auth.users (id, phone) VALUES
  ('00000000-0000-0000-0000-00000000a001', '2348000000301'),
  ('00000000-0000-0000-0000-00000000a002', '2348000000302'),
  ('00000000-0000-0000-0000-00000000a003', '2348000000303'),
  ('00000000-0000-0000-0000-00000000a004', '2348000000304'),
  ('00000000-0000-0000-0000-00000000a005', '2348000000305');

INSERT INTO public.user_roles (user_id, role) VALUES
  ('00000000-0000-0000-0000-00000000a001', 'rider'),
  ('00000000-0000-0000-0000-00000000a002', 'rider'),
  ('00000000-0000-0000-0000-00000000a003', 'customer'),
  ('00000000-0000-0000-0000-00000000a003', 'rider'),
  ('00000000-0000-0000-0000-00000000a004', 'customer'),
  ('00000000-0000-0000-0000-00000000a005', 'admin');

-- A price quote for each customer (made by the quote-order Edge Function in real use).
SELECT public.create_order_quote(u, 'Pickup, Ede', 7.733, 4.433, NULL, 'Drop-off, Ede', 7.742, 4.441, NULL,
                                 1500, 'routes')
  FROM unnest(ARRAY['00000000-0000-0000-0000-00000000a003'::uuid,
                    '00000000-0000-0000-0000-00000000a004'::uuid]) AS u;

INSERT INTO storage.objects (bucket_id, name) VALUES
  ('rider-kyc', '00000000-0000-0000-0000-00000000a002/id-1.jpg'),
  ('rider-kyc', '00000000-0000-0000-0000-00000000a002/selfie-1.jpg'),
  ('rider-kyc', '00000000-0000-0000-0000-00000000a003/id-1.jpg'),
  ('rider-kyc', '00000000-0000-0000-0000-00000000a003/selfie-1.jpg');

INSERT INTO public.rider_details
  (user_id, full_name, bike_make_model, bike_colour, plate_number, id_photo_path, selfie_path)
VALUES
  ('00000000-0000-0000-0000-00000000a002', 'Rider Two', 'Bajaj Boxer', 'Red', 'EDE-222-AA',
   '00000000-0000-0000-0000-00000000a002/id-1.jpg', '00000000-0000-0000-0000-00000000a002/selfie-1.jpg');

INSERT INTO public.rider_details
  (user_id, full_name, bike_make_model, bike_colour, plate_number, id_photo_path, selfie_path,
   kyc_status, is_online)
VALUES
  ('00000000-0000-0000-0000-00000000a003', 'Dual Role', 'Honda Ace', 'Black', 'EDE-333-BB',
   '00000000-0000-0000-0000-00000000a003/id-1.jpg', '00000000-0000-0000-0000-00000000a003/selfie-1.jpg',
   'approved', false);

-- Going online needs a verified bank account (20261124100000_rider_bank_account).
INSERT INTO public.rider_bank_accounts
  (rider_id, bank_name, account_number, account_name, name_match,
   status, verified_name, verified_name_match, recorded_by, reviewed_at)
VALUES ('00000000-0000-0000-0000-00000000a003', 'Test Bank', '0000000303', 'Dual Role', 'match',
        'verified', 'DUAL ROLE', 'match', 'test fixture', now());
UPDATE public.rider_details SET is_online = true
 WHERE user_id = '00000000-0000-0000-0000-00000000a003';

-- ---------------------------------------------------------------------------
-- r1: uploads and first submission
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT lives_ok(
  $$INSERT INTO storage.objects (bucket_id, name) VALUES
      ('rider-kyc', '00000000-0000-0000-0000-00000000a001/id-1.jpg'),
      ('rider-kyc', '00000000-0000-0000-0000-00000000a001/selfie-1.jpg')$$,
  'a rider can upload KYC photos to their own folder'
);

SELECT throws_ok(
  $$INSERT INTO storage.objects (bucket_id, name)
    VALUES ('rider-kyc', '00000000-0000-0000-0000-00000000a002/sneaky.jpg')$$,
  '42501', NULL,
  'a rider cannot upload into another rider''s folder'
);

SELECT is(
  (SELECT count(*) FROM storage.objects WHERE bucket_id = 'rider-kyc'),
  2::bigint,
  'a rider can only see their own KYC files'
);

SELECT throws_ok(
  $$INSERT INTO public.rider_details
      (user_id, full_name, bike_make_model, bike_colour, plate_number, id_photo_path, selfie_path)
    VALUES (auth.uid(), 'Rider One', 'Bajaj Boxer', 'Blue', 'ede-111-cc',
      '00000000-0000-0000-0000-00000000a002/id-1.jpg',
      '00000000-0000-0000-0000-00000000a001/selfie-1.jpg')$$,
  'P0001', 'KYC photos must be your own uploaded files',
  'a rider cannot submit another rider''s photo'
);

SELECT throws_ok(
  $$INSERT INTO public.rider_details
      (user_id, full_name, bike_make_model, bike_colour, plate_number, id_photo_path, selfie_path)
    VALUES (auth.uid(), 'Rider One', 'Bajaj Boxer', 'Blue', 'ede-111-cc',
      '00000000-0000-0000-0000-00000000a001/not-uploaded.jpg',
      '00000000-0000-0000-0000-00000000a001/selfie-1.jpg')$$,
  'P0001', 'KYC photos must be your own uploaded files',
  'a rider cannot submit a photo that was never uploaded'
);

SELECT throws_ok(
  $$INSERT INTO public.rider_details
      (user_id, full_name, bike_make_model, bike_colour, plate_number, id_photo_path, selfie_path,
       kyc_status)
    VALUES (auth.uid(), 'Rider One', 'Bajaj Boxer', 'Blue', 'ede-111-cc',
      '00000000-0000-0000-0000-00000000a001/id-1.jpg',
      '00000000-0000-0000-0000-00000000a001/selfie-1.jpg', 'approved')$$,
  'P0001', 'A new KYC submission must be pending and unreviewed',
  'a rider cannot submit themselves as approved'
);

SELECT lives_ok(
  $$INSERT INTO public.rider_details
      (user_id, full_name, bike_make_model, bike_colour, plate_number, id_photo_path, selfie_path)
    VALUES (auth.uid(), 'Rider One', 'Bajaj Boxer', 'Blue', '  ede-111-cc ',
      '00000000-0000-0000-0000-00000000a001/id-1.jpg',
      '00000000-0000-0000-0000-00000000a001/selfie-1.jpg')$$,
  'a rider with an active rider role can submit KYC'
);

SELECT is(
  (SELECT kyc_status::text || ' ' || plate_number FROM public.rider_details WHERE user_id = auth.uid()),
  'pending EDE-111-CC',
  'a new submission is pending and the plate is trimmed and uppercased'
);

SELECT is(
  (SELECT count(*) FROM public.rider_details),
  1::bigint,
  'a rider can only see their own KYC row'
);

-- Silently filtered by RLS; checked from the server context further down.
UPDATE public.rider_details SET bike_colour = 'Hacked'
 WHERE user_id = '00000000-0000-0000-0000-00000000a002';

SELECT throws_ok(
  $$UPDATE public.rider_details SET kyc_status = 'approved' WHERE user_id = auth.uid()$$,
  'P0001', 'Only an admin can change KYC status',
  'a rider cannot approve themselves'
);

SELECT throws_ok(
  $$UPDATE public.rider_details SET reviewed_at = now() WHERE user_id = auth.uid()$$,
  'P0001', 'Cannot change KYC review fields',
  'a rider cannot set review fields'
);

SELECT throws_ok(
  $$UPDATE public.rider_details SET plate_number = 'NEW-PLATE' WHERE user_id = auth.uid()$$,
  'P0001', 'KYC details can only be changed when resubmitting after a rejection',
  'KYC details are locked while pending'
);

SELECT throws_ok(
  $$UPDATE public.rider_details SET is_online = true WHERE user_id = auth.uid()$$,
  'P0001', 'Rider must be KYC approved with an active rider role to go online',
  'a rider who is not approved cannot go online'
);

-- ---------------------------------------------------------------------------
-- Server: reject r1; r2's row was not touched by r1
-- ---------------------------------------------------------------------------
RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);

SELECT is(
  (SELECT bike_colour FROM public.rider_details WHERE user_id = '00000000-0000-0000-0000-00000000a002'),
  'Red',
  'a rider cannot modify another rider''s KYC row'
);

SELECT throws_ok(
  $$UPDATE public.rider_details SET kyc_status = 'rejected'
     WHERE user_id = '00000000-0000-0000-0000-00000000a001'$$,
  '23514', NULL,
  'a rejection needs a reason'
);

SELECT lives_ok(
  $$UPDATE public.rider_details
       SET kyc_status = 'rejected', rejection_reason = 'ID photo is blurry'
     WHERE user_id = '00000000-0000-0000-0000-00000000a001'$$,
  'an admin can reject with a reason'
);

SELECT isnt(
  (SELECT reviewed_at FROM public.rider_details WHERE user_id = '00000000-0000-0000-0000-00000000a001'),
  NULL,
  'reviewed_at is recorded on rejection'
);

-- ---------------------------------------------------------------------------
-- r1: sees the reason and resubmits
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT is(
  (SELECT rejection_reason FROM public.rider_details WHERE user_id = auth.uid()),
  'ID photo is blurry',
  'a rejected rider can read the reason'
);

SELECT throws_ok(
  $$UPDATE public.rider_details SET rejection_reason = NULL WHERE user_id = auth.uid()$$,
  'P0001', 'Cannot change KYC review fields',
  'a rider cannot clear the rejection reason directly'
);

INSERT INTO storage.objects (bucket_id, name)
VALUES ('rider-kyc', '00000000-0000-0000-0000-00000000a001/id-2.jpg');

SELECT lives_ok(
  $$UPDATE public.rider_details
       SET id_photo_path = '00000000-0000-0000-0000-00000000a001/id-2.jpg', kyc_status = 'pending'
     WHERE user_id = auth.uid()$$,
  'a rejected rider can fix details and resubmit'
);

SELECT is(
  (SELECT kyc_status::text || ' ' || COALESCE(rejection_reason, 'no reason')
     FROM public.rider_details WHERE user_id = auth.uid()),
  'pending no reason',
  'resubmitting sets pending and clears the reason'
);

-- ---------------------------------------------------------------------------
-- Server: approve r1, then r1 can go online but cannot edit details
-- ---------------------------------------------------------------------------
RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);
UPDATE public.rider_details SET kyc_status = 'approved'
 WHERE user_id = '00000000-0000-0000-0000-00000000a001';
INSERT INTO public.rider_bank_accounts
  (rider_id, bank_name, account_number, account_name, name_match,
   status, verified_name, verified_name_match, recorded_by, reviewed_at)
SELECT user_id, 'Test Bank', '0000000301', full_name, 'match',
       'verified', full_name, 'match', 'test fixture', now()
  FROM public.rider_details WHERE user_id = '00000000-0000-0000-0000-00000000a001';

SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT lives_ok(
  $$UPDATE public.rider_details SET is_online = true WHERE user_id = auth.uid()$$,
  'an approved rider with an active rider role can go online'
);

SELECT throws_ok(
  $$UPDATE public.rider_details SET plate_number = 'NEW-PLATE' WHERE user_id = auth.uid()$$,
  'P0001', 'KYC details can only be changed when resubmitting after a rejection',
  'KYC details are locked after approval'
);

-- ---------------------------------------------------------------------------
-- s1: rider role suspended (customer role stays active)
-- ---------------------------------------------------------------------------
RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);
UPDATE public.user_roles SET status = 'suspended', suspended_reason = 'Test suspension'
 WHERE user_id = '00000000-0000-0000-0000-00000000a003' AND role = 'rider';

SELECT is(
  (SELECT is_online FROM public.rider_details WHERE user_id = '00000000-0000-0000-0000-00000000a003'),
  false,
  'suspending the rider role takes an online rider offline'
);

SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000a003","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT throws_ok(
  $$UPDATE public.rider_details SET is_online = true WHERE user_id = auth.uid()$$,
  'P0001', 'Rider must be KYC approved with an active rider role to go online',
  'a suspended rider cannot go online even with approved KYC'
);

SELECT throws_ok(
  $$INSERT INTO storage.objects (bucket_id, name)
    VALUES ('rider-kyc', '00000000-0000-0000-0000-00000000a003/id-2.jpg')$$,
  '42501', NULL,
  'a suspended rider cannot upload to rider-kyc'
);

SELECT lives_ok(
  $$SELECT public.create_order_from_quote(
      (SELECT id FROM public.order_quotes WHERE customer_id = auth.uid()),
      'Documents', 'Receiver One', '2348031234567')$$,
  'a suspended rider can still order as a customer'
);

RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);
UPDATE public.rider_details SET kyc_status = 'rejected', rejection_reason = 'Plate unreadable'
 WHERE user_id = '00000000-0000-0000-0000-00000000a003';

SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000a003","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT throws_ok(
  $$UPDATE public.rider_details SET kyc_status = 'pending' WHERE user_id = auth.uid()$$,
  'P0001', 'An active rider role is required to resubmit KYC',
  'a suspended rider cannot resubmit KYC'
);

-- ---------------------------------------------------------------------------
-- c1: customer only, unaffected
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000a004","role":"authenticated"}', true);

SELECT throws_ok(
  $$INSERT INTO public.rider_details
      (user_id, full_name, bike_make_model, bike_colour, plate_number, id_photo_path, selfie_path)
    VALUES (auth.uid(), 'Customer', 'Bike', 'Red', 'X',
      '00000000-0000-0000-0000-00000000a004/id.jpg', '00000000-0000-0000-0000-00000000a004/s.jpg')$$,
  'P0001', 'An active rider role is required to submit KYC',
  'a customer-only user cannot submit rider KYC'
);

SELECT throws_ok(
  $$INSERT INTO storage.objects (bucket_id, name)
    VALUES ('rider-kyc', '00000000-0000-0000-0000-00000000a004/id.jpg')$$,
  '42501', NULL,
  'a customer-only user cannot upload to rider-kyc'
);

SELECT is(
  (SELECT count(*) FROM storage.objects WHERE bucket_id = 'rider-kyc'),
  0::bigint,
  'a customer-only user cannot see any KYC files'
);

SELECT lives_ok(
  $$SELECT public.create_order_from_quote(
      (SELECT id FROM public.order_quotes WHERE customer_id = auth.uid()),
      'Documents', 'Receiver Two', '2348031234568')$$,
  'a customer-only user can still create orders'
);

-- ---------------------------------------------------------------------------
-- a1: admin sees everything and is recorded as reviewer
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000a005","role":"authenticated"}', true);

SELECT is(
  (SELECT count(*) FROM public.rider_details),
  3::bigint,
  'an admin can see every KYC row'
);

SELECT is(
  (SELECT count(*) FROM storage.objects WHERE bucket_id = 'rider-kyc'),
  7::bigint,
  'an admin can see every KYC file'
);

UPDATE public.rider_details SET kyc_status = 'approved'
 WHERE user_id = '00000000-0000-0000-0000-00000000a002';

SELECT is(
  (SELECT reviewed_by FROM public.rider_details WHERE user_id = '00000000-0000-0000-0000-00000000a002'),
  '00000000-0000-0000-0000-00000000a005'::uuid,
  'an admin approving in the app is recorded as reviewer'
);

RESET ROLE;

-- ---------------------------------------------------------------------------
-- SECURITY DEFINER functions are not callable by API roles that don't need them
-- ---------------------------------------------------------------------------
SELECT ok(
  NOT has_function_privilege('authenticated', 'public.rider_role_is_active(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.is_own_kyc_file(uuid, text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.protect_rider_details()', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.take_suspended_rider_offline()', 'EXECUTE'),
  'signed-in users cannot call the KYC helper functions directly'
);

SELECT ok(
  NOT has_function_privilege('anon', 'public.is_admin()', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.has_active_role(public.app_role)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.is_admin()', 'EXECUTE'),
  'role helpers are callable by signed-in users only'
);

SELECT ok(
  NOT (SELECT public FROM storage.buckets WHERE id = 'rider-kyc'),
  'the rider-kyc bucket is private'
);

SELECT * FROM finish();
ROLLBACK;
