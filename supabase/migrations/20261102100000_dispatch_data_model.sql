-- Dispatch MVP data model
-- Money: integer kobo (bigint) only. Wallet: append-only ledger.
-- Apply manually; this file is not run by the agent.
--
-- IMPORTANT: app_settings is seeded with placeholder zeros for base_fee_kobo,
-- per_km_rate_kobo, commission_percent, and min_withdrawal_kobo. These MUST be
-- set to real pilot values before launch.

-- ---------------------------------------------------------------------------
-- Extensions
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
CREATE TYPE public.app_role AS ENUM ('customer', 'rider', 'admin');

CREATE TYPE public.role_status AS ENUM ('active', 'suspended');

CREATE TYPE public.kyc_status AS ENUM ('pending', 'approved', 'rejected');

CREATE TYPE public.vehicle_type AS ENUM ('bike');

CREATE TYPE public.order_status AS ENUM (
  'created',
  'rider_requested',
  'accepted',
  'picked_up',
  'delivered',
  'completed',
  'cancelled_by_customer',
  'cancelled_by_rider',
  'no_rider_found',
  'payment_failed'
);

-- Payment at point of delivery (POD): starts unpaid until provider confirms.
CREATE TYPE public.payment_status AS ENUM (
  'unpaid',
  'awaiting_payment',
  'paid',
  'failed'
);

CREATE TYPE public.payment_record_status AS ENUM ('pending', 'success', 'failed');

CREATE TYPE public.wallet_entry_type AS ENUM ('credit', 'withdrawal', 'adjustment');

CREATE TYPE public.withdrawal_status AS ENUM (
  'pending',
  'processing',
  'success',
  'failed',
  'cancelled'
);

-- ---------------------------------------------------------------------------
-- profiles (1:1 with auth.users)
-- ---------------------------------------------------------------------------
CREATE TABLE public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  phone text UNIQUE,
  full_name text,
  -- Non-payment / abandon tracking (SPEC 10.5); server/admin writes only
  has_unsettled_unpaid_order boolean NOT NULL DEFAULT false,
  unpaid_abandon_count integer NOT NULL DEFAULT 0
    CHECK (unpaid_abandon_count >= 0),
  flagged_for_admin_review boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX profiles_flagged_for_admin_review_idx
  ON public.profiles (flagged_for_admin_review)
  WHERE flagged_for_admin_review = true;

-- Auto-create profile on signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, phone, full_name)
  VALUES (
    NEW.id,
    NEW.phone,
    COALESCE(NEW.raw_user_meta_data ->> 'full_name', NULL)
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();

-- ---------------------------------------------------------------------------
-- user_roles (per-role suspension)
-- ---------------------------------------------------------------------------
CREATE TABLE public.user_roles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  role public.app_role NOT NULL,
  status public.role_status NOT NULL DEFAULT 'active',
  suspended_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, role),
  CONSTRAINT suspended_reason_when_suspended CHECK (
    (status = 'suspended' AND suspended_reason IS NOT NULL)
    OR (status = 'active' AND suspended_reason IS NULL)
  )
);

CREATE INDEX user_roles_user_id_idx ON public.user_roles (user_id);

-- Role helpers: SECURITY DEFINER avoids infinite RLS recursion on user_roles
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles
    WHERE user_id = auth.uid()
      AND role = 'admin'
      AND status = 'active'
  );
$$;

CREATE OR REPLACE FUNCTION public.has_active_role(r public.app_role)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles
    WHERE user_id = auth.uid()
      AND role = r
      AND status = 'active'
  );
$$;

-- Block clients from changing risk-flag columns (service_role / admin may)
CREATE OR REPLACE FUNCTION public.protect_profile_columns()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
BEGIN
  IF COALESCE(auth.role(), 'service_role') = 'service_role' OR public.is_admin() THEN
    RETURN NEW;
  END IF;

  IF NEW.has_unsettled_unpaid_order IS DISTINCT FROM OLD.has_unsettled_unpaid_order
     OR NEW.unpaid_abandon_count IS DISTINCT FROM OLD.unpaid_abandon_count
     OR NEW.flagged_for_admin_review IS DISTINCT FROM OLD.flagged_for_admin_review
     OR NEW.phone IS DISTINCT FROM OLD.phone
     OR NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'Cannot change protected profile fields';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER profiles_protect_columns
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_profile_columns();

