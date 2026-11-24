-- Rider bank account: name check, rider submission, admin approve/reject/revoke,
-- locked records, the going-online rule, unique plates, and privileges.
-- Run locally with: supabase db start && supabase test db
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(52);

-- Users
--   r1 = approved rider "Adebayo Okafor"   r2 = approved rider "Tunde Bello"
--   r3 = rider who has not submitted KYC    s1 = approved rider, rider role suspended
--   c1 = customer only                      a1 = admin
-- Switching user: set the JWT claims and SET LOCAL ROLE authenticated.
-- Back to server context: RESET ROLE and clear the claims ('{}' => auth.role() is NULL).

-- ---------------------------------------------------------------------------
-- Fixtures (server context)
-- ---------------------------------------------------------------------------
INSERT INTO auth.users (id, phone) VALUES
  ('00000000-0000-0000-0000-00000000c001', '2348000000501'),
  ('00000000-0000-0000-0000-00000000c002', '2348000000502'),
  ('00000000-0000-0000-0000-00000000c003', '2348000000503'),
  ('00000000-0000-0000-0000-00000000c004', '2348000000504'),
  ('00000000-0000-0000-0000-00000000c005', '2348000000505'),
  ('00000000-0000-0000-0000-00000000c006', '2348000000506');

INSERT INTO public.user_roles (user_id, role) VALUES
  ('00000000-0000-0000-0000-00000000c001', 'rider'),
  ('00000000-0000-0000-0000-00000000c002', 'rider'),
  ('00000000-0000-0000-0000-00000000c003', 'rider'),
  ('00000000-0000-0000-0000-00000000c004', 'rider'),
  ('00000000-0000-0000-0000-00000000c005', 'customer'),
  ('00000000-0000-0000-0000-00000000c006', 'admin');

INSERT INTO public.rider_details
  (user_id, full_name, bike_make_model, bike_colour, plate_number, id_photo_path, selfie_path, kyc_status)
VALUES
  ('00000000-0000-0000-0000-00000000c001', 'Adebayo Okafor', 'Bajaj Boxer', 'Red', 'EDE-201',
   'c001/id.jpg', 'c001/selfie.jpg', 'approved'),
  ('00000000-0000-0000-0000-00000000c002', 'Tunde Bello', 'Honda Ace', 'Black', 'EDE-202',
   'c002/id.jpg', 'c002/selfie.jpg', 'approved'),
  ('00000000-0000-0000-0000-00000000c004', 'Suspended Rider', 'Bajaj Boxer', 'Blue', 'EDE-204',
   'c004/id.jpg', 'c004/selfie.jpg', 'approved');

UPDATE public.user_roles SET status = 'suspended', suspended_reason = 'Test suspension'
 WHERE user_id = '00000000-0000-0000-0000-00000000c004' AND role = 'rider';

-- ---------------------------------------------------------------------------
-- Name check
-- ---------------------------------------------------------------------------
SELECT is(
  public.bank_account_name_match('Mr. Adebayo Okafor', 'OKAFOR, ADEBAYO O.'),
  'match'::public.bank_name_match,
  'name check: case, punctuation, titles and order do not matter'
);

SELECT is(
  public.bank_account_name_match('Tunde Bello', 'BELLO AMINAT'),
  'partial'::public.bank_name_match,
  'name check: one shared name is partial'
);

SELECT is(
  public.bank_account_name_match('Tunde Bello', 'CHIDI OBI'),
  'mismatch'::public.bank_name_match,
  'name check: no shared name is a mismatch'
);

-- ---------------------------------------------------------------------------
-- r1: submits through the function only
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000c001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT throws_ok(
  $$INSERT INTO public.rider_bank_accounts (rider_id, bank_name, account_number, account_name, name_match)
    VALUES (auth.uid(), 'Opay', '1234567890', 'Adebayo Okafor', 'match')$$,
  '42501', NULL,
  'a rider cannot insert a bank account directly'
);

SELECT throws_ok(
  $$SELECT public.submit_rider_bank_account('Opay', '123456789', 'Adebayo Okafor')$$,
  'P0001', 'The account number must be exactly 10 digits',
  'an account number must have 10 digits'
);

