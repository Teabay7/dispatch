-- Commission ledger (payment model step 3).
--
-- Riders keep the fare and owe the company a commission per counted trip (SPEC 10.3,
-- 10.9, 10.10). Commission accrues in an append-only ledger; trips are counted in
-- cycles of N; when a cycle is due the rider is offline until the amount owed is paid
-- by bank transfer and an admin records it. The company account riders pay into lives
-- in its own admin-only table, shown to riders through a function, and every change
-- to it is logged. See docs/commission-admin.md (including the hosted pre-push check).

-- ---------------------------------------------------------------------------
-- Settings: integer basis points instead of a numeric percent; cycle length
-- ---------------------------------------------------------------------------
ALTER TABLE public.app_settings
  DROP COLUMN commission_percent,
  ADD COLUMN commission_bps integer NOT NULL DEFAULT 1500
    CONSTRAINT app_settings_commission_bps_range CHECK (commission_bps BETWEEN 0 AND 10000),
  ADD COLUMN commission_trips_per_cycle integer NOT NULL DEFAULT 4
    CONSTRAINT app_settings_commission_trips_per_cycle_range CHECK (commission_trips_per_cycle BETWEEN 1 AND 50);

-- Half-up to the kobo: (price × bps + 5000) / 10000, in integers. For the quote step.
CREATE OR REPLACE FUNCTION public.commission_for_price(p_price_kobo bigint, p_bps integer)
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF p_price_kobo IS NULL OR p_price_kobo < 0 THEN
    RAISE EXCEPTION 'The price must be zero or more';
  END IF;
  IF p_bps IS NULL OR p_bps < 0 OR p_bps > 10000 THEN
    RAISE EXCEPTION 'The commission rate must be between 0 and 10000 basis points';
  END IF;
  RETURN (p_price_kobo * p_bps + 5000) / 10000;
END;
$$;