-- Users cannot change their own role, status, or suspended_reason
CREATE OR REPLACE FUNCTION public.protect_user_roles()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF COALESCE(auth.role(), 'service_role') = 'service_role' OR public.is_admin() THEN
      RETURN NEW;
    END IF;
    -- Authenticated users may only add customer/rider for themselves, active
    IF NEW.user_id <> auth.uid()
       OR NEW.role = 'admin'
       OR NEW.status <> 'active'
       OR NEW.suspended_reason IS NOT NULL THEN
      RAISE EXCEPTION 'Cannot assign this role or status';
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE
  IF COALESCE(auth.role(), 'service_role') = 'service_role' OR public.is_admin() THEN
    NEW.updated_at := now();
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'Cannot change role or role status';
END;
$$;

CREATE TRIGGER user_roles_protect
  BEFORE INSERT OR UPDATE ON public.user_roles
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_user_roles();

-- ---------------------------------------------------------------------------
-- rider_details
-- ---------------------------------------------------------------------------
CREATE TABLE public.rider_details (
  user_id uuid PRIMARY KEY REFERENCES public.profiles (id) ON DELETE CASCADE,
  vehicle_type public.vehicle_type NOT NULL DEFAULT 'bike',
  plate_number text NOT NULL,
  kyc_status public.kyc_status NOT NULL DEFAULT 'pending',
  id_photo_path text,
  selfie_path text,
  bank_account_ref text,
  is_online boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX rider_details_online_approved_idx
  ON public.rider_details (is_online)
  WHERE is_online = true AND kyc_status = 'approved';

-- Riders cannot change their own KYC status; cannot go online unless approved
CREATE OR REPLACE FUNCTION public.protect_rider_details()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
BEGIN
  IF NEW.is_online = true AND NEW.kyc_status <> 'approved' THEN
    RAISE EXCEPTION 'Rider must be KYC approved to go online';
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF COALESCE(auth.role(), 'service_role') = 'service_role' OR public.is_admin() THEN
      RETURN NEW;
    END IF;
    IF NEW.user_id <> auth.uid() OR NEW.kyc_status <> 'pending' THEN
      RAISE EXCEPTION 'Invalid rider_details insert';
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE
  IF COALESCE(auth.role(), 'service_role') = 'service_role' OR public.is_admin() THEN
    NEW.updated_at := now();
    RETURN NEW;
  END IF;

  IF NEW.user_id <> OLD.user_id
     OR NEW.kyc_status IS DISTINCT FROM OLD.kyc_status THEN
    RAISE EXCEPTION 'Cannot change KYC status or rider identity';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER rider_details_protect
  BEFORE INSERT OR UPDATE ON public.rider_details
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_rider_details();

-- ---------------------------------------------------------------------------
-- rider_locations
-- ---------------------------------------------------------------------------
CREATE TABLE public.rider_locations (
  rider_id uuid PRIMARY KEY REFERENCES public.rider_details (user_id) ON DELETE CASCADE,
  lat double precision NOT NULL
    CHECK (lat >= -90 AND lat <= 90),
  lng double precision NOT NULL
    CHECK (lng >= -180 AND lng <= 180),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public.touch_rider_location()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER rider_locations_touch
  BEFORE UPDATE ON public.rider_locations
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_rider_location();

-- ---------------------------------------------------------------------------
-- orders
-- ---------------------------------------------------------------------------
CREATE TABLE public.orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid NOT NULL REFERENCES public.profiles (id),
  rider_id uuid REFERENCES public.profiles (id),
  pickup_address text NOT NULL,
  pickup_lat double precision NOT NULL,
  pickup_lng double precision NOT NULL,
  pickup_postcode text,
  dropoff_address text NOT NULL,
  dropoff_lat double precision NOT NULL,
  dropoff_lng double precision NOT NULL,
  dropoff_postcode text,
  price_kobo bigint NOT NULL CHECK (price_kobo >= 0),
  commission_kobo bigint NOT NULL CHECK (commission_kobo >= 0),
  status public.order_status NOT NULL DEFAULT 'created',
  payment_status public.payment_status NOT NULL DEFAULT 'unpaid',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT commission_not_gt_price CHECK (commission_kobo <= price_kobo)
);

CREATE INDEX orders_customer_id_idx ON public.orders (customer_id);
CREATE INDEX orders_rider_id_idx ON public.orders (rider_id);
CREATE INDEX orders_status_idx ON public.orders (status);
CREATE INDEX orders_payment_status_idx ON public.orders (payment_status);

-- Money, payment_status, rider_id, status: service_role only
-- Exception: customer may cancel while created / rider_requested
CREATE OR REPLACE FUNCTION public.protect_order_fields()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
BEGIN
  IF COALESCE(auth.role(), 'service_role') = 'service_role' THEN
    NEW.updated_at := now();
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.price_kobo <> 0 OR NEW.commission_kobo <> 0 THEN
      RAISE EXCEPTION 'price_kobo and commission_kobo must be set server-side';
    END IF;
    IF NEW.payment_status <> 'unpaid' THEN
      RAISE EXCEPTION 'payment_status must start as unpaid';
    END IF;
    IF NEW.customer_id <> auth.uid() THEN
      RAISE EXCEPTION 'Cannot create order for another user';
    END IF;
    IF NEW.rider_id IS NOT NULL THEN
      RAISE EXCEPTION 'Clients cannot assign rider_id';
    END IF;
    IF NEW.status <> 'created' THEN
      RAISE EXCEPTION 'Clients can only create orders with status created';
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE: clients may not change money or payment fields
  IF NEW.price_kobo IS DISTINCT FROM OLD.price_kobo
     OR NEW.commission_kobo IS DISTINCT FROM OLD.commission_kobo
     OR NEW.payment_status IS DISTINCT FROM OLD.payment_status
     OR NEW.customer_id IS DISTINCT FROM OLD.customer_id THEN
    RAISE EXCEPTION 'Cannot change order money or payment fields';
  END IF;

  -- Clients cannot change rider_id
  IF NEW.rider_id IS DISTINCT FROM OLD.rider_id THEN
    RAISE EXCEPTION 'Clients cannot change rider_id';
  END IF;

  -- Clients cannot change status, except customer cancel early
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NEW.customer_id = auth.uid()
       AND NEW.status = 'cancelled_by_customer'
       AND OLD.status IN ('created', 'rider_requested') THEN
      NULL; -- allowed
    ELSE
      RAISE EXCEPTION 'Clients cannot change order status';
    END IF;
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER orders_protect_fields
  BEFORE INSERT OR UPDATE ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_order_fields();

-- ---------------------------------------------------------------------------
-- order_events (status change log; written only by trigger / service_role)
-- ---------------------------------------------------------------------------
CREATE TABLE public.order_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders (id) ON DELETE CASCADE,
  status public.order_status NOT NULL,
  actor_id uuid REFERENCES public.profiles (id),
  note text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX order_events_order_id_idx ON public.order_events (order_id);

CREATE OR REPLACE FUNCTION public.log_order_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.order_events (order_id, status, actor_id)
    VALUES (NEW.id, NEW.status, auth.uid());
    RETURN NEW;
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO public.order_events (order_id, status, actor_id)
    VALUES (NEW.id, NEW.status, auth.uid());
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER orders_log_events
  AFTER INSERT OR UPDATE OF status ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.log_order_event();

-- ---------------------------------------------------------------------------
-- payments (Paystack VA / webhook; client read-only)
-- ---------------------------------------------------------------------------
CREATE TABLE public.payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders (id),
  provider_ref text,
  virtual_account text,
  amount_kobo bigint NOT NULL CHECK (amount_kobo > 0),
  status public.payment_record_status NOT NULL DEFAULT 'pending',
  raw_webhook_id text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT payments_provider_ref_unique UNIQUE (provider_ref),
  CONSTRAINT payments_raw_webhook_id_unique UNIQUE (raw_webhook_id)
);