SELECT throws_ok(
  $$SELECT public.submit_rider_bank_account('Opay', '12345678AB', 'Adebayo Okafor')$$,
  'P0001', 'The account number must be exactly 10 digits',
  'an account number must be digits only'
);

SELECT throws_ok(
  $$SELECT public.submit_rider_bank_account('  ', '1234567890', 'Adebayo Okafor')$$,
  'P0001', 'Choose your bank',
  'a bank is required'
);

SELECT lives_ok(
  $$SELECT public.submit_rider_bank_account('Opay', '1111111111', 'Adebayo Okafor')$$,
  'an approved rider can submit a bank account'
);

SELECT lives_ok(
  $$SELECT public.submit_rider_bank_account('  Moniepoint ', '0123 456 789', 'okafor adebayo')$$,
  'a rider can submit again before review (spaces are removed)'
);

SELECT is(
  (SELECT array_agg(status::text || ':' || bank_name || ':' || account_number || ':' || name_match::text
                    ORDER BY created_at, status)
     FROM public.rider_bank_accounts WHERE rider_id = auth.uid()),
  ARRAY['pending:Moniepoint:0123456789:match', 'withdrawn:Opay:1111111111:match'],
  'the new submission is pending with a name match; the earlier one is withdrawn'
);

SELECT throws_ok(
  $$UPDATE public.rider_bank_accounts SET account_number = '9999999999' WHERE rider_id = auth.uid()$$,
  '42501', NULL,
  'a rider cannot update a bank account directly'
);

SELECT throws_ok(
  $$DELETE FROM public.rider_bank_accounts WHERE rider_id = auth.uid()$$,
  '42501', NULL,
  'a rider cannot delete a bank account'
);

SELECT throws_ok(
  $$SELECT public.approve_rider_bank_account(
      (SELECT id FROM public.rider_bank_accounts WHERE rider_id = auth.uid() AND status = 'pending'),
      'OKAFOR ADEBAYO', 'me')$$,
  'P0001', 'Only an admin can approve bank accounts',
  'a rider cannot approve their own account'
);

SELECT throws_ok(
  $$UPDATE public.rider_details SET is_online = true WHERE user_id = auth.uid()$$,
  'P0001', 'A verified bank account is required to go online',
  'an approved rider with only a pending account cannot go online'
);

-- ---------------------------------------------------------------------------
-- r2: isolation and duplicates
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000c002","role":"authenticated"}', true);

SELECT is(
  (SELECT count(*) FROM public.rider_bank_accounts
    WHERE rider_id = '00000000-0000-0000-0000-00000000c001'),
  0::bigint,
  'a rider cannot see another rider''s bank accounts'
);

SELECT throws_ok(
  $$SELECT public.submit_rider_bank_account('MONIEPOINT', '0123456789', 'Tunde Bello')$$,
  'P0001', 'This bank account is already registered to another rider',
  'an account pending for another rider is refused (and the error has no account number)'
);

SELECT lives_ok(
  $$SELECT public.submit_rider_bank_account('Opay', '1111111111', 'Tunde Bello')$$,
  'an account only withdrawn by another rider can be used'
);

SELECT throws_ok(
  $$SELECT public.revoke_rider_bank_account(
      (SELECT id FROM public.rider_bank_accounts WHERE rider_id = auth.uid() LIMIT 1), 'x', 'me')$$,
  'P0001', 'Only an admin can revoke bank accounts',
  'a rider cannot revoke'
);

SELECT throws_ok(
  $$SELECT public.reject_rider_bank_account(
      (SELECT id FROM public.rider_bank_accounts WHERE rider_id = auth.uid() LIMIT 1), 'x', 'me')$$,
  'P0001', 'Only an admin can reject bank accounts',
  'a rider cannot reject'
);

SELECT throws_ok(
  $$UPDATE public.rider_details SET plate_released = true WHERE user_id = auth.uid()$$,
  'P0001', 'Only an admin can release a plate',
  'a rider cannot release their plate'
);

-- ---------------------------------------------------------------------------
-- r3 (no KYC), s1 (suspended), c1 (customer only)
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000c003","role":"authenticated"}', true);

SELECT throws_ok(
  $$SELECT public.submit_rider_bank_account('Opay', '3333333333', 'Rider Three')$$,
  'P0001', 'Submit your rider verification before adding a bank account',
  'a rider without KYC cannot add a bank account'
);

SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000c004","role":"authenticated"}', true);

SELECT throws_ok(
  $$SELECT public.submit_rider_bank_account('Opay', '4444444444', 'Suspended Rider')$$,
  'P0001', 'An active rider role is required to add a bank account',
  'a suspended rider cannot add a bank account'
);

SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000c005","role":"authenticated"}', true);

SELECT throws_ok(
  $$SELECT public.submit_rider_bank_account('Opay', '5555555555', 'Customer Only')$$,
  'P0001', 'An active rider role is required to add a bank account',
  'a customer without a rider role cannot add a bank account'
);

-- ---------------------------------------------------------------------------
-- a1: approve and reject
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000c006","role":"authenticated"}', true);

SELECT is(
  (SELECT count(*) FROM public.rider_bank_accounts),
  3::bigint,
  'an admin can see every bank account'
);

SELECT throws_ok(
  $$SELECT public.approve_rider_bank_account(
      (SELECT id FROM public.rider_bank_accounts
        WHERE rider_id = '00000000-0000-0000-0000-00000000c001' AND status = 'pending'),
      'SOMEONE ELSE', 'Admin Ade')$$,
  'P0001', 'A name mismatch can only be approved with a review note',
  'approval needs a note when the name from the admin''s enquiry does not match'
);

SELECT throws_ok(
  $$SELECT public.approve_rider_bank_account(
      (SELECT id FROM public.rider_bank_accounts
        WHERE rider_id = '00000000-0000-0000-0000-00000000c001' AND status = 'pending'),
      'OKAFOR ADEBAYO', '  ')$$,
  'P0001', 'Enter who is recording this',
  'approval needs "recorded by"'
);

SELECT lives_ok(
  $$SELECT public.approve_rider_bank_account(
      (SELECT id FROM public.rider_bank_accounts
        WHERE rider_id = '00000000-0000-0000-0000-00000000c001' AND status = 'pending'),
      'OKAFOR ADEBAYO', 'Admin Ade')$$,
  'an admin can approve a matching account'
);

SELECT is(
  (SELECT status::text || ' ' || verified_name_match::text || ' ' || recorded_by || ' ' || reviewed_by::text
     FROM public.rider_bank_accounts
    WHERE rider_id = '00000000-0000-0000-0000-00000000c001' AND bank_name = 'Moniepoint'),
  'verified match Admin Ade 00000000-0000-0000-0000-00000000c006',
  'approval records the status, the enquiry match, who recorded it and the reviewer'
);

SELECT throws_ok(
  $$SELECT public.approve_rider_bank_account(
      (SELECT id FROM public.rider_bank_accounts
        WHERE rider_id = '00000000-0000-0000-0000-00000000c001' AND status = 'verified'),
      'OKAFOR ADEBAYO', 'Admin Ade')$$,
  'P0001', 'Only a pending bank account can be approved',
  'a verified account cannot be approved again'
);

SELECT throws_ok(
  $$SELECT public.reject_rider_bank_account(
      (SELECT id FROM public.rider_bank_accounts
        WHERE rider_id = '00000000-0000-0000-0000-00000000c002' AND status = 'pending'),
      '', 'Admin Ade')$$,
  'P0001', 'A rejection needs a reason the rider can act on',
  'a rejection needs a reason'
);

SELECT lives_ok(
  $$SELECT public.reject_rider_bank_account(
      (SELECT id FROM public.rider_bank_accounts
        WHERE rider_id = '00000000-0000-0000-0000-00000000c002' AND status = 'pending'),
      'The account name does not match your ID', 'Admin Ade')$$,
  'an admin can reject a pending account with a reason'
);

RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);

-- r2 submits an account in someone else's name: a mismatch.
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000c002","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT public.submit_rider_bank_account('Kuda', '2222222222', 'Chidi Obi');

SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000c006","role":"authenticated"}', true);

SELECT throws_ok(
  $$SELECT public.approve_rider_bank_account(
      (SELECT id FROM public.rider_bank_accounts
        WHERE rider_id = '00000000-0000-0000-0000-00000000c002' AND status = 'pending'),
      'CHIDI OBI', 'Admin Ade', '   ')$$,
  'P0001', 'A name mismatch can only be approved with a review note',
  'a mismatched account cannot be approved without a note'
);