REVOKE ALL ON FUNCTION public.commission_for_price(bigint, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.commission_for_price(bigint, integer) TO service_role;

-- Shared by every append-only table.
CREATE OR REPLACE FUNCTION public.reject_ledger_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION '% is append-only: updates and deletes are not allowed', TG_TABLE_NAME;
END;
$$;

REVOKE ALL ON FUNCTION public.reject_ledger_mutation() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Company account riders pay commission into (one row, admin-only table)
-- ---------------------------------------------------------------------------
CREATE TABLE public.company_payment_account (
  id integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  bank_name text,
  account_number text CHECK (account_number IS NULL OR account_number ~ '^[0-9]{10}$'),
  account_name text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.company_payment_account (id) VALUES (1);

CREATE TABLE public.company_payment_account_changes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  changed_at timestamptz NOT NULL DEFAULT now(),
  changed_by text NOT NULL CHECK (btrim(changed_by) <> ''), -- free text: the SQL Editor has no user
  changed_by_user uuid REFERENCES public.profiles (id),    -- set when an admin uses the app
  field text NOT NULL CHECK (field IN ('bank_name', 'account_number', 'account_name')),
  old_value text,
  new_value text
);

CREATE INDEX company_payment_account_changes_changed_at_idx
  ON public.company_payment_account_changes (changed_at DESC);

CREATE TRIGGER company_payment_account_changes_no_update
  BEFORE UPDATE OR DELETE ON public.company_payment_account_changes
  FOR EACH ROW EXECUTE FUNCTION public.reject_ledger_mutation();
CREATE TRIGGER company_payment_account_changes_no_truncate
  BEFORE TRUNCATE ON public.company_payment_account_changes
  FOR EACH STATEMENT EXECUTE FUNCTION public.reject_ledger_mutation();

-- The account can only change through set_company_payment_account(), which logs it.
CREATE OR REPLACE FUNCTION public.company_payment_account_protect()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'The company payment account cannot be deleted';
  END IF;
  IF coalesce(current_setting('dispatch.company_account_change', true), '') <> 'on' THEN
    RAISE EXCEPTION 'Use set_company_payment_account() to change the company account';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.company_payment_account_protect() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER company_payment_account_protect
  BEFORE UPDATE OR DELETE ON public.company_payment_account
  FOR EACH ROW EXECUTE FUNCTION public.company_payment_account_protect();

ALTER TABLE public.company_payment_account ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.company_payment_account_changes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.company_payment_account, public.company_payment_account_changes FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
  ON public.company_payment_account, public.company_payment_account_changes FROM authenticated;

CREATE POLICY company_payment_account_select_admin
  ON public.company_payment_account FOR SELECT TO authenticated
  USING (public.is_admin());
CREATE POLICY company_payment_account_changes_select_admin
  ON public.company_payment_account_changes FOR SELECT TO authenticated
  USING (public.is_admin());

CREATE OR REPLACE FUNCTION public.set_company_payment_account(
  p_bank_name text,
  p_account_number text,
  p_account_name text,
  p_changed_by text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  cur public.company_payment_account%ROWTYPE;
  v_bank text := regexp_replace(btrim(coalesce(p_bank_name, '')), '\s+', ' ', 'g');
  v_number text := regexp_replace(coalesce(p_account_number, ''), '\s+', '', 'g');
  v_name text := regexp_replace(btrim(coalesce(p_account_name, '')), '\s+', ' ', 'g');
  v_by text := btrim(coalesce(p_changed_by, ''));
BEGIN
  IF NOT (COALESCE(auth.role(), 'service_role') = 'service_role' OR public.is_admin()) THEN
    RAISE EXCEPTION 'Only an admin can change the company account';
  END IF;
  IF v_bank = '' THEN
    RAISE EXCEPTION 'Enter the bank name';
  END IF;
  IF v_number !~ '^[0-9]{10}$' THEN
    RAISE EXCEPTION 'The account number must be exactly 10 digits';
  END IF;
  IF v_name = '' THEN
    RAISE EXCEPTION 'Enter the account name';
  END IF;
  IF v_by = '' THEN
    RAISE EXCEPTION 'Enter who is making this change';
  END IF;

  SELECT * INTO cur FROM public.company_payment_account WHERE id = 1 FOR UPDATE;

  INSERT INTO public.company_payment_account_changes (changed_by, changed_by_user, field, old_value, new_value)
  SELECT v_by, auth.uid(), f.field, f.old_value, f.new_value
    FROM (VALUES ('bank_name', cur.bank_name, v_bank),
                 ('account_number', cur.account_number, v_number),
                 ('account_name', cur.account_name, v_name)) AS f(field, old_value, new_value)
   WHERE f.old_value IS DISTINCT FROM f.new_value;

  PERFORM set_config('dispatch.company_account_change', 'on', true);
  UPDATE public.company_payment_account
     SET bank_name = v_bank, account_number = v_number, account_name = v_name
   WHERE id = 1;
  PERFORM set_config('dispatch.company_account_change', '', true);
END;
$$;

-- What riders see: only riders (any status: a suspended rider may still owe) and admins.
CREATE OR REPLACE FUNCTION public.get_company_payment_account()
RETURNS TABLE (bank_name text, account_number text, account_name text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sign in to see the company account';
  END IF;
  IF NOT (public.is_admin() OR EXISTS (
    SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'rider'
  )) THEN
    RAISE EXCEPTION 'Only riders can see the company account';
  END IF;
  RETURN QUERY
    SELECT c.bank_name, c.account_number, c.account_name
      FROM public.company_payment_account c WHERE c.id = 1;
END;
$$;

REVOKE ALL ON FUNCTION public.set_company_payment_account(text, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_company_payment_account() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_company_payment_account(text, text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_company_payment_account() TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Cycles and the ledger
-- ---------------------------------------------------------------------------
CREATE TYPE public.commission_cycle_status AS ENUM ('open', 'due', 'paid');
CREATE TYPE public.commission_entry_type AS ENUM ('commission', 'payment', 'reversal');

CREATE TABLE public.commission_cycles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rider_id uuid NOT NULL REFERENCES public.rider_details (user_id),
  cycle_no integer NOT NULL CHECK (cycle_no > 0),
  -- Copied from app_settings when the cycle opens, so a settings change does not move it.
  trips_required integer NOT NULL CHECK (trips_required BETWEEN 1 AND 50),
  trip_count integer NOT NULL DEFAULT 0,
  status public.commission_cycle_status NOT NULL DEFAULT 'open',
  -- The rider writes this in the transfer narration.
  reference_code text NOT NULL,
  opened_at timestamptz NOT NULL DEFAULT now(),
  due_at timestamptz,
  paid_at timestamptz,
  CONSTRAINT commission_cycles_rider_cycle_no UNIQUE (rider_id, cycle_no),
  CONSTRAINT commission_cycles_reference_code_unique UNIQUE (reference_code),
  CONSTRAINT commission_cycles_trip_count CHECK (trip_count BETWEEN 0 AND trips_required),
  CONSTRAINT commission_cycles_due_fields CHECK (
    (status = 'open' AND due_at IS NULL AND paid_at IS NULL)
    OR (status = 'due' AND due_at IS NOT NULL AND paid_at IS NULL AND trip_count = trips_required)
    OR (status = 'paid' AND due_at IS NOT NULL AND paid_at IS NOT NULL AND trip_count = trips_required)
  )
);

CREATE UNIQUE INDEX commission_cycles_one_open ON public.commission_cycles (rider_id) WHERE status = 'open';
CREATE UNIQUE INDEX commission_cycles_one_due ON public.commission_cycles (rider_id) WHERE status = 'due';
CREATE INDEX commission_cycles_due_idx ON public.commission_cycles (due_at) WHERE status = 'due';

CREATE TABLE public.commission_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rider_id uuid NOT NULL REFERENCES public.rider_details (user_id),
  -- Per-rider sequence: the order of entries (created_at is the same within a transaction).
  entry_no bigint NOT NULL,
  cycle_id uuid NOT NULL REFERENCES public.commission_cycles (id),
  type public.commission_entry_type NOT NULL,
  -- Positive = the rider owes more; negative = paid or credited.
  amount_kobo bigint NOT NULL,
  order_id uuid REFERENCES public.orders (id),
  bank_reference text,
  paid_at timestamptz,
  reverses_entry_id uuid REFERENCES public.commission_entries (id),
  recorded_by text,
  note text,
  balance_after_kobo bigint NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT commission_entries_rider_entry_no UNIQUE (rider_id, entry_no),
  CONSTRAINT commission_entries_reverses_once UNIQUE (reverses_entry_id),
  CONSTRAINT commission_entries_shape CHECK (
    (type = 'commission' AND amount_kobo >= 0 AND order_id IS NOT NULL
       AND bank_reference IS NULL AND reverses_entry_id IS NULL)
    OR (type = 'payment' AND amount_kobo < 0 AND order_id IS NULL AND reverses_entry_id IS NULL
       AND bank_reference IS NOT NULL AND btrim(bank_reference) <> '' AND paid_at IS NOT NULL
       AND btrim(coalesce(recorded_by, '')) <> '' AND btrim(coalesce(note, '')) <> '')
    OR (type = 'reversal' AND amount_kobo <> 0 AND reverses_entry_id IS NOT NULL
       AND order_id IS NULL AND bank_reference IS NULL
       AND btrim(coalesce(recorded_by, '')) <> '' AND btrim(coalesce(note, '')) <> '')
  )
);

-- One charge per order, ever (a reversed charge is not charged again).
CREATE UNIQUE INDEX commission_entries_one_charge_per_order
  ON public.commission_entries (order_id) WHERE type = 'commission';
CREATE INDEX commission_entries_bank_reference_idx
  ON public.commission_entries (lower(btrim(bank_reference))) WHERE type = 'payment';
CREATE INDEX commission_entries_rider_idx ON public.commission_entries (rider_id, entry_no DESC);
CREATE INDEX commission_entries_cycle_idx ON public.commission_entries (cycle_id);

-- Append-only, for everyone (the server and the database owner included).
CREATE TRIGGER commission_entries_no_update
  BEFORE UPDATE OR DELETE ON public.commission_entries
  FOR EACH ROW EXECUTE FUNCTION public.reject_ledger_mutation();
CREATE TRIGGER commission_entries_no_truncate
  BEFORE TRUNCATE ON public.commission_entries
  FOR EACH STATEMENT EXECUTE FUNCTION public.reject_ledger_mutation();

-- Cycles: never deleted; identity fixed; counts only go up; status moves
-- open → due → paid, and paid → due only when a payment is reversed.
CREATE OR REPLACE FUNCTION public.commission_cycles_protect()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Commission cycles cannot be deleted';
  END IF;
  IF (NEW.id, NEW.rider_id, NEW.cycle_no, NEW.trips_required, NEW.reference_code, NEW.opened_at)
     IS DISTINCT FROM
     (OLD.id, OLD.rider_id, OLD.cycle_no, OLD.trips_required, OLD.reference_code, OLD.opened_at) THEN
    RAISE EXCEPTION 'A commission cycle''s identity cannot be changed';
  END IF;
  IF NEW.trip_count < OLD.trip_count THEN
    RAISE EXCEPTION 'A cycle''s trip count cannot go down';
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
       (OLD.status = 'open' AND NEW.status = 'due')
    OR (OLD.status = 'due' AND NEW.status = 'paid')
    OR (OLD.status = 'paid' AND NEW.status = 'due')
  ) THEN
    RAISE EXCEPTION 'This commission cycle status change is not allowed';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.commission_cycles_protect() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER commission_cycles_protect
  BEFORE UPDATE OR DELETE ON public.commission_cycles
  FOR EACH ROW EXECUTE FUNCTION public.commission_cycles_protect();
CREATE TRIGGER commission_cycles_no_truncate
  BEFORE TRUNCATE ON public.commission_cycles
  FOR EACH STATEMENT EXECUTE FUNCTION public.reject_ledger_mutation();

-- Row Level Security: riders read their own rows, admins read all, nobody writes.
ALTER TABLE public.commission_cycles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.commission_entries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.commission_cycles, public.commission_entries FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.commission_cycles, public.commission_entries FROM authenticated;

CREATE POLICY commission_cycles_select_own_or_admin
  ON public.commission_cycles FOR SELECT TO authenticated
  USING (rider_id = (SELECT auth.uid()) OR public.is_admin());
CREATE POLICY commission_entries_select_own_or_admin
  ON public.commission_entries FOR SELECT TO authenticated
  USING (rider_id = (SELECT auth.uid()) OR public.is_admin());

-- ---------------------------------------------------------------------------
-- Internal helpers (SECURITY DEFINER; not callable by API roles)
-- ---------------------------------------------------------------------------

-- Amount owed now (positive) or credit (negative): the latest balance_after.
CREATE OR REPLACE FUNCTION public.rider_commission_balance(p_rider_id uuid)
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT coalesce(
    (SELECT balance_after_kobo FROM public.commission_entries
      WHERE rider_id = p_rider_id ORDER BY entry_no DESC LIMIT 1),
    0);
$$;

CREATE OR REPLACE FUNCTION public.rider_has_commission_due(p_rider_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (SELECT 1 FROM public.commission_cycles WHERE rider_id = p_rider_id AND status = 'due');
$$;

-- Serialises all ledger writes for one rider.
CREATE OR REPLACE FUNCTION public.lock_rider_commission(p_rider_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('commission:' || p_rider_id::text, 0));
$$;

-- Appends an entry with the next entry_no and the running balance. Caller holds the rider lock.
CREATE OR REPLACE FUNCTION public.append_commission_entry(
  p_rider_id uuid,
  p_cycle_id uuid,
  p_type public.commission_entry_type,
  p_amount_kobo bigint,
  p_order_id uuid DEFAULT NULL,
  p_bank_reference text DEFAULT NULL,
  p_paid_at timestamptz DEFAULT NULL,
  p_reverses_entry_id uuid DEFAULT NULL,
  p_recorded_by text DEFAULT NULL,
  p_note text DEFAULT NULL
)
RETURNS public.commission_entries
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  last_no bigint;
  last_balance bigint;
  result public.commission_entries;
BEGIN
  SELECT entry_no, balance_after_kobo INTO last_no, last_balance
    FROM public.commission_entries WHERE rider_id = p_rider_id
   ORDER BY entry_no DESC LIMIT 1;

  INSERT INTO public.commission_entries
    (rider_id, entry_no, cycle_id, type, amount_kobo, order_id, bank_reference, paid_at,
     reverses_entry_id, recorded_by, note, balance_after_kobo)
  VALUES
    (p_rider_id, coalesce(last_no, 0) + 1, p_cycle_id, p_type, p_amount_kobo, p_order_id,
     NULLIF(btrim(p_bank_reference), ''), p_paid_at, p_reverses_entry_id,
     NULLIF(btrim(p_recorded_by), ''), NULLIF(btrim(p_note), ''),
     coalesce(last_balance, 0) + p_amount_kobo)
  RETURNING * INTO result;
  RETURN result;
END;
$$;

-- A reference code that no other cycle uses: DSP-<8 hex of rider id>-C<cycle>, with a
-- longer prefix (12, 16, then all 32 characters) if that is taken. The full id plus the
-- cycle number is unique, so a rider can always open a cycle.
CREATE OR REPLACE FUNCTION public.commission_reference_code(p_rider_id uuid, p_cycle_no integer)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  hex text := upper(replace(p_rider_id::text, '-', ''));
  len integer;
  code text;
BEGIN
  -- Serialise code allocation across riders.
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('commission_reference_code', 0));
  FOREACH len IN ARRAY ARRAY[8, 12, 16, 32] LOOP
    code := 'DSP-' || left(hex, len) || '-C' || lpad(p_cycle_no::text, 3, '0');
    IF NOT EXISTS (SELECT 1 FROM public.commission_cycles WHERE reference_code = code) THEN
      RETURN code;
    END IF;
  END LOOP;
  RAISE EXCEPTION 'Could not allocate a commission reference code';
END;
$$;

-- Takes the rider offline (the existing trigger then deletes their location).
CREATE OR REPLACE FUNCTION public.take_rider_offline_for_commission(p_rider_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  UPDATE public.rider_details SET is_online = false WHERE user_id = p_rider_id AND is_online;
$$;

-- When nothing is owed, every due cycle is paid.
CREATE OR REPLACE FUNCTION public.settle_commission_cycles(p_rider_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF public.rider_commission_balance(p_rider_id) <= 0 THEN
    UPDATE public.commission_cycles
       SET status = 'paid', paid_at = now()
     WHERE rider_id = p_rider_id AND status = 'due';
  END IF;
END;
$$;

-- Which order endings count as a trip (SPEC 10.9). Reviewed against order_status by a
-- pgTAP test: if the enum changes, that test fails until this is checked.
CREATE OR REPLACE FUNCTION public.order_counts_as_trip(
  p_status public.order_status,
  p_payment_status public.payment_status
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT p_status IN ('delivered', 'completed')
      OR (p_status IN ('cancelled_by_customer', 'cancelled_by_rider', 'no_rider_found', 'payment_failed')
          AND p_payment_status = 'paid');
$$;

REVOKE ALL ON FUNCTION public.rider_commission_balance(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rider_has_commission_due(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lock_rider_commission(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.append_commission_entry(uuid, uuid, public.commission_entry_type, bigint, uuid, text, timestamptz, uuid, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.commission_reference_code(uuid, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.take_rider_offline_for_commission(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.settle_commission_cycles(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.order_counts_as_trip(public.order_status, public.payment_status) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The delivered-trip step. Called by the trigger below whenever an order ends in a
-- way that counts; the order flow may also call it (service_role). Idempotent:
-- returns true if it charged the order now, false if it was already charged.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.accrue_trip_commission(p_order_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  o public.orders%ROWTYPE;
  cyc public.commission_cycles%ROWTYPE;
  next_no integer;
  trips integer;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order not found';
  END IF;
  IF o.rider_id IS NULL OR NOT public.order_counts_as_trip(o.status, o.payment_status) THEN
    RAISE EXCEPTION 'This order does not count as a trip';
  END IF;

  PERFORM public.lock_rider_commission(o.rider_id);

  IF EXISTS (SELECT 1 FROM public.commission_entries
              WHERE order_id = o.id AND type = 'commission') THEN
    RETURN false;
  END IF;

  SELECT * INTO cyc FROM public.commission_cycles
   WHERE rider_id = o.rider_id AND status = 'open' FOR UPDATE;
  IF NOT FOUND THEN
    SELECT coalesce(max(cycle_no), 0) + 1 INTO next_no
      FROM public.commission_cycles WHERE rider_id = o.rider_id;
    SELECT commission_trips_per_cycle INTO trips FROM public.app_settings WHERE id = 1;
    INSERT INTO public.commission_cycles (rider_id, cycle_no, trips_required, reference_code)
    VALUES (o.rider_id, next_no, trips, public.commission_reference_code(o.rider_id, next_no))
    RETURNING * INTO cyc;
  END IF;

  PERFORM public.append_commission_entry(o.rider_id, cyc.id, 'commission', o.commission_kobo, o.id);

  UPDATE public.commission_cycles
     SET trip_count = trip_count + 1,
         status = CASE WHEN trip_count + 1 >= trips_required THEN 'due'::public.commission_cycle_status ELSE status END,
         due_at = CASE WHEN trip_count + 1 >= trips_required THEN now() ELSE due_at END
   WHERE id = cyc.id
  RETURNING * INTO cyc;

  IF cyc.status = 'due' THEN
    -- Credit may already cover it; otherwise the rider is offline until they pay.
    PERFORM public.settle_commission_cycles(o.rider_id);
    IF public.rider_has_commission_due(o.rider_id) THEN
      PERFORM public.take_rider_offline_for_commission(o.rider_id);
    END IF;
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.accrue_trip_commission(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.accrue_trip_commission(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.orders_accrue_commission()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.rider_id IS NOT NULL AND public.order_counts_as_trip(NEW.status, NEW.payment_status) THEN
    PERFORM public.accrue_trip_commission(NEW.id);
  END IF;
  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.orders_accrue_commission() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER orders_accrue_commission
  AFTER UPDATE OF status, payment_status ON public.orders
  FOR EACH ROW
  WHEN (NEW.status IS DISTINCT FROM OLD.status OR NEW.payment_status IS DISTINCT FROM OLD.payment_status)
  EXECUTE FUNCTION public.orders_accrue_commission();

-- ---------------------------------------------------------------------------
-- Admin: record a payment, reverse an entry (admin in the app, the server, or the
-- SQL Editor, where there is no JWT and the caller is trusted).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_commission_payment(
  p_reference_code text,
  p_amount_kobo bigint,
  p_bank_reference text,
  p_paid_at timestamptz,
  p_recorded_by text,
  p_note text
)
RETURNS bigint -- the rider's balance afterwards (negative = credit)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  cyc public.commission_cycles%ROWTYPE;
  v_ref text := btrim(coalesce(p_bank_reference, ''));
BEGIN
  IF NOT (COALESCE(auth.role(), 'service_role') = 'service_role' OR public.is_admin()) THEN
    RAISE EXCEPTION 'Only an admin can record commission payments';
  END IF;
  IF p_amount_kobo IS NULL OR p_amount_kobo <= 0 THEN
    RAISE EXCEPTION 'The amount must be more than zero (in kobo)';
  END IF;
  IF v_ref = '' THEN
    RAISE EXCEPTION 'Enter the bank transaction reference';
  END IF;
  IF p_paid_at IS NULL THEN
    RAISE EXCEPTION 'Enter when the transfer was made';
  END IF;
  IF btrim(coalesce(p_recorded_by, '')) = '' THEN
    RAISE EXCEPTION 'Enter who is recording this';
  END IF;
  IF btrim(coalesce(p_note, '')) = '' THEN
    RAISE EXCEPTION 'Enter a note';
  END IF;

  SELECT * INTO cyc FROM public.commission_cycles
   WHERE reference_code = upper(btrim(coalesce(p_reference_code, '')));
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown commission reference code';
  END IF;

  PERFORM public.lock_rider_commission(cyc.rider_id);
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('commission_bank_ref:' || lower(v_ref), 0));

  -- The same transfer never counts twice (a reversed recording does not count).
  IF EXISTS (
    SELECT 1 FROM public.commission_entries p
     WHERE p.type = 'payment' AND lower(btrim(p.bank_reference)) = lower(v_ref)
       AND NOT EXISTS (SELECT 1 FROM public.commission_entries r WHERE r.reverses_entry_id = p.id)
  ) THEN
    RAISE EXCEPTION 'This bank transfer is already recorded';
  END IF;

  PERFORM public.append_commission_entry(
    cyc.rider_id, cyc.id, 'payment', -p_amount_kobo,
    p_bank_reference => v_ref, p_paid_at => p_paid_at,
    p_recorded_by => p_recorded_by, p_note => p_note);

  PERFORM public.settle_commission_cycles(cyc.rider_id);
  RETURN public.rider_commission_balance(cyc.rider_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.reverse_commission_entry(
  p_entry_id uuid,
  p_reason text,
  p_recorded_by text
)
RETURNS bigint -- the rider's balance afterwards
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  e public.commission_entries%ROWTYPE;
  cyc public.commission_cycles%ROWTYPE;
BEGIN
  IF NOT (COALESCE(auth.role(), 'service_role') = 'service_role' OR public.is_admin()) THEN
    RAISE EXCEPTION 'Only an admin can reverse commission entries';
  END IF;
  IF btrim(coalesce(p_reason, '')) = '' THEN
    RAISE EXCEPTION 'A reversal needs a reason';
  END IF;
  IF btrim(coalesce(p_recorded_by, '')) = '' THEN
    RAISE EXCEPTION 'Enter who is recording this';
  END IF;

  SELECT * INTO e FROM public.commission_entries WHERE id = p_entry_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Commission entry not found';
  END IF;

  PERFORM public.lock_rider_commission(e.rider_id);

  IF e.type = 'reversal' THEN
    RAISE EXCEPTION 'A reversal cannot be reversed';
  END IF;
  IF EXISTS (SELECT 1 FROM public.commission_entries WHERE reverses_entry_id = e.id) THEN
    RAISE EXCEPTION 'This entry is already reversed';
  END IF;
  IF e.amount_kobo = 0 THEN
    RAISE EXCEPTION 'Nothing to reverse: the amount is zero';
  END IF;

  PERFORM public.append_commission_entry(
    e.rider_id, e.cycle_id, 'reversal', -e.amount_kobo,
    p_reverses_entry_id => e.id, p_recorded_by => p_recorded_by, p_note => p_reason);

  -- A reversed payment that had settled its cycle makes it due again.
  IF e.type = 'payment' AND public.rider_commission_balance(e.rider_id) > 0 THEN
    SELECT * INTO cyc FROM public.commission_cycles WHERE id = e.cycle_id FOR UPDATE;
    IF cyc.status = 'paid' AND NOT public.rider_has_commission_due(e.rider_id) THEN
      UPDATE public.commission_cycles SET status = 'due', paid_at = NULL WHERE id = cyc.id;
    END IF;
    IF public.rider_has_commission_due(e.rider_id) THEN
      PERFORM public.take_rider_offline_for_commission(e.rider_id);
    END IF;
  END IF;

  PERFORM public.settle_commission_cycles(e.rider_id);
  RETURN public.rider_commission_balance(e.rider_id);
END;
$$;

REVOKE ALL ON FUNCTION public.record_commission_payment(text, bigint, text, timestamptz, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.reverse_commission_entry(uuid, text, text) FROM PUBLIC, anon;
-- Signed-in users can call them, but only admins get past the check inside.
GRANT EXECUTE ON FUNCTION public.record_commission_payment(text, bigint, text, timestamptz, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reverse_commission_entry(uuid, text, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- protect_rider_details: as in 20261124100000_rider_bank_account.sql, plus no
-- going online while a commission cycle is due.
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

  -- ...and no commission due (SPEC 10.9).
  IF NEW.is_online AND public.rider_has_commission_due(NEW.user_id) THEN
    IF TG_OP = 'INSERT' OR NOT OLD.is_online THEN
      RAISE EXCEPTION 'Commission is due: pay it to go online';
    END IF;
    NEW.is_online := false;
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.protect_rider_details() FROM PUBLIC, anon, authenticated;