CREATE INDEX payments_order_id_idx ON public.payments (order_id);

-- ---------------------------------------------------------------------------
-- wallet_entries (append-only ledger; never update or delete)
-- ---------------------------------------------------------------------------
CREATE TABLE public.wallet_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rider_id uuid NOT NULL REFERENCES public.profiles (id),
  type public.wallet_entry_type NOT NULL,
  amount_kobo bigint NOT NULL,
  order_id uuid REFERENCES public.orders (id),
  balance_after_kobo bigint NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT wallet_entries_amount_nonzero CHECK (amount_kobo <> 0)
);

CREATE INDEX wallet_entries_rider_id_created_at_idx
  ON public.wallet_entries (rider_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.reject_wallet_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
BEGIN
  RAISE EXCEPTION 'wallet_entries is append-only: updates and deletes are not allowed';
END;
$$;

CREATE TRIGGER wallet_entries_no_update
  BEFORE UPDATE ON public.wallet_entries
  FOR EACH ROW
  EXECUTE FUNCTION public.reject_wallet_mutation();

CREATE TRIGGER wallet_entries_no_delete
  BEFORE DELETE ON public.wallet_entries
  FOR EACH ROW
  EXECUTE FUNCTION public.reject_wallet_mutation();

-- ---------------------------------------------------------------------------
-- withdrawals (client read-only)
-- ---------------------------------------------------------------------------
CREATE TABLE public.withdrawals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rider_id uuid NOT NULL REFERENCES public.profiles (id),
  amount_kobo bigint NOT NULL CHECK (amount_kobo > 0),
  status public.withdrawal_status NOT NULL DEFAULT 'pending',
  provider_ref text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT withdrawals_provider_ref_unique UNIQUE (provider_ref)
);

