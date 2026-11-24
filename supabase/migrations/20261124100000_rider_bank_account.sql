-- Rider bank account (payment model step 2): the account customers pay into.
-- Server/admin writes only, name check against the KYC name, admin approval,
-- revocation, a verified account required to go online, and unique plates.
-- See docs/rider-bank-account-admin.md (including the hosted pre-push check).
--
-- Account numbers must never appear in error messages or logs: every error raised
-- here is a fixed message, and the submit function turns constraint errors (whose
-- DETAIL would contain the row) into a generic message.

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------
CREATE TYPE public.bank_account_status AS ENUM (
  'pending',   -- submitted by the rider, waiting for an admin
  'verified',  -- approved: customers pay into this account
  'rejected',  -- refused by an admin (reason required)
  'withdrawn', -- the rider submitted another account before this one was reviewed
  'replaced',  -- was verified; a newer account was verified
  'revoked'    -- was verified; an admin withdrew it (reason required)
);

CREATE TYPE public.bank_name_match AS ENUM ('match', 'partial', 'mismatch');

-- ---------------------------------------------------------------------------
-- Name check: compares two names ignoring case, punctuation, titles and order.
-- 2+ shared names = match, 1 = partial, 0 = mismatch.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bank_account_name_match(p_kyc_name text, p_account_name text)
RETURNS public.bank_name_match
LANGUAGE sql
IMMUTABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  WITH titles(t) AS (
    VALUES ('MR'), ('MRS'), ('MS'), ('MISS'), ('DR'), ('ALHAJI'), ('ALH'), ('ALHAJA'),
           ('HAJIA'), ('CHIEF'), ('PASTOR'), ('PST'), ('ENGR'), ('PROF'), ('REV'),
           ('EVANG'), ('BARR'), ('HON'), ('SIR'), ('MADAM'), ('MALLAM'), ('MAL')
  ),
  a AS (
    SELECT DISTINCT tok
      FROM regexp_split_to_table(regexp_replace(upper(coalesce(p_kyc_name, '')), '[^A-Z]+', ' ', 'g'), ' ') AS tok
     WHERE length(tok) >= 2 AND tok NOT IN (SELECT t FROM titles)
  ),
  b AS (
    SELECT DISTINCT tok
      FROM regexp_split_to_table(regexp_replace(upper(coalesce(p_account_name, '')), '[^A-Z]+', ' ', 'g'), ' ') AS tok
     WHERE length(tok) >= 2 AND tok NOT IN (SELECT t FROM titles)
  )
  SELECT CASE
           WHEN count(*) >= 2 THEN 'match'
           WHEN count(*) = 1 THEN 'partial'
           ELSE 'mismatch'
         END::public.bank_name_match
    FROM a JOIN b USING (tok);
$$;

