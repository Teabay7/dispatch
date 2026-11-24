-- Customer order creation with server-side pricing (feature 4).
--
-- Quotes are made only by the quote-order Edge Function (service_role), which looks
-- places up on Google, measures the road distance (or falls back to straight line
-- x 1.3) and calls create_order_quote(). The customer then creates the order from
-- that quote with create_order_from_quote(): every price, distance and address field
-- is copied from the quote, so a client can never send a price or coordinates.
-- Once created, an order's addresses, coordinates and price can't change for anyone.
-- Clients (authenticated/anon) can't insert or update orders directly; the database
-- owner and service_role still can (SQL Editor test scripts, fixtures, functions).
-- See docs/orders-admin.md (including the hosted pre-push check).

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
ALTER TABLE public.app_settings
  ADD COLUMN max_order_distance_m integer NOT NULL DEFAULT 20000
    CONSTRAINT app_settings_max_order_distance_range CHECK (max_order_distance_m BETWEEN 1000 AND 100000),
  ADD COLUMN quote_valid_minutes integer NOT NULL DEFAULT 15
    CONSTRAINT app_settings_quote_valid_minutes_range CHECK (quote_valid_minutes BETWEEN 1 AND 120),
  ADD COLUMN quotes_per_hour integer NOT NULL DEFAULT 20
    CONSTRAINT app_settings_quotes_per_hour_range CHECK (quotes_per_hour BETWEEN 1 AND 1000),
  ADD COLUMN place_searches_per_hour integer NOT NULL DEFAULT 300
    CONSTRAINT app_settings_place_searches_per_hour_range CHECK (place_searches_per_hour BETWEEN 1 AND 10000),
  -- Total paid Google calls per day (Lagos time) across all users.
  ADD COLUMN google_calls_per_day integer NOT NULL DEFAULT 2000
    CONSTRAINT app_settings_google_calls_per_day_range CHECK (google_calls_per_day BETWEEN 1 AND 1000000),
  ADD COLUMN max_active_orders_per_customer integer NOT NULL DEFAULT 2
    CONSTRAINT app_settings_max_active_orders_range CHECK (max_active_orders_per_customer BETWEEN 1 AND 20);

-- Pilot prices (SPEC 10.2): ₦600 base fee + ₦600 per km.
UPDATE public.app_settings SET base_fee_kobo = 60000, per_km_rate_kobo = 60000;

-- ---------------------------------------------------------------------------
-- Service areas (admin-managed in the SQL Editor; readable by signed-in users)
-- ---------------------------------------------------------------------------
CREATE TABLE public.service_areas (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE CHECK (btrim(name) <> ''),
  center_lat double precision NOT NULL CHECK (center_lat BETWEEN -90 AND 90),
  center_lng double precision NOT NULL CHECK (center_lng BETWEEN -180 AND 180),
  radius_m integer NOT NULL CHECK (radius_m BETWEEN 500 AND 50000),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.service_areas (name, center_lat, center_lng, radius_m)
VALUES ('Ede, Osun State', 7.7333, 4.4333, 10000);

ALTER TABLE public.service_areas ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.service_areas FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.service_areas FROM authenticated;
CREATE POLICY service_areas_select_authenticated
  ON public.service_areas FOR SELECT TO authenticated USING (true);

-- ---------------------------------------------------------------------------
-- Geometry and pricing helpers
-- ---------------------------------------------------------------------------
-- Great-circle distance in metres (haversine).
CREATE OR REPLACE FUNCTION public.distance_between_m(
  p_lat1 double precision, p_lng1 double precision,
  p_lat2 double precision, p_lng2 double precision
)
RETURNS double precision
LANGUAGE sql
IMMUTABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT 2 * 6371000 * asin(least(1, sqrt(
           power(sin(radians(p_lat2 - p_lat1) / 2), 2)
           + cos(radians(p_lat1)) * cos(radians(p_lat2)) * power(sin(radians(p_lng2 - p_lng1) / 2), 2))));
$$;

CREATE OR REPLACE FUNCTION public.point_in_service_area(p_lat double precision, p_lng double precision)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.service_areas a
     WHERE a.active
       AND public.distance_between_m(a.center_lat, a.center_lng, p_lat, p_lng) <= a.radius_m
  );