CREATE INDEX withdrawals_rider_id_idx ON public.withdrawals (rider_id);

-- ---------------------------------------------------------------------------
-- ratings
-- ---------------------------------------------------------------------------
CREATE TABLE public.ratings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders (id) ON DELETE CASCADE,
  from_id uuid NOT NULL REFERENCES public.profiles (id),
  to_id uuid NOT NULL REFERENCES public.profiles (id),
  score integer NOT NULL CHECK (score >= 1 AND score <= 5),
  comment text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (order_id, from_id),
  CONSTRAINT ratings_not_self CHECK (from_id <> to_id)
);

CREATE INDEX ratings_to_id_idx ON public.ratings (to_id);

-- ---------------------------------------------------------------------------
-- app_settings (single row; admin / service_role write)
-- ---------------------------------------------------------------------------
CREATE TABLE public.app_settings (
  id integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  base_fee_kobo bigint NOT NULL CHECK (base_fee_kobo >= 0),
  per_km_rate_kobo bigint NOT NULL CHECK (per_km_rate_kobo >= 0),
  -- Not money; numeric percent is intentional (e.g. 15.00 = 15%)
  commission_percent numeric(5, 2) NOT NULL
    CHECK (commission_percent >= 0 AND commission_percent <= 100),
  min_withdrawal_kobo bigint NOT NULL CHECK (min_withdrawal_kobo >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Placeholder pilot values — MUST be replaced before launch
INSERT INTO public.app_settings (
  id,
  base_fee_kobo,
  per_km_rate_kobo,
  commission_percent,
  min_withdrawal_kobo
) VALUES (
  1,
  0,
  0,
  0,
  0
);

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rider_details ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rider_locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.withdrawals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ratings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.app_settings ENABLE ROW LEVEL SECURITY;

-- profiles
CREATE POLICY profiles_select_own_or_admin
  ON public.profiles FOR SELECT TO authenticated
  USING (id = auth.uid() OR public.is_admin());

CREATE POLICY profiles_update_own
  ON public.profiles FOR UPDATE TO authenticated
  USING (id = auth.uid() OR public.is_admin())
  WITH CHECK (id = auth.uid() OR public.is_admin());

-- user_roles
CREATE POLICY user_roles_select_own_or_admin
  ON public.user_roles FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.is_admin());

CREATE POLICY user_roles_insert_self_or_admin
  ON public.user_roles FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid() OR public.is_admin());

CREATE POLICY user_roles_update_admin_only
  ON public.user_roles FOR UPDATE TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- rider_details
CREATE POLICY rider_details_select_own_or_admin
  ON public.rider_details FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.is_admin());

CREATE POLICY rider_details_insert_own
  ON public.rider_details FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid() OR public.is_admin());

CREATE POLICY rider_details_update_own_or_admin
  ON public.rider_details FOR UPDATE TO authenticated
  USING (user_id = auth.uid() OR public.is_admin())
  WITH CHECK (user_id = auth.uid() OR public.is_admin());

-- rider_locations: rider writes own; customer may read assigned rider on active order
CREATE POLICY rider_locations_select_own_assigned_or_admin
  ON public.rider_locations FOR SELECT TO authenticated
  USING (
    rider_id = auth.uid()
    OR public.is_admin()
    OR EXISTS (
      SELECT 1
      FROM public.orders o
      WHERE o.rider_id = rider_locations.rider_id
        AND o.customer_id = auth.uid()
        AND o.status IN (
          'accepted',
          'picked_up',
          'delivered',
          'rider_requested'
        )
    )
  );