REVOKE ALL ON FUNCTION public.bank_account_name_match(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bank_account_name_match(text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- rider_bank_accounts: one row per submitted account; rows are never deleted
-- ---------------------------------------------------------------------------
CREATE TABLE public.rider_bank_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rider_id uuid NOT NULL REFERENCES public.rider_details (user_id),
  bank_name text NOT NULL,
  account_number text NOT NULL,
  -- The name as the rider says their bank shows it.
  account_name text NOT NULL,
  -- account_name compared with the KYC name, when submitted.
  name_match public.bank_name_match NOT NULL,
  status public.bank_account_status NOT NULL DEFAULT 'pending',
  -- Review (approve or reject). recorded_by is free text: the SQL Editor has no user.
  verified_name text,               -- the name the admin saw in their own name enquiry
  verified_name_match public.bank_name_match,
  review_note text,
  recorded_by text,
  reviewed_at timestamptz,
  reviewed_by uuid REFERENCES public.profiles (id),
  -- Rejection or revocation reason.
  reason text,
  revoked_at timestamptz,
  revoked_recorded_by text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT rider_bank_accounts_bank_name CHECK (btrim(bank_name) <> '' AND length(bank_name) <= 100),
  CONSTRAINT rider_bank_accounts_account_number CHECK (account_number ~ '^[0-9]{10}$'),
  CONSTRAINT rider_bank_accounts_account_name CHECK (length(btrim(account_name)) BETWEEN 2 AND 100),
  CONSTRAINT rider_bank_accounts_reason CHECK (
    (status IN ('rejected', 'revoked')) = (reason IS NOT NULL AND btrim(reason) <> '')
  ),
  CONSTRAINT rider_bank_accounts_reviewed CHECK (
    status IN ('pending', 'withdrawn')
    OR (recorded_by IS NOT NULL AND btrim(recorded_by) <> '' AND reviewed_at IS NOT NULL)
  ),
  CONSTRAINT rider_bank_accounts_verified CHECK (
    status NOT IN ('verified', 'replaced', 'revoked')
    OR (verified_name IS NOT NULL AND btrim(verified_name) <> '' AND verified_name_match IS NOT NULL)
  ),
  CONSTRAINT rider_bank_accounts_revoked CHECK (
    (status = 'revoked')
    = (revoked_at IS NOT NULL AND revoked_recorded_by IS NOT NULL AND btrim(revoked_recorded_by) <> '')
  )
);

-- At most one pending and one verified account per rider.
CREATE UNIQUE INDEX rider_bank_accounts_one_pending
  ON public.rider_bank_accounts (rider_id) WHERE status = 'pending';
CREATE UNIQUE INDEX rider_bank_accounts_one_verified
  ON public.rider_bank_accounts (rider_id) WHERE status = 'verified';
-- Duplicate check across riders (enforced by trigger, so the error carries no number).
CREATE INDEX rider_bank_accounts_active_number_idx
  ON public.rider_bank_accounts (lower(bank_name), account_number)
  WHERE status IN ('pending', 'verified');
CREATE INDEX rider_bank_accounts_rider_created_idx
  ON public.rider_bank_accounts (rider_id, created_at DESC);
CREATE INDEX rider_bank_accounts_pending_idx
  ON public.rider_bank_accounts (created_at) WHERE status = 'pending';

-- ---------------------------------------------------------------------------
-- Insert: clean the text, compute the name match, refuse an account that is
-- pending or verified for another rider.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rider_bank_accounts_before_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  kyc_name text;
BEGIN
  NEW.bank_name := regexp_replace(btrim(NEW.bank_name), '\s+', ' ', 'g');
  NEW.account_number := regexp_replace(NEW.account_number, '\s+', '', 'g');
  NEW.account_name := regexp_replace(btrim(NEW.account_name), '\s+', ' ', 'g');

  SELECT rd.full_name INTO kyc_name FROM public.rider_details rd WHERE rd.user_id = NEW.rider_id;
  NEW.name_match := public.bank_account_name_match(kyc_name, NEW.account_name);

  -- Serialise checks for the same account so two riders can't race past each other.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(lower(NEW.bank_name) || ':' || NEW.account_number, 0));
  IF NEW.status IN ('pending', 'verified') AND EXISTS (
    SELECT 1 FROM public.rider_bank_accounts b
     WHERE lower(b.bank_name) = lower(NEW.bank_name)
       AND b.account_number = NEW.account_number
       AND b.status IN ('pending', 'verified')
       AND b.rider_id <> NEW.rider_id
  ) THEN
    RAISE EXCEPTION 'This bank account is already registered to another rider';
  END IF;

  NEW.created_at := now();
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.rider_bank_accounts_before_insert() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER rider_bank_accounts_before_insert
  BEFORE INSERT ON public.rider_bank_accounts
  FOR EACH ROW
  EXECUTE FUNCTION public.rider_bank_accounts_before_insert();

-- ---------------------------------------------------------------------------
-- Update/delete: the account itself never changes, status only moves forward,
-- rows are never deleted. Applies to everyone, admins and the server included.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rider_bank_accounts_protect()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Bank account records cannot be deleted';
  END IF;

  IF (NEW.id, NEW.rider_id, NEW.bank_name, NEW.account_number, NEW.account_name, NEW.name_match, NEW.created_at)
     IS DISTINCT FROM
     (OLD.id, OLD.rider_id, OLD.bank_name, OLD.account_number, OLD.account_name, OLD.name_match, OLD.created_at) THEN
    RAISE EXCEPTION 'A bank account cannot be changed; submit a new one instead';
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
       (OLD.status = 'pending' AND NEW.status IN ('verified', 'rejected', 'withdrawn'))
    OR (OLD.status = 'verified' AND NEW.status IN ('replaced', 'revoked'))
  ) THEN
    RAISE EXCEPTION 'This bank account status change is not allowed';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.rider_bank_accounts_protect() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER rider_bank_accounts_protect
  BEFORE UPDATE OR DELETE ON public.rider_bank_accounts
  FOR EACH ROW
  EXECUTE FUNCTION public.rider_bank_accounts_protect();