SELECT lives_ok(
  $$SELECT public.approve_rider_bank_account(
      (SELECT id FROM public.rider_bank_accounts
        WHERE rider_id = '00000000-0000-0000-0000-00000000c002' AND status = 'pending'),
      'CHIDI OBI', 'Admin Ade', 'Account belongs to the rider''s brother; confirmed by phone')$$,
  'a mismatched account can be approved with a review note'
);

-- ---------------------------------------------------------------------------
-- Records are locked, even for the server
-- ---------------------------------------------------------------------------
RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);

SELECT throws_ok(
  $$UPDATE public.rider_bank_accounts SET account_number = '9999999999'
     WHERE rider_id = '00000000-0000-0000-0000-00000000c001' AND status = 'verified'$$,
  'P0001', 'A bank account cannot be changed; submit a new one instead',
  'the account number cannot be changed, even by the server'
);

SELECT throws_ok(
  $$UPDATE public.rider_bank_accounts SET status = 'pending'
     WHERE rider_id = '00000000-0000-0000-0000-00000000c001' AND status = 'verified'$$,
  'P0001', 'This bank account status change is not allowed',
  'a verified account cannot go back to pending'
);

SELECT throws_ok(
  $$DELETE FROM public.rider_bank_accounts WHERE rider_id = '00000000-0000-0000-0000-00000000c001'$$,
  'P0001', 'Bank account records cannot be deleted',
  'bank account records cannot be deleted, even by the server'
);

-- ---------------------------------------------------------------------------
-- Going online, changing account, revoking
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000c001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT lives_ok(
  $$UPDATE public.rider_details SET is_online = true WHERE user_id = auth.uid()$$,
  'a rider with a verified account can go online'
);

SELECT throws_ok(
  $$SELECT public.submit_rider_bank_account('moniepoint', '0123456789', 'Adebayo Okafor')$$,
  'P0001', 'This is already your verified bank account',
  'a rider cannot resubmit their verified account'
);

SELECT lives_ok(
  $$SELECT public.submit_rider_bank_account('Palmpay', '7777777777', 'Adebayo Okafor')$$,
  'a verified rider can ask to change account'
);

SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000c006","role":"authenticated"}', true);
SELECT public.approve_rider_bank_account(
  (SELECT id FROM public.rider_bank_accounts
    WHERE rider_id = '00000000-0000-0000-0000-00000000c001' AND status = 'pending'),
  'ADEBAYO OKAFOR', 'Admin Ade', 'Rider phoned and confirmed the change');

SELECT is(
  (SELECT array_agg(bank_name || ':' || status::text ORDER BY bank_name)
     FROM public.rider_bank_accounts
    WHERE rider_id = '00000000-0000-0000-0000-00000000c001' AND status <> 'withdrawn'),
  ARRAY['Moniepoint:replaced', 'Palmpay:verified'],
  'approving a new account replaces the old verified one'
);

SELECT is(
  (SELECT is_online FROM public.rider_details WHERE user_id = '00000000-0000-0000-0000-00000000c001'),
  true,
  'changing account keeps the rider online'
);

SELECT throws_ok(
  $$SELECT public.revoke_rider_bank_account(
      (SELECT id FROM public.rider_bank_accounts
        WHERE rider_id = '00000000-0000-0000-0000-00000000c001' AND status = 'replaced'),
      'Closed account', 'Admin Ade')$$,
  'P0001', 'Only a verified bank account can be revoked',
  'only a verified account can be revoked'
);

SELECT throws_ok(
  $$SELECT public.revoke_rider_bank_account(
      (SELECT id FROM public.rider_bank_accounts
        WHERE rider_id = '00000000-0000-0000-0000-00000000c001' AND status = 'verified'),
      '', 'Admin Ade')$$,
  'P0001', 'A revocation needs a reason',
  'a revocation needs a reason'
);

SELECT lives_ok(
  $$SELECT public.revoke_rider_bank_account(
      (SELECT id FROM public.rider_bank_accounts
        WHERE rider_id = '00000000-0000-0000-0000-00000000c001' AND status = 'verified'),
      'Customer reported payments not arriving', 'Admin Ade')$$,
  'an admin can revoke a verified account'
);