$$;

-- D1: base fee + per-km rate per started 100 m, rounded UP to the nearest ₦50.
-- Integer kobo only: units = ceil(m / 100); raw = base + ceil(per_km x units / 10);
-- price = ceil(raw / 5000) x 5000.
CREATE OR REPLACE FUNCTION public.price_for_distance(
  p_distance_m integer,
  p_base_fee_kobo bigint,
  p_per_km_rate_kobo bigint
)
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  units bigint;
  raw bigint;
BEGIN
  IF p_distance_m IS NULL OR p_distance_m < 0 THEN
    RAISE EXCEPTION 'The distance must be zero or more';
  END IF;
  IF p_base_fee_kobo IS NULL OR p_base_fee_kobo < 0 OR p_per_km_rate_kobo IS NULL OR p_per_km_rate_kobo < 0 THEN
    RAISE EXCEPTION 'Fees must be zero or more';
  END IF;
  units := (p_distance_m::bigint + 99) / 100;
  raw := p_base_fee_kobo + (p_per_km_rate_kobo * units + 9) / 10;
  RETURN ((raw + 4999) / 5000) * 5000;
END;
$$;

REVOKE ALL ON FUNCTION public.distance_between_m(double precision, double precision, double precision, double precision) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.point_in_service_area(double precision, double precision) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.price_for_distance(integer, bigint, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.distance_between_m(double precision, double precision, double precision, double precision) TO service_role;
GRANT EXECUTE ON FUNCTION public.point_in_service_area(double precision, double precision) TO service_role;
GRANT EXECUTE ON FUNCTION public.price_for_distance(integer, bigint, bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- Usage counter for rate limits and the daily Google cap (server-only)
-- ---------------------------------------------------------------------------
CREATE TABLE public.api_usage (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles (id),
  kind text NOT NULL CHECK (kind IN ('quote', 'place_search')),
  -- Paid Google calls this request may make (counted up front).
  google_calls integer NOT NULL CHECK (google_calls BETWEEN 0 AND 10),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX api_usage_user_kind_created_idx ON public.api_usage (user_id, kind, created_at DESC);
CREATE INDEX api_usage_created_idx ON public.api_usage (created_at);

ALTER TABLE public.api_usage ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.api_usage FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.api_usage FROM authenticated;
CREATE POLICY api_usage_select_admin
  ON public.api_usage FOR SELECT TO authenticated USING (public.is_admin());

-- Records one request, or refuses it: per-user hourly limit per kind, then the
-- total daily cap on paid Google calls. Called by the Edge Functions BEFORE any
-- Google call. A refused request is not counted.
CREATE OR REPLACE FUNCTION public.use_api_quota(p_user_id uuid, p_kind text, p_google_calls integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  s public.app_settings%ROWTYPE;
  per_hour integer;
  day_start timestamptz := date_trunc('day', now() AT TIME ZONE 'Africa/Lagos') AT TIME ZONE 'Africa/Lagos';
BEGIN
  IF p_user_id IS NULL OR p_kind NOT IN ('quote', 'place_search') OR p_google_calls IS NULL OR p_google_calls < 0 THEN
    RAISE EXCEPTION 'Invalid usage request';
  END IF;
  SELECT * INTO s FROM public.app_settings WHERE id = 1;
  per_hour := CASE p_kind WHEN 'quote' THEN s.quotes_per_hour ELSE s.place_searches_per_hour END;

  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('api_usage:' || p_user_id::text, 0));
  IF (SELECT count(*) FROM public.api_usage
       WHERE user_id = p_user_id AND kind = p_kind AND created_at > now() - interval '1 hour') >= per_hour THEN
    RAISE EXCEPTION 'Too many requests. Try again later.';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('api_usage:daily', 0));
  IF coalesce((SELECT sum(google_calls) FROM public.api_usage WHERE created_at >= day_start), 0)
     + p_google_calls > s.google_calls_per_day THEN
    RAISE EXCEPTION 'Dispatch is busy right now. Try again later.';
  END IF;

  INSERT INTO public.api_usage (user_id, kind, google_calls) VALUES (p_user_id, p_kind, p_google_calls);
END;
$$;

REVOKE ALL ON FUNCTION public.use_api_quota(uuid, text, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.use_api_quota(uuid, text, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- Quotes (server-only writes; a quote is fixed once made)
-- ---------------------------------------------------------------------------
CREATE TYPE public.order_distance_source AS ENUM ('routes', 'straight_line_fallback');

CREATE TABLE public.order_quotes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid NOT NULL REFERENCES public.profiles (id),
  pickup_address text NOT NULL CHECK (btrim(pickup_address) <> ''),
  pickup_lat double precision NOT NULL CHECK (pickup_lat BETWEEN -90 AND 90),
  pickup_lng double precision NOT NULL CHECK (pickup_lng BETWEEN -180 AND 180),
  pickup_place_id text,
  dropoff_address text NOT NULL CHECK (btrim(dropoff_address) <> ''),
  dropoff_lat double precision NOT NULL CHECK (dropoff_lat BETWEEN -90 AND 90),
  dropoff_lng double precision NOT NULL CHECK (dropoff_lng BETWEEN -180 AND 180),
  dropoff_place_id text,
  distance_m integer NOT NULL CHECK (distance_m > 0),
  distance_source public.order_distance_source NOT NULL,
  -- Pricing as it was at quote time.
  base_fee_kobo bigint NOT NULL CHECK (base_fee_kobo >= 0),
  per_km_rate_kobo bigint NOT NULL CHECK (per_km_rate_kobo >= 0),
  commission_bps integer NOT NULL CHECK (commission_bps BETWEEN 0 AND 10000),
  price_kobo bigint NOT NULL CHECK (price_kobo > 0),
  commission_kobo bigint NOT NULL CHECK (commission_kobo >= 0 AND commission_kobo <= price_kobo),
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  -- Set once, when the order is created from this quote.
  order_id uuid UNIQUE
);

CREATE INDEX order_quotes_customer_created_idx ON public.order_quotes (customer_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.order_quotes_protect()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Quotes cannot be deleted';
  END IF;
  IF OLD.order_id IS NOT NULL
     OR NEW.order_id IS NULL
     OR (to_jsonb(NEW) - 'order_id') IS DISTINCT FROM (to_jsonb(OLD) - 'order_id') THEN
    RAISE EXCEPTION 'A quote cannot be changed';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.order_quotes_protect() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER order_quotes_protect
  BEFORE UPDATE OR DELETE ON public.order_quotes
  FOR EACH ROW EXECUTE FUNCTION public.order_quotes_protect();

ALTER TABLE public.order_quotes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.order_quotes FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.order_quotes FROM authenticated;
CREATE POLICY order_quotes_select_own_or_admin
  ON public.order_quotes FOR SELECT TO authenticated
  USING (customer_id = (SELECT auth.uid()) OR public.is_admin());

-- ---------------------------------------------------------------------------
-- orders: quote link, distance, pricing snapshot, package. Nullable for orders made
-- before this migration; every order created from a quote fills them.
-- ---------------------------------------------------------------------------
ALTER TABLE public.orders
  ADD COLUMN quote_id uuid UNIQUE REFERENCES public.order_quotes (id),
  ADD COLUMN distance_m integer CHECK (distance_m IS NULL OR distance_m > 0),
  ADD COLUMN distance_source public.order_distance_source,
  ADD COLUMN priced_with_fallback boolean
    GENERATED ALWAYS AS (distance_source = 'straight_line_fallback') STORED,
  ADD COLUMN base_fee_kobo bigint CHECK (base_fee_kobo IS NULL OR base_fee_kobo >= 0),
  ADD COLUMN per_km_rate_kobo bigint CHECK (per_km_rate_kobo IS NULL OR per_km_rate_kobo >= 0),
  ADD COLUMN commission_bps integer CHECK (commission_bps IS NULL OR commission_bps BETWEEN 0 AND 10000),
  ADD COLUMN package_description text,
  ADD COLUMN pickup_place_id text,
  ADD COLUMN dropoff_place_id text;

CREATE INDEX orders_customer_status_idx ON public.orders (customer_id, status);

-- No client writes to orders: creation and cancelling go through functions.
DROP POLICY orders_insert_as_customer ON public.orders;
DROP POLICY orders_update_participant_or_admin ON public.orders;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.orders FROM anon, authenticated;

-- Replaces protect_order_fields() from 20261102100000_dispatch_data_model.sql.
--   * INSERT: refused for API clients (authenticated, anon); the database owner,
--     service_role and SECURITY DEFINER functions (which run as the owner) may insert.
--   * UPDATE: the addresses, coordinates, place ids, price, commission, distance,
--     pricing snapshot, package, quote and customer never change, for anyone.
--     API clients may not change anything at all.
CREATE OR REPLACE FUNCTION public.protect_order_fields()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  is_client boolean := current_user IN ('authenticated', 'anon');
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF is_client THEN
      RAISE EXCEPTION 'Orders are created from a quote';
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
  END IF;

  IF (NEW.id, NEW.customer_id, NEW.quote_id, NEW.created_at,
      NEW.pickup_address, NEW.pickup_lat, NEW.pickup_lng, NEW.pickup_postcode, NEW.pickup_place_id,
      NEW.dropoff_address, NEW.dropoff_lat, NEW.dropoff_lng, NEW.dropoff_postcode, NEW.dropoff_place_id,
      NEW.price_kobo, NEW.commission_kobo, NEW.distance_m, NEW.distance_source,
      NEW.base_fee_kobo, NEW.per_km_rate_kobo, NEW.commission_bps, NEW.package_description)
     IS DISTINCT FROM
     (OLD.id, OLD.customer_id, OLD.quote_id, OLD.created_at,
      OLD.pickup_address, OLD.pickup_lat, OLD.pickup_lng, OLD.pickup_postcode, OLD.pickup_place_id,
      OLD.dropoff_address, OLD.dropoff_lat, OLD.dropoff_lng, OLD.dropoff_postcode, OLD.dropoff_place_id,
      OLD.price_kobo, OLD.commission_kobo, OLD.distance_m, OLD.distance_source,
      OLD.base_fee_kobo, OLD.per_km_rate_kobo, OLD.commission_bps, OLD.package_description) THEN
    RAISE EXCEPTION 'An order''s addresses, price and package are fixed once it is created';
  END IF;

  IF is_client THEN
    RAISE EXCEPTION 'Orders cannot be changed directly';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.protect_order_fields() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Receiver contact: kept off orders so no open read exposes a phone number.
-- The customer reads their own; riders get it through get_order_contact_details().
-- ---------------------------------------------------------------------------
CREATE TABLE public.order_contacts (
  order_id uuid PRIMARY KEY REFERENCES public.orders (id),
  receiver_name text NOT NULL CHECK (length(btrim(receiver_name)) BETWEEN 2 AND 100),
  receiver_phone text NOT NULL CHECK (receiver_phone ~ '^234[789][01][0-9]{8}$'),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public.order_contacts_protect()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION 'Order contact details cannot be changed or deleted';
END;
$$;

REVOKE ALL ON FUNCTION public.order_contacts_protect() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER order_contacts_protect
  BEFORE UPDATE OR DELETE ON public.order_contacts
  FOR EACH ROW EXECUTE FUNCTION public.order_contacts_protect();

ALTER TABLE public.order_contacts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.order_contacts FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.order_contacts FROM authenticated;
CREATE POLICY order_contacts_select_customer_or_admin
  ON public.order_contacts FOR SELECT TO authenticated
  USING (
    public.is_admin()
    OR EXISTS (SELECT 1 FROM public.orders o
                WHERE o.id = order_contacts.order_id AND o.customer_id = (SELECT auth.uid()))
  );

-- ---------------------------------------------------------------------------
-- Is this user an active customer? (checks the given user, not the caller)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.customer_role_is_active(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles
     WHERE user_id = p_user_id AND role = 'customer' AND status = 'active'
  );
$$;

REVOKE ALL ON FUNCTION public.customer_role_is_active(uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Make a quote (quote-order Edge Function only, as service_role)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_order_quote(
  p_customer_id uuid,
  p_pickup_address text,
  p_pickup_lat double precision,
  p_pickup_lng double precision,
  p_pickup_place_id text,
  p_dropoff_address text,
  p_dropoff_lat double precision,
  p_dropoff_lng double precision,
  p_dropoff_place_id text,
  p_distance_m integer,
  p_distance_source public.order_distance_source
)
RETURNS public.order_quotes
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  s public.app_settings%ROWTYPE;
  v_price bigint;
  result public.order_quotes;
BEGIN
  IF NOT public.customer_role_is_active(p_customer_id) THEN
    RAISE EXCEPTION 'An active customer account is required to order';
  END IF;
  IF btrim(coalesce(p_pickup_address, '')) = '' OR btrim(coalesce(p_dropoff_address, '')) = ''
     OR p_pickup_lat IS NULL OR p_pickup_lng IS NULL OR p_dropoff_lat IS NULL OR p_dropoff_lng IS NULL
     OR p_distance_source IS NULL THEN
    RAISE EXCEPTION 'Pickup and drop-off are required';
  END IF;
  IF NOT public.point_in_service_area(p_pickup_lat, p_pickup_lng) THEN
    RAISE EXCEPTION 'The pickup point is outside the Dispatch service area';
  END IF;
  IF NOT public.point_in_service_area(p_dropoff_lat, p_dropoff_lng) THEN
    RAISE EXCEPTION 'The drop-off point is outside the Dispatch service area';
  END IF;

  SELECT * INTO s FROM public.app_settings WHERE id = 1;
  IF p_distance_m IS NULL OR p_distance_m <= 0 THEN
    RAISE EXCEPTION 'Pickup and drop-off must be different places';
  END IF;
  IF p_distance_m > s.max_order_distance_m THEN
    RAISE EXCEPTION 'This delivery is longer than the maximum distance';
  END IF;

  v_price := public.price_for_distance(p_distance_m, s.base_fee_kobo, s.per_km_rate_kobo);

  INSERT INTO public.order_quotes
    (customer_id, pickup_address, pickup_lat, pickup_lng, pickup_place_id,
     dropoff_address, dropoff_lat, dropoff_lng, dropoff_place_id,
     distance_m, distance_source, base_fee_kobo, per_km_rate_kobo, commission_bps,
     price_kobo, commission_kobo, expires_at)
  VALUES
    (p_customer_id, btrim(p_pickup_address), p_pickup_lat, p_pickup_lng, NULLIF(btrim(p_pickup_place_id), ''),
     btrim(p_dropoff_address), p_dropoff_lat, p_dropoff_lng, NULLIF(btrim(p_dropoff_place_id), ''),
     p_distance_m, p_distance_source, s.base_fee_kobo, s.per_km_rate_kobo, s.commission_bps,
     v_price, public.commission_for_price(v_price, s.commission_bps),
     now() + make_interval(mins => s.quote_valid_minutes))
  RETURNING * INTO result;
  RETURN result;
END;
$$;

REVOKE ALL ON FUNCTION public.create_order_quote(uuid, text, double precision, double precision, text, text, double precision, double precision, text, integer, public.order_distance_source) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_order_quote(uuid, text, double precision, double precision, text, text, double precision, double precision, text, integer, public.order_distance_source) TO service_role;

-- ---------------------------------------------------------------------------
-- Customer: create the order from a quote (the only way a customer creates one)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_order_from_quote(
  p_quote_id uuid,
  p_package_description text,
  p_receiver_name text,
  p_receiver_phone text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  uid uuid := auth.uid();
  q public.order_quotes%ROWTYPE;
  v_package text := regexp_replace(btrim(coalesce(p_package_description, '')), '\s+', ' ', 'g');
  v_name text := regexp_replace(btrim(coalesce(p_receiver_name, '')), '\s+', ' ', 'g');
  v_phone text := regexp_replace(coalesce(p_receiver_phone, ''), '^\+', '');
  v_limit integer;
  new_id uuid;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'Sign in to order';
  END IF;
  IF NOT public.customer_role_is_active(uid) THEN
    RAISE EXCEPTION 'An active customer account is required to order';
  END IF;

  SELECT * INTO q FROM public.order_quotes WHERE id = p_quote_id FOR UPDATE;
  IF NOT FOUND OR q.customer_id <> uid THEN
    RAISE EXCEPTION 'Quote not found';
  END IF;
  IF q.order_id IS NOT NULL THEN
    RAISE EXCEPTION 'This price has already been used for an order';
  END IF;
  IF q.expires_at <= now() THEN
    RAISE EXCEPTION 'This price has expired. Get a new price.';
  END IF;

  IF length(v_package) < 2 OR length(v_package) > 200 THEN
    RAISE EXCEPTION 'Describe the package (2 to 200 characters)';
  END IF;
  IF length(v_name) < 2 OR length(v_name) > 100 THEN
    RAISE EXCEPTION 'Enter the receiver''s name';
  END IF;
  IF v_phone !~ '^234[789][01][0-9]{8}$' THEN
    RAISE EXCEPTION 'Enter the receiver''s Nigerian mobile number';
  END IF;

  -- One customer at a time, so two quick taps can't pass the limit together.
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('orders:' || uid::text, 0));
  SELECT max_active_orders_per_customer INTO v_limit FROM public.app_settings WHERE id = 1;
  IF (SELECT count(*) FROM public.orders
       WHERE customer_id = uid
         AND status IN ('created', 'rider_requested', 'accepted', 'picked_up')) >= v_limit THEN
    RAISE EXCEPTION 'You have reached the limit of active orders. Wait for one to finish or cancel it.';
  END IF;

  INSERT INTO public.orders
    (customer_id, quote_id, status,
     pickup_address, pickup_lat, pickup_lng, pickup_place_id,
     dropoff_address, dropoff_lat, dropoff_lng, dropoff_place_id,
     distance_m, distance_source, base_fee_kobo, per_km_rate_kobo, commission_bps,
     price_kobo, commission_kobo, package_description)
  VALUES
    (uid, q.id, 'created',
     q.pickup_address, q.pickup_lat, q.pickup_lng, q.pickup_place_id,
     q.dropoff_address, q.dropoff_lat, q.dropoff_lng, q.dropoff_place_id,
     q.distance_m, q.distance_source, q.base_fee_kobo, q.per_km_rate_kobo, q.commission_bps,
     q.price_kobo, q.commission_kobo, v_package)
  RETURNING id INTO new_id;

  INSERT INTO public.order_contacts (order_id, receiver_name, receiver_phone)
  VALUES (new_id, v_name, v_phone);

  UPDATE public.order_quotes SET order_id = new_id WHERE id = q.id;
  RETURN new_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- Customer: cancel before a rider accepts (SPEC 10.6). Late cancels and
-- admin-only cancelling after pickup come with dispatch.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_order(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  o public.orders%ROWTYPE;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND OR o.customer_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Order not found';
  END IF;
  IF o.status NOT IN ('created', 'rider_requested') THEN
    RAISE EXCEPTION 'This order can no longer be cancelled in the app';
  END IF;
  UPDATE public.orders SET status = 'cancelled_by_customer' WHERE id = o.id;
END;
$$;

-- ---------------------------------------------------------------------------
-- Rider (after accepting) or admin: who to call. Wired in with dispatch.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_order_contact_details(p_order_id uuid)
RETURNS TABLE (customer_name text, customer_phone text, receiver_name text, receiver_phone text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  o public.orders%ROWTYPE;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND OR NOT (
       public.is_admin()
    OR (o.rider_id = auth.uid() AND o.status IN ('accepted', 'picked_up'))
  ) THEN
    RAISE EXCEPTION 'Contact details are not available for this order';
  END IF;
  RETURN QUERY
    SELECT p.full_name, p.phone, c.receiver_name, c.receiver_phone
      FROM public.profiles p
      LEFT JOIN public.order_contacts c ON c.order_id = o.id
     WHERE p.id = o.customer_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_order_from_quote(uuid, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cancel_order(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_order_contact_details(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_order_from_quote(uuid, text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cancel_order(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_order_contact_details(uuid) TO authenticated, service_role;