-- ---------------------------------------------------------------------------
-- Row Level Security: riders read their own rows, admins read all.
-- No INSERT/UPDATE/DELETE policies: writes go through the functions below.
-- ---------------------------------------------------------------------------
ALTER TABLE public.rider_bank_accounts ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.rider_bank_accounts FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.rider_bank_accounts FROM authenticated;

CREATE POLICY rider_bank_accounts_select_own_or_admin
  ON public.rider_bank_accounts FOR SELECT TO authenticated
  USING (rider_id = (SELECT auth.uid()) OR public.is_admin());

-- ---------------------------------------------------------------------------
-- Helper: does this rider have a verified account? (used by the online rule)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rider_has_verified_bank_account(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.rider_bank_accounts
     WHERE rider_id = p_user_id AND status = 'verified'
  );
$$;

REVOKE ALL ON FUNCTION public.rider_has_verified_bank_account(uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Rider: submit an account (any earlier pending one is withdrawn).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_rider_bank_account(
  p_bank_name text,
  p_account_number text,
  p_account_name text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  uid uuid := auth.uid();
  v_bank text := regexp_replace(btrim(coalesce(p_bank_name, '')), '\s+', ' ', 'g');
  v_number text := regexp_replace(coalesce(p_account_number, ''), '\s+', '', 'g');
  v_name text := regexp_replace(btrim(coalesce(p_account_name, '')), '\s+', ' ', 'g');
  new_id uuid;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'Sign in to add a bank account';
  END IF;
  IF NOT public.rider_role_is_active(uid) THEN
    RAISE EXCEPTION 'An active rider role is required to add a bank account';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rider_details WHERE user_id = uid) THEN
    RAISE EXCEPTION 'Submit your rider verification before adding a bank account';
  END IF;

  IF v_bank = '' OR length(v_bank) > 100 THEN
    RAISE EXCEPTION 'Choose your bank';
  END IF;
  IF v_number !~ '^[0-9]{10}$' THEN
    RAISE EXCEPTION 'The account number must be exactly 10 digits';
  END IF;
  IF length(v_name) < 2 OR length(v_name) > 100 THEN
    RAISE EXCEPTION 'Enter the account name as your bank shows it';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.rider_bank_accounts
     WHERE rider_id = uid AND status = 'verified'
       AND lower(bank_name) = lower(v_bank) AND account_number = v_number
  ) THEN
    RAISE EXCEPTION 'This is already your verified bank account';
  END IF;

  UPDATE public.rider_bank_accounts
     SET status = 'withdrawn'
   WHERE rider_id = uid AND status = 'pending';

  BEGIN
    INSERT INTO public.rider_bank_accounts (rider_id, bank_name, account_number, account_name, name_match)
    VALUES (uid, v_bank, v_number, v_name, 'mismatch') -- name_match is recomputed by the trigger
    RETURNING id INTO new_id;
  EXCEPTION
    -- These errors' DETAIL would include the row; replace them with a fixed message.
    WHEN unique_violation OR check_violation OR not_null_violation OR foreign_key_violation THEN
      RAISE EXCEPTION 'We could not save this bank account. Please try again.';
  END;

  RETURN new_id;