CREATE POLICY rider_locations_insert_own
  ON public.rider_locations FOR INSERT TO authenticated
  WITH CHECK (
    rider_id = auth.uid()
    AND public.has_active_role('rider')
    AND EXISTS (
      SELECT 1
      FROM public.rider_details rd
      WHERE rd.user_id = auth.uid()
        AND rd.kyc_status = 'approved'
    )
  );

CREATE POLICY rider_locations_update_own
  ON public.rider_locations FOR UPDATE TO authenticated
  USING (
    rider_id = auth.uid()
    AND public.has_active_role('rider')
    AND EXISTS (
      SELECT 1
      FROM public.rider_details rd
      WHERE rd.user_id = auth.uid()
        AND rd.kyc_status = 'approved'
    )
  )
  WITH CHECK (
    rider_id = auth.uid()
    AND public.has_active_role('rider')
    AND EXISTS (
      SELECT 1
      FROM public.rider_details rd
      WHERE rd.user_id = auth.uid()
        AND rd.kyc_status = 'approved'
    )
  );

-- orders
CREATE POLICY orders_select_participant_or_admin
  ON public.orders FOR SELECT TO authenticated
  USING (
    customer_id = auth.uid()
    OR rider_id = auth.uid()
    OR public.is_admin()
  );

CREATE POLICY orders_insert_as_customer
  ON public.orders FOR INSERT TO authenticated
  WITH CHECK (
    customer_id = auth.uid()
    AND public.has_active_role('customer')
    AND EXISTS (
      SELECT 1
      FROM public.profiles p
      WHERE p.id = auth.uid()
        AND p.has_unsettled_unpaid_order = false
    )
  );

CREATE POLICY orders_update_participant_or_admin
  ON public.orders FOR UPDATE TO authenticated
  USING (
    customer_id = auth.uid()
    OR rider_id = auth.uid()
    OR public.is_admin()
  )
  WITH CHECK (
    customer_id = auth.uid()
    OR rider_id = auth.uid()
    OR public.is_admin()
  );

-- order_events: read only for clients (rows written by log_order_event trigger)
CREATE POLICY order_events_select_participant_or_admin
  ON public.order_events FOR SELECT TO authenticated
  USING (
    public.is_admin()
    OR EXISTS (
      SELECT 1
      FROM public.orders o
      WHERE o.id = order_events.order_id
        AND (o.customer_id = auth.uid() OR o.rider_id = auth.uid())
    )
  );

-- payments: readable by order parties / admin; no client writes
CREATE POLICY payments_select_participant_or_admin
  ON public.payments FOR SELECT TO authenticated
  USING (
    public.is_admin()
    OR EXISTS (
      SELECT 1
      FROM public.orders o
      WHERE o.id = payments.order_id
        AND (o.customer_id = auth.uid() OR o.rider_id = auth.uid())
    )
  );

-- wallet_entries: rider reads own; no client writes
CREATE POLICY wallet_entries_select_own_or_admin
  ON public.wallet_entries FOR SELECT TO authenticated
  USING (rider_id = auth.uid() OR public.is_admin());

-- withdrawals: rider reads own; no client writes
CREATE POLICY withdrawals_select_own_or_admin
  ON public.withdrawals FOR SELECT TO authenticated
  USING (rider_id = auth.uid() OR public.is_admin());

-- ratings
CREATE POLICY ratings_select_involved_or_admin
  ON public.ratings FOR SELECT TO authenticated
  USING (
    from_id = auth.uid()
    OR to_id = auth.uid()
    OR public.is_admin()
  );

CREATE POLICY ratings_insert_own
  ON public.ratings FOR INSERT TO authenticated
  WITH CHECK (
    from_id = auth.uid()
    AND EXISTS (
      SELECT 1
      FROM public.orders o
      WHERE o.id = ratings.order_id
        AND o.status = 'completed'
        AND (o.customer_id = auth.uid() OR o.rider_id = auth.uid())
        AND (ratings.to_id = o.customer_id OR ratings.to_id = o.rider_id)
    )
  );

-- app_settings: anyone signed in can read (pricing); only admin updates via client
CREATE POLICY app_settings_select_authenticated
  ON public.app_settings FOR SELECT TO authenticated
  USING (true);

CREATE POLICY app_settings_update_admin
  ON public.app_settings FOR UPDATE TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- Explicit: no INSERT/UPDATE/DELETE policies for payments, wallet_entries,
-- withdrawals, or order_events for authenticated. Service role bypasses RLS;
-- order_events inserts go through SECURITY DEFINER log_order_event.
-- No DELETE policies on most tables for authenticated users.