SELECT is(
  (SELECT rd.is_online::text || ' ' || b.status::text || ' ' || b.revoked_recorded_by
     FROM public.rider_details rd
     JOIN public.rider_bank_accounts b ON b.rider_id = rd.user_id AND b.bank_name = 'Palmpay'
    WHERE rd.user_id = '00000000-0000-0000-0000-00000000c001'),
  'false revoked Admin Ade',
  'revoking takes the rider offline and records who revoked it'
);

SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000c001","role":"authenticated"}', true);

SELECT throws_ok(
  $$UPDATE public.rider_details SET is_online = true WHERE user_id = auth.uid()$$,
  'P0001', 'A verified bank account is required to go online',
  'after a revocation the rider cannot go online'
);

SELECT public.submit_rider_bank_account('GTBank', '8888888888', 'Adebayo Okafor');
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000c006","role":"authenticated"}', true);
SELECT public.approve_rider_bank_account(
  (SELECT id FROM public.rider_bank_accounts
    WHERE rider_id = '00000000-0000-0000-0000-00000000c001' AND status = 'pending'),
  'ADEBAYO OKAFOR', 'Admin Ade');
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000c001","role":"authenticated"}', true);

SELECT lives_ok(
  $$UPDATE public.rider_details SET is_online = true WHERE user_id = auth.uid()$$,
  'with a new verified account the rider can go online again'
);

-- ---------------------------------------------------------------------------
-- Unique plates (server context: same index the app's KYC insert hits)
-- ---------------------------------------------------------------------------
RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);

SELECT throws_ok(
  $$INSERT INTO public.rider_details
      (user_id, full_name, bike_make_model, bike_colour, plate_number, id_photo_path, selfie_path)
    VALUES ('00000000-0000-0000-0000-00000000c003', 'Rider Three', 'Bajaj', 'Red', ' ede-201 ',
            'c003/id.jpg', 'c003/selfie.jpg')$$,
  '23505', NULL,
  'a plate already registered to another rider is refused (after trimming and uppercasing)'
);

UPDATE public.rider_details SET plate_released = true
 WHERE user_id = '00000000-0000-0000-0000-00000000c001';

SELECT lives_ok(
  $$INSERT INTO public.rider_details
      (user_id, full_name, bike_make_model, bike_colour, plate_number, id_photo_path, selfie_path)
    VALUES ('00000000-0000-0000-0000-00000000c003', 'Rider Three', 'Bajaj', 'Red', 'EDE-201',
            'c003/id.jpg', 'c003/selfie.jpg')$$,
  'after an admin releases the plate, a new rider can register it'
);

-- ---------------------------------------------------------------------------
-- Privileges and search_path
-- ---------------------------------------------------------------------------
SELECT ok(
  NOT has_function_privilege('anon', 'public.submit_rider_bank_account(text, text, text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.approve_rider_bank_account(uuid, text, text, text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.reject_rider_bank_account(uuid, text, text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.revoke_rider_bank_account(uuid, text, text)', 'EXECUTE')
  AND NOT has_table_privilege('anon', 'public.rider_bank_accounts', 'SELECT'),
  'anonymous users cannot call the bank account functions or read the table'
);

SELECT ok(
  NOT has_function_privilege('authenticated', 'public.bank_account_name_match(text, text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.rider_has_verified_bank_account(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.rider_bank_accounts_before_insert()', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.rider_bank_accounts_protect()', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.protect_rider_details()', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.submit_rider_bank_account(text, text, text)', 'EXECUTE'),
  'signed-in users can call submit, but not the internal helpers'
);

SELECT is(
  (SELECT array_agg(p.proname::text ORDER BY p.proname)
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('bank_account_name_match', 'rider_bank_accounts_before_insert',
                        'rider_bank_accounts_protect', 'rider_has_verified_bank_account',
                        'submit_rider_bank_account', 'approve_rider_bank_account',
                        'reject_rider_bank_account', 'revoke_rider_bank_account',
                        'protect_rider_details')
      AND NOT coalesce(p.proconfig @> ARRAY['search_path=""'], false)),
  NULL,
  'every new or replaced function sets an empty search_path'
);

SELECT * FROM finish();
ROLLBACK;