END;
$$;

REVOKE ALL ON FUNCTION public.submit_rider_bank_account(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_rider_bank_account(text, text, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Admin: approve, reject, revoke. Callable by an admin in the app, the server,
-- or the SQL Editor (no JWT => trusted server context).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.approve_rider_bank_account(
  p_account_id uuid,
  p_verified_name text,
  p_recorded_by text,
  p_note text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  acct public.rider_bank_accounts%ROWTYPE;
  kyc_name text;
  v_match public.bank_name_match;
BEGIN
  IF NOT (COALESCE(auth.role(), 'service_role') = 'service_role' OR public.is_admin()) THEN
    RAISE EXCEPTION 'Only an admin can approve bank accounts';
  END IF;

  SELECT * INTO acct FROM public.rider_bank_accounts WHERE id = p_account_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Bank account not found';
  END IF;
  IF acct.status <> 'pending' THEN
    RAISE EXCEPTION 'Only a pending bank account can be approved';
  END IF;
  IF btrim(coalesce(p_verified_name, '')) = '' THEN
    RAISE EXCEPTION 'Enter the account name from your own name enquiry';
  END IF;
  IF btrim(coalesce(p_recorded_by, '')) = '' THEN
    RAISE EXCEPTION 'Enter who is recording this';
  END IF;

  SELECT rd.full_name INTO kyc_name FROM public.rider_details rd WHERE rd.user_id = acct.rider_id;
  v_match := public.bank_account_name_match(kyc_name, p_verified_name);

  IF (acct.name_match = 'mismatch' OR v_match = 'mismatch')
     AND btrim(coalesce(p_note, '')) = '' THEN
    RAISE EXCEPTION 'A name mismatch can only be approved with a review note';
  END IF;

  UPDATE public.rider_bank_accounts
     SET status = 'replaced'
   WHERE rider_id = acct.rider_id AND status = 'verified';

  UPDATE public.rider_bank_accounts
     SET status = 'verified',
         verified_name = btrim(p_verified_name),
         verified_name_match = v_match,
         recorded_by = btrim(p_recorded_by),
         review_note = NULLIF(btrim(coalesce(p_note, '')), ''),
         reviewed_at = now(),
         reviewed_by = auth.uid() -- NULL from the SQL Editor
   WHERE id = acct.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.reject_rider_bank_account(
  p_account_id uuid,
  p_reason text,
  p_recorded_by text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  acct public.rider_bank_accounts%ROWTYPE;
BEGIN
  IF NOT (COALESCE(auth.role(), 'service_role') = 'service_role' OR public.is_admin()) THEN
    RAISE EXCEPTION 'Only an admin can reject bank accounts';
  END IF;

  SELECT * INTO acct FROM public.rider_bank_accounts WHERE id = p_account_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Bank account not found';
  END IF;
  IF acct.status <> 'pending' THEN
    RAISE EXCEPTION 'Only a pending bank account can be rejected';
  END IF;
  IF btrim(coalesce(p_reason, '')) = '' THEN
    RAISE EXCEPTION 'A rejection needs a reason the rider can act on';
  END IF;
  IF btrim(coalesce(p_recorded_by, '')) = '' THEN
    RAISE EXCEPTION 'Enter who is recording this';
  END IF;

  UPDATE public.rider_bank_accounts
     SET status = 'rejected',
         reason = btrim(p_reason),
         recorded_by = btrim(p_recorded_by),
         reviewed_at = now(),
         reviewed_by = auth.uid()
   WHERE id = acct.id;
END;
$$;

-- Withdraw a verified account (fraud, closed account, rider's request). The rider
-- goes offline and cannot go online until a new account is verified.
CREATE OR REPLACE FUNCTION public.revoke_rider_bank_account(
  p_account_id uuid,
  p_reason text,
  p_recorded_by text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  acct public.rider_bank_accounts%ROWTYPE;
BEGIN
  IF NOT (COALESCE(auth.role(), 'service_role') = 'service_role' OR public.is_admin()) THEN
    RAISE EXCEPTION 'Only an admin can revoke bank accounts';
  END IF;

  SELECT * INTO acct FROM public.rider_bank_accounts WHERE id = p_account_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Bank account not found';
  END IF;
  IF acct.status <> 'verified' THEN
    RAISE EXCEPTION 'Only a verified bank account can be revoked';
  END IF;
  IF btrim(coalesce(p_reason, '')) = '' THEN
    RAISE EXCEPTION 'A revocation needs a reason';
  END IF;
  IF btrim(coalesce(p_recorded_by, '')) = '' THEN
    RAISE EXCEPTION 'Enter who is recording this';
  END IF;

  UPDATE public.rider_bank_accounts
     SET status = 'revoked',
         reason = btrim(p_reason),
         revoked_at = now(),
         revoked_recorded_by = btrim(p_recorded_by)
   WHERE id = acct.id;

  UPDATE public.rider_details
     SET is_online = false
   WHERE user_id = acct.rider_id AND is_online;
END;
$$;

REVOKE ALL ON FUNCTION public.approve_rider_bank_account(uuid, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.reject_rider_bank_account(uuid, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.revoke_rider_bank_account(uuid, text, text) FROM PUBLIC, anon;
-- Signed-in users can call them, but only admins get past the check inside.
GRANT EXECUTE ON FUNCTION public.approve_rider_bank_account(uuid, text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reject_rider_bank_account(uuid, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.revoke_rider_bank_account(uuid, text, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- rider_details: unique plates (admin can release a plate), no bank_account_ref
-- ---------------------------------------------------------------------------
ALTER TABLE public.rider_details DROP COLUMN bank_account_ref;

-- Set by an admin on the OLD owner's row to free the plate for a new owner.
ALTER TABLE public.rider_details ADD COLUMN plate_released boolean NOT NULL DEFAULT false;

CREATE UNIQUE INDEX rider_details_plate_number_unique
  ON public.rider_details (plate_number)
  WHERE NOT plate_released;

-- ---------------------------------------------------------------------------
-- protect_rider_details: as in 20261122100000_rider_kyc.sql, plus
--   * riders cannot set plate_released;
--   * going online also needs a verified bank account (and losing it takes the
--     rider offline).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.protect_rider_details()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  privileged boolean := COALESCE(auth.role(), 'service_role') = 'service_role' OR public.is_admin();
  details_changed boolean;
BEGIN
  NEW.plate_number := upper(btrim(NEW.plate_number));

  IF TG_OP = 'INSERT' THEN
    IF NOT privileged THEN
      IF NEW.user_id IS DISTINCT FROM auth.uid() THEN
        RAISE EXCEPTION 'Cannot submit KYC for another user';
      END IF;
      IF NOT public.rider_role_is_active(NEW.user_id) THEN
        RAISE EXCEPTION 'An active rider role is required to submit KYC';
      END IF;
      IF NEW.kyc_status <> 'pending'
         OR NEW.rejection_reason IS NOT NULL
         OR NEW.reviewed_at IS NOT NULL
         OR NEW.reviewed_by IS NOT NULL THEN
        RAISE EXCEPTION 'A new KYC submission must be pending and unreviewed';
      END IF;
      IF NEW.plate_released THEN
        RAISE EXCEPTION 'Only an admin can release a plate';
      END IF;
      IF NOT public.is_own_kyc_file(NEW.user_id, NEW.id_photo_path)
         OR NOT public.is_own_kyc_file(NEW.user_id, NEW.selfie_path) THEN
        RAISE EXCEPTION 'KYC photos must be your own uploaded files';
      END IF;
    END IF;
    NEW.submitted_at := now();
  ELSE
    IF NEW.user_id IS DISTINCT FROM OLD.user_id THEN
      RAISE EXCEPTION 'Cannot change rider identity';
    END IF;

    details_changed :=
      (NEW.full_name, NEW.bike_make_model, NEW.bike_colour, NEW.plate_number,
       NEW.vehicle_type, NEW.id_photo_path, NEW.selfie_path)
      IS DISTINCT FROM
      (OLD.full_name, OLD.bike_make_model, OLD.bike_colour, OLD.plate_number,
       OLD.vehicle_type, OLD.id_photo_path, OLD.selfie_path);

    IF NOT privileged THEN
      IF NEW.rejection_reason IS DISTINCT FROM OLD.rejection_reason
         OR NEW.reviewed_at IS DISTINCT FROM OLD.reviewed_at
         OR NEW.reviewed_by IS DISTINCT FROM OLD.reviewed_by
         OR NEW.submitted_at IS DISTINCT FROM OLD.submitted_at THEN
        RAISE EXCEPTION 'Cannot change KYC review fields';
      END IF;

      IF NEW.plate_released IS DISTINCT FROM OLD.plate_released THEN
        RAISE EXCEPTION 'Only an admin can release a plate';
      END IF;

      IF NEW.kyc_status IS DISTINCT FROM OLD.kyc_status THEN
        IF NOT (OLD.kyc_status = 'rejected' AND NEW.kyc_status = 'pending') THEN
          RAISE EXCEPTION 'Only an admin can change KYC status';
        END IF;
        -- Resubmission after a rejection
        IF NOT public.rider_role_is_active(NEW.user_id) THEN
          RAISE EXCEPTION 'An active rider role is required to resubmit KYC';
        END IF;
        IF NOT public.is_own_kyc_file(NEW.user_id, NEW.id_photo_path)
           OR NOT public.is_own_kyc_file(NEW.user_id, NEW.selfie_path) THEN
          RAISE EXCEPTION 'KYC photos must be your own uploaded files';
        END IF;
        NEW.submitted_at := now();
      ELSIF details_changed THEN
        RAISE EXCEPTION 'KYC details can only be changed when resubmitting after a rejection';
      END IF;
    ELSIF NEW.kyc_status IS DISTINCT FROM OLD.kyc_status
          AND NEW.kyc_status IN ('approved', 'rejected') THEN
      NEW.reviewed_at := now();
      NEW.reviewed_by := auth.uid(); -- NULL from the SQL editor
    END IF;
  END IF;

  -- The reason only belongs to a rejection; leaving "rejected" clears it.
  IF NEW.kyc_status <> 'rejected' THEN
    NEW.rejection_reason := NULL;
  END IF;

  -- Going online needs approved KYC and an active rider role (SPEC 10.7, per-role suspension).
  IF NEW.is_online
     AND (NEW.kyc_status <> 'approved' OR NOT public.rider_role_is_active(NEW.user_id)) THEN
    IF TG_OP = 'INSERT' OR NOT OLD.is_online THEN
      RAISE EXCEPTION 'Rider must be KYC approved with an active rider role to go online';
    END IF;
    -- Already online (e.g. an admin just rejected them): take them offline.
    NEW.is_online := false;
  END IF;

  -- ...and a verified bank account for customers to pay into (SPEC 10.8).
  IF NEW.is_online AND NOT public.rider_has_verified_bank_account(NEW.user_id) THEN
    IF TG_OP = 'INSERT' OR NOT OLD.is_online THEN
      RAISE EXCEPTION 'A verified bank account is required to go online';
    END IF;
    NEW.is_online := false;
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.protect_rider_details() FROM PUBLIC, anon, authenticated;

-- Nobody has a verified bank account yet, so nobody may stay online. Riders online
-- right now are set offline (which also deletes their location); they go online
-- again once an admin verifies their account.
UPDATE public.rider_details SET is_online = false WHERE is_online;
