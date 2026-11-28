-- Dispatch (feature 5): offer each new order to the nearest eligible rider, one at a
-- time, with a timeout; accept race-safely; move the job through arrived and picked
-- up; cancellation rules with counted late cancels and admin review flags; and
-- server functions that show the customer the assigned rider and their location.
--
-- Matching runs in the database. Orders created in the app start at once; a pg_cron
-- sweep (run_dispatch_sweep, every 10 seconds) expires timed-out offers, moves on to
-- the next rider, starts orders created in the SQL Editor and ends searches that ran
-- out of attempts or time. It exits early when there is nothing to do.
-- Phone numbers, addresses and account numbers never go into dispatch_offers,
-- cancellation_events, order_events, error messages or logs.
-- See docs/dispatch-admin.md (including the hosted pre-push check and the schedule).

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
ALTER TABLE public.app_settings
  ADD COLUMN offer_timeout_seconds integer NOT NULL DEFAULT 30
    CONSTRAINT app_settings_offer_timeout_range CHECK (offer_timeout_seconds BETWEEN 10 AND 300),
  ADD COLUMN dispatch_max_attempts integer NOT NULL DEFAULT 5
    CONSTRAINT app_settings_dispatch_max_attempts_range CHECK (dispatch_max_attempts BETWEEN 1 AND 30),
  ADD COLUMN dispatch_max_radius_m integer NOT NULL DEFAULT 5000
    CONSTRAINT app_settings_dispatch_max_radius_range CHECK (dispatch_max_radius_m BETWEEN 500 AND 50000),
  ADD COLUMN dispatch_search_minutes integer NOT NULL DEFAULT 10
    CONSTRAINT app_settings_dispatch_search_minutes_range CHECK (dispatch_search_minutes BETWEEN 1 AND 60),
  ADD COLUMN customer_late_cancel_flag_after integer NOT NULL DEFAULT 3
    CONSTRAINT app_settings_customer_late_cancel_range CHECK (customer_late_cancel_flag_after BETWEEN 1 AND 20),
  ADD COLUMN rider_late_cancel_flag_after integer NOT NULL DEFAULT 3
    CONSTRAINT app_settings_rider_late_cancel_range CHECK (rider_late_cancel_flag_after BETWEEN 1 AND 20);

-- ---------------------------------------------------------------------------
-- orders: dispatch fields. A rider has at most one active job (database-enforced).
-- ---------------------------------------------------------------------------
ALTER TABLE public.orders
  ADD COLUMN dispatch_round integer NOT NULL DEFAULT 0 CHECK (dispatch_round >= 0),
  ADD COLUMN dispatch_started_at timestamptz,
  ADD COLUMN accepted_at timestamptz,
  ADD COLUMN arrived_pickup_at timestamptz,
  ADD COLUMN picked_up_at timestamptz,
  ADD COLUMN cancelled_at timestamptz,
  -- The rider's verified bank account at acceptance: where this order is paid.
  ADD COLUMN payee_account_id uuid REFERENCES public.rider_bank_accounts (id);

CREATE UNIQUE INDEX orders_one_active_job_per_rider
  ON public.orders (rider_id)
  WHERE rider_id IS NOT NULL AND status IN ('accepted', 'picked_up');

CREATE INDEX orders_searching_idx ON public.orders (status)
  WHERE status IN ('created', 'rider_requested');

-- ---------------------------------------------------------------------------
-- Offers
-- ---------------------------------------------------------------------------
CREATE TYPE public.dispatch_offer_status AS ENUM ('pending', 'accepted', 'declined', 'expired', 'withdrawn');

CREATE TABLE public.dispatch_offers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders (id),
  round_no integer NOT NULL CHECK (round_no >= 1),
  attempt_no integer NOT NULL CHECK (attempt_no >= 1),
  rider_id uuid NOT NULL REFERENCES public.rider_details (user_id),
  distance_to_pickup_m integer NOT NULL CHECK (distance_to_pickup_m >= 0),
  offered_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  status public.dispatch_offer_status NOT NULL DEFAULT 'pending',
  responded_at timestamptz,
  -- A rider is never offered the same order twice in one search round.
  CONSTRAINT dispatch_offers_once_per_round UNIQUE (order_id, round_no, rider_id),
  CONSTRAINT dispatch_offers_responded CHECK ((status = 'pending') = (responded_at IS NULL))
);

-- One offer at a time per order, and per rider.
CREATE UNIQUE INDEX dispatch_offers_one_pending_per_order ON public.dispatch_offers (order_id) WHERE status = 'pending';
CREATE UNIQUE INDEX dispatch_offers_one_pending_per_rider ON public.dispatch_offers (rider_id) WHERE status = 'pending';
CREATE INDEX dispatch_offers_pending_expiry_idx ON public.dispatch_offers (expires_at) WHERE status = 'pending';

CREATE OR REPLACE FUNCTION public.dispatch_offers_protect()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Dispatch offers cannot be deleted';
  END IF;
  IF (NEW.id, NEW.order_id, NEW.round_no, NEW.attempt_no, NEW.rider_id, NEW.distance_to_pickup_m,
      NEW.offered_at, NEW.expires_at)
     IS DISTINCT FROM
     (OLD.id, OLD.order_id, OLD.round_no, OLD.attempt_no, OLD.rider_id, OLD.distance_to_pickup_m,
      OLD.offered_at, OLD.expires_at)
     OR (OLD.status <> 'pending' AND NEW.status IS DISTINCT FROM OLD.status) THEN
    RAISE EXCEPTION 'A dispatch offer cannot be changed';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.dispatch_offers_protect() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER dispatch_offers_protect
  BEFORE UPDATE OR DELETE ON public.dispatch_offers
  FOR EACH ROW EXECUTE FUNCTION public.dispatch_offers_protect();

ALTER TABLE public.dispatch_offers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.dispatch_offers FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.dispatch_offers FROM authenticated;
CREATE POLICY dispatch_offers_select_own_or_admin
  ON public.dispatch_offers FOR SELECT TO authenticated
  USING (rider_id = (SELECT auth.uid()) OR public.is_admin());

-- ---------------------------------------------------------------------------
-- Cancellations (append-only) and admin review flags
-- ---------------------------------------------------------------------------
CREATE TYPE public.cancel_stage AS ENUM ('before_accept', 'after_accept', 'after_pickup');

CREATE TABLE public.cancellation_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders (id),
  cancelled_by uuid REFERENCES public.profiles (id),   -- NULL when an admin uses the SQL Editor
  role text NOT NULL CHECK (role IN ('customer', 'rider', 'admin')),
  stage public.cancel_stage NOT NULL,
  counted boolean NOT NULL,
  -- A short code for riders; free text only from admins. Never a phone or account
  -- number: 7 or more digits in a row are refused.
  reason text CHECK (reason IS NULL OR (length(reason) <= 300 AND reason !~ '[0-9]{7,}')),
  recorded_by text CHECK (recorded_by IS NULL OR recorded_by !~ '[0-9]{7,}'),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX cancellation_events_counted_idx
  ON public.cancellation_events (cancelled_by, role) WHERE counted;
CREATE INDEX cancellation_events_order_idx ON public.cancellation_events (order_id);

CREATE TRIGGER cancellation_events_no_update
  BEFORE UPDATE OR DELETE ON public.cancellation_events
  FOR EACH ROW EXECUTE FUNCTION public.reject_ledger_mutation();
CREATE TRIGGER cancellation_events_no_truncate
  BEFORE TRUNCATE ON public.cancellation_events
  FOR EACH STATEMENT EXECUTE FUNCTION public.reject_ledger_mutation();

CREATE TABLE public.admin_review_flags (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles (id),
  role text NOT NULL CHECK (role IN ('customer', 'rider')),
  reason text NOT NULL CHECK (reason IN ('late_cancels')),
  created_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  resolved_by text,
  resolution_note text CHECK (resolution_note IS NULL OR resolution_note !~ '[0-9]{7,}'),
  CONSTRAINT admin_review_flags_resolved CHECK (
    (resolved_at IS NULL AND resolved_by IS NULL)
    OR (resolved_at IS NOT NULL AND btrim(coalesce(resolved_by, '')) <> '')
  )
);

-- At most one open flag per user, role and reason.
CREATE UNIQUE INDEX admin_review_flags_one_open
  ON public.admin_review_flags (user_id, role, reason) WHERE resolved_at IS NULL;

ALTER TABLE public.cancellation_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_review_flags ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.cancellation_events, public.admin_review_flags FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.cancellation_events, public.admin_review_flags FROM authenticated;
CREATE POLICY cancellation_events_select_admin
  ON public.cancellation_events FOR SELECT TO authenticated USING (public.is_admin());
CREATE POLICY admin_review_flags_select_admin
  ON public.admin_review_flags FOR SELECT TO authenticated USING (public.is_admin());

-- ---------------------------------------------------------------------------
-- Helpers (not callable by API roles)
-- ---------------------------------------------------------------------------
-- All matching is serialised: simple and safe for the pilot's volume.
CREATE OR REPLACE FUNCTION public.lock_dispatch()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('dispatch', 0));
$$;

-- Could this rider take a job now? (Ignores whether they hold an offer.)
CREATE OR REPLACE FUNCTION public.rider_can_take_job(p_rider_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM public.rider_details rd
      JOIN public.rider_locations rl ON rl.rider_id = rd.user_id
     WHERE rd.user_id = p_rider_id
       AND rd.is_online
       AND rd.kyc_status = 'approved'
       AND rl.updated_at >= public.rider_stale_cutoff()
  )
  AND public.rider_role_is_active(p_rider_id)
  AND public.rider_has_verified_bank_account(p_rider_id)
  AND NOT public.rider_has_commission_due(p_rider_id)
  AND NOT EXISTS (
    SELECT 1 FROM public.orders o
     WHERE o.rider_id = p_rider_id AND o.status IN ('accepted', 'picked_up')
  );
$$;

-- Can this rider be offered a new order now?
CREATE OR REPLACE FUNCTION public.rider_is_dispatchable(p_rider_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT public.rider_can_take_job(p_rider_id)
     AND NOT EXISTS (SELECT 1 FROM public.dispatch_offers WHERE rider_id = p_rider_id AND status = 'pending');
$$;

-- "north-east" etc.: the direction from the rider to the pickup.
CREATE OR REPLACE FUNCTION public.compass_direction(
  p_from_lat double precision, p_from_lng double precision,
  p_to_lat double precision, p_to_lng double precision
)
RETURNS text
LANGUAGE sql
IMMUTABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT (ARRAY['north', 'north-east', 'east', 'south-east', 'south', 'south-west', 'west', 'north-west'])[
    (round(((degrees(atan2(
        sin(radians(p_to_lng - p_from_lng)) * cos(radians(p_to_lat)),
        cos(radians(p_from_lat)) * sin(radians(p_to_lat))
          - sin(radians(p_from_lat)) * cos(radians(p_to_lat)) * cos(radians(p_to_lng - p_from_lng))
      )) + 360)::numeric % 360) / 45)::integer % 8) + 1];
$$;

-- Counts a counted late cancel and opens a review flag at the threshold.
CREATE OR REPLACE FUNCTION public.flag_after_late_cancels(p_user_id uuid, p_role text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  threshold integer;
BEGIN
  SELECT CASE p_role WHEN 'customer' THEN customer_late_cancel_flag_after ELSE rider_late_cancel_flag_after END
    INTO threshold FROM public.app_settings WHERE id = 1;
  IF (SELECT count(*) FROM public.cancellation_events
       WHERE cancelled_by = p_user_id AND role = p_role AND counted) >= threshold
     AND NOT EXISTS (SELECT 1 FROM public.admin_review_flags
                      WHERE user_id = p_user_id AND role = p_role AND reason = 'late_cancels'
                        AND resolved_at IS NULL) THEN
    INSERT INTO public.admin_review_flags (user_id, role, reason) VALUES (p_user_id, p_role, 'late_cancels');
  END IF;
END;
$$;

-- Ends a search with no rider.
CREATE OR REPLACE FUNCTION public.end_search_no_rider(p_order_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  UPDATE public.orders SET status = 'no_rider_found' WHERE id = p_order_id AND status = 'rider_requested';
$$;

-- Offers the order to the nearest eligible rider not yet offered it in this round.
-- Returns the offer id, or NULL (an offer is pending, nobody eligible yet, or the
-- search ended with no rider). Caller holds lock_dispatch().
CREATE OR REPLACE FUNCTION public.offer_next_rider(p_order_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  o public.orders%ROWTYPE;
  s public.app_settings%ROWTYPE;
  attempts integer;
  pick record;
  new_id uuid;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND OR o.status <> 'rider_requested' OR o.rider_id IS NOT NULL THEN
    RETURN NULL;
  END IF;
  IF EXISTS (SELECT 1 FROM public.dispatch_offers WHERE order_id = o.id AND status = 'pending') THEN
    RETURN NULL;
  END IF;

  SELECT * INTO s FROM public.app_settings WHERE id = 1;
  SELECT count(*) INTO attempts FROM public.dispatch_offers WHERE order_id = o.id AND round_no = o.dispatch_round;
  IF attempts >= s.dispatch_max_attempts THEN
    PERFORM public.end_search_no_rider(o.id);
    RETURN NULL;
  END IF;

  SELECT rd.user_id AS rider_id,
         public.distance_between_m(rl.lat, rl.lng, o.pickup_lat, o.pickup_lng) AS distance
    INTO pick
    FROM public.rider_details rd
    JOIN public.rider_locations rl ON rl.rider_id = rd.user_id
   WHERE rd.is_online
     AND public.distance_between_m(rl.lat, rl.lng, o.pickup_lat, o.pickup_lng) <= s.dispatch_max_radius_m
     AND NOT EXISTS (SELECT 1 FROM public.dispatch_offers d
                      WHERE d.order_id = o.id AND d.round_no = o.dispatch_round AND d.rider_id = rd.user_id)
     -- A rider who cancelled this job is never offered it again.
     AND NOT EXISTS (SELECT 1 FROM public.cancellation_events c
                      WHERE c.order_id = o.id AND c.role = 'rider' AND c.cancelled_by = rd.user_id)
     AND rd.user_id IS DISTINCT FROM o.customer_id
     AND public.rider_is_dispatchable(rd.user_id)
   ORDER BY 2, rl.updated_at DESC
   LIMIT 1;

  IF pick.rider_id IS NULL THEN
    IF o.dispatch_started_at IS NOT NULL
       AND now() >= o.dispatch_started_at + make_interval(mins => s.dispatch_search_minutes) THEN
      PERFORM public.end_search_no_rider(o.id);
    END IF;
    RETURN NULL;
  END IF;

  INSERT INTO public.dispatch_offers (order_id, round_no, attempt_no, rider_id, distance_to_pickup_m, expires_at)
  VALUES (o.id, o.dispatch_round, attempts + 1, pick.rider_id, ceil(pick.distance)::integer,
          now() + make_interval(secs => s.offer_timeout_seconds))
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

-- Starts a new search round for an order that is created or found no rider.
CREATE OR REPLACE FUNCTION public.begin_dispatch(p_order_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public.lock_dispatch();
  UPDATE public.orders
     SET status = 'rider_requested',
         dispatch_round = dispatch_round + 1,
         dispatch_started_at = now()
   WHERE id = p_order_id AND status IN ('created', 'no_rider_found') AND rider_id IS NULL;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  RETURN public.offer_next_rider(p_order_id);
END;
$$;

-- Withdraws any pending offer for an order (it was cancelled or taken).
CREATE OR REPLACE FUNCTION public.withdraw_pending_offers(p_order_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  UPDATE public.dispatch_offers SET status = 'withdrawn', responded_at = now()
   WHERE order_id = p_order_id AND status = 'pending';
$$;

REVOKE ALL ON FUNCTION public.lock_dispatch() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rider_can_take_job(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rider_is_dispatchable(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.compass_direction(double precision, double precision, double precision, double precision) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.flag_after_late_cancels(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.end_search_no_rider(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.offer_next_rider(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.begin_dispatch(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.withdraw_pending_offers(uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The sweep (pg_cron every 10 seconds; see docs/dispatch-admin.md)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.run_dispatch_sweep()
RETURNS integer -- offers made
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r record;
  made integer := 0;
BEGIN
  -- Cheap exit: nothing searching, nothing pending.
  IF NOT EXISTS (SELECT 1 FROM public.orders WHERE status IN ('created', 'rider_requested'))
     AND NOT EXISTS (SELECT 1 FROM public.dispatch_offers WHERE status = 'pending') THEN
    RETURN 0;
  END IF;

  PERFORM public.lock_dispatch();

  -- Timed-out offers, and offers to riders who can no longer take a job.
  UPDATE public.dispatch_offers d
     SET status = 'expired', responded_at = now()
   WHERE d.status = 'pending'
     AND (d.expires_at <= now() OR NOT public.rider_can_take_job(d.rider_id));

  -- Orders created outside the app (SQL Editor) start here.
  FOR r IN SELECT id FROM public.orders WHERE status = 'created' AND rider_id IS NULL ORDER BY created_at LOOP
    IF public.begin_dispatch(r.id) IS NOT NULL THEN made := made + 1; END IF;
  END LOOP;

  -- Searching orders without a pending offer: next rider, or end the search.
  FOR r IN
    SELECT o.id FROM public.orders o
     WHERE o.status = 'rider_requested'
       AND NOT EXISTS (SELECT 1 FROM public.dispatch_offers d WHERE d.order_id = o.id AND d.status = 'pending')
     ORDER BY o.dispatch_started_at NULLS FIRST
  LOOP
    IF public.offer_next_rider(r.id) IS NOT NULL THEN made := made + 1; END IF;
  END LOOP;

  RETURN made;
END;
$$;

REVOKE ALL ON FUNCTION public.run_dispatch_sweep() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.run_dispatch_sweep() TO service_role;

-- ---------------------------------------------------------------------------
-- Admin (SQL Editor) and server
-- ---------------------------------------------------------------------------
-- Start (or restart) the search for one order now, instead of waiting for the sweep.
CREATE OR REPLACE FUNCTION public.start_dispatch(p_order_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT (COALESCE(auth.role(), 'service_role') = 'service_role' OR public.is_admin()) THEN
    RAISE EXCEPTION 'Only an admin can start dispatch';
  END IF;
  RETURN public.begin_dispatch(p_order_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_cancel_order(
  p_order_id uuid,
  p_on_behalf_of text,
  p_reason text,
  p_recorded_by text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  o public.orders%ROWTYPE;
BEGIN
  IF NOT (COALESCE(auth.role(), 'service_role') = 'service_role' OR public.is_admin()) THEN
    RAISE EXCEPTION 'Only an admin can cancel this way';
  END IF;
  IF p_on_behalf_of NOT IN ('customer', 'rider') THEN
    RAISE EXCEPTION 'Cancel on behalf of the customer or the rider';
  END IF;
  IF btrim(coalesce(p_reason, '')) = '' OR btrim(coalesce(p_recorded_by, '')) = '' THEN
    RAISE EXCEPTION 'A reason and who is recording it are required';
  END IF;
  IF p_reason ~ '[0-9]{7,}' OR p_recorded_by ~ '[0-9]{7,}' THEN
    RAISE EXCEPTION 'Do not put phone or account numbers in the reason';
  END IF;

  PERFORM public.lock_dispatch();
  SELECT * INTO o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order not found';
  END IF;
  IF o.status NOT IN ('created', 'rider_requested', 'accepted', 'picked_up', 'no_rider_found') THEN
    RAISE EXCEPTION 'This order has already ended';
  END IF;

  PERFORM public.withdraw_pending_offers(o.id);
  UPDATE public.orders
     SET status = CASE p_on_behalf_of WHEN 'customer' THEN 'cancelled_by_customer'::public.order_status
                                      ELSE 'cancelled_by_rider'::public.order_status END,
         cancelled_at = now()
   WHERE id = o.id;
  INSERT INTO public.cancellation_events (order_id, cancelled_by, role, stage, counted, reason, recorded_by)
  VALUES (o.id, auth.uid(), 'admin',
          CASE WHEN o.status = 'picked_up' THEN 'after_pickup'::public.cancel_stage
               WHEN o.status = 'accepted' THEN 'after_accept'::public.cancel_stage
               ELSE 'before_accept'::public.cancel_stage END,
          false, btrim(p_reason), btrim(p_recorded_by));
END;
$$;

CREATE OR REPLACE FUNCTION public.resolve_review_flag(p_flag_id uuid, p_note text, p_recorded_by text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT (COALESCE(auth.role(), 'service_role') = 'service_role' OR public.is_admin()) THEN
    RAISE EXCEPTION 'Only an admin can resolve review flags';
  END IF;
  IF btrim(coalesce(p_recorded_by, '')) = '' THEN
    RAISE EXCEPTION 'Enter who is recording this';
  END IF;
  UPDATE public.admin_review_flags
     SET resolved_at = now(), resolved_by = btrim(p_recorded_by), resolution_note = NULLIF(btrim(coalesce(p_note, '')), '')
   WHERE id = p_flag_id AND resolved_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Open review flag not found';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.start_dispatch(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_cancel_order(uuid, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.resolve_review_flag(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.start_dispatch(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_cancel_order(uuid, text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.resolve_review_flag(uuid, text, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Rider
-- ---------------------------------------------------------------------------
-- The rider's current offer: no address until accepted.
CREATE OR REPLACE FUNCTION public.get_my_offer()
RETURNS TABLE (
  offer_id uuid,
  order_id uuid,
  distance_to_pickup_m integer,
  direction text,
  area_name text,
  trip_distance_m integer,
  price_kobo bigint,
  seconds_left integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT d.id, d.order_id, d.distance_to_pickup_m,
         CASE WHEN rl.rider_id IS NULL THEN NULL
              ELSE public.compass_direction(rl.lat, rl.lng, o.pickup_lat, o.pickup_lng) END,
         coalesce((SELECT a.name FROM public.service_areas a
                    WHERE a.active
                      AND public.distance_between_m(a.center_lat, a.center_lng, o.pickup_lat, o.pickup_lng) <= a.radius_m
                    ORDER BY a.created_at LIMIT 1), 'Dispatch area'),
         o.distance_m,
         o.price_kobo,
         greatest(0, ceil(extract(epoch FROM d.expires_at - now())))::integer
    FROM public.dispatch_offers d
    JOIN public.orders o ON o.id = d.order_id
    LEFT JOIN public.rider_locations rl ON rl.rider_id = d.rider_id
   WHERE d.rider_id = auth.uid() AND d.status = 'pending' AND d.expires_at > now();
$$;

CREATE OR REPLACE FUNCTION public.get_my_active_job()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT id FROM public.orders
   WHERE rider_id = auth.uid() AND status IN ('accepted', 'picked_up')
   LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.accept_offer(p_offer_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  uid uuid := auth.uid();
  d public.dispatch_offers%ROWTYPE;
  o public.orders%ROWTYPE;
  v_payee uuid;
BEGIN
  PERFORM public.lock_dispatch();
  SELECT * INTO d FROM public.dispatch_offers WHERE id = p_offer_id FOR UPDATE;
  IF NOT FOUND OR d.rider_id IS DISTINCT FROM uid THEN
    RAISE EXCEPTION 'Offer not found';
  END IF;
  IF d.status <> 'pending' THEN
    RAISE EXCEPTION 'This offer is no longer available';
  END IF;
  IF d.expires_at <= now() THEN
    RAISE EXCEPTION 'This offer has expired';
  END IF;

  SELECT * INTO o FROM public.orders WHERE id = d.order_id FOR UPDATE;
  IF o.status <> 'rider_requested' OR o.rider_id IS NOT NULL THEN
    RAISE EXCEPTION 'This offer is no longer available';
  END IF;
  IF NOT public.rider_can_take_job(uid) THEN
    RAISE EXCEPTION 'You cannot take a job right now';
  END IF;

  SELECT id INTO v_payee FROM public.rider_bank_accounts WHERE rider_id = uid AND status = 'verified';

  UPDATE public.dispatch_offers SET status = 'accepted', responded_at = now() WHERE id = d.id;
  UPDATE public.orders
     SET rider_id = uid, status = 'accepted', accepted_at = now(), payee_account_id = v_payee
   WHERE id = o.id;
  RETURN o.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.decline_offer(p_offer_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  d public.dispatch_offers%ROWTYPE;
BEGIN
  PERFORM public.lock_dispatch();
  SELECT * INTO d FROM public.dispatch_offers WHERE id = p_offer_id FOR UPDATE;
  IF NOT FOUND OR d.rider_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Offer not found';
  END IF;
  IF d.status <> 'pending' THEN
    RAISE EXCEPTION 'This offer is no longer available';
  END IF;
  UPDATE public.dispatch_offers SET status = 'declined', responded_at = now() WHERE id = d.id;
  PERFORM public.offer_next_rider(d.order_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_arrived_at_pickup(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  o public.orders%ROWTYPE;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND OR o.rider_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Job not found';
  END IF;
  IF o.status <> 'accepted' OR o.arrived_pickup_at IS NOT NULL THEN
    RAISE EXCEPTION 'You can mark arrival only once, after accepting';
  END IF;
  UPDATE public.orders SET arrived_pickup_at = now() WHERE id = o.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_picked_up(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  o public.orders%ROWTYPE;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND OR o.rider_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Job not found';
  END IF;
  IF o.status <> 'accepted' OR o.arrived_pickup_at IS NULL THEN
    RAISE EXCEPTION 'Mark that you have arrived at pickup first';
  END IF;
  UPDATE public.orders SET status = 'picked_up', picked_up_at = now() WHERE id = o.id;
END;
$$;

-- Before pickup only; counted against the rider. The order goes back to searching.
CREATE OR REPLACE FUNCTION public.rider_cancel_job(p_order_id uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  uid uuid := auth.uid();
  o public.orders%ROWTYPE;
BEGIN
  IF p_reason IS NULL OR p_reason NOT IN ('customer_unreachable', 'pickup_problem', 'vehicle_problem', 'safety', 'other') THEN
    RAISE EXCEPTION 'Choose a reason';
  END IF;
  PERFORM public.lock_dispatch();
  SELECT * INTO o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND OR o.rider_id IS DISTINCT FROM uid THEN
    RAISE EXCEPTION 'Job not found';
  END IF;
  IF o.status <> 'accepted' THEN
    RAISE EXCEPTION 'After pickup, only Dispatch support can cancel';
  END IF;

  INSERT INTO public.cancellation_events (order_id, cancelled_by, role, stage, counted, reason)
  VALUES (o.id, uid, 'rider', 'after_accept', true, p_reason);
  PERFORM public.flag_after_late_cancels(uid, 'rider');

  -- Same round (riders who already declined stay excluded), fresh search time. An
  -- order assigned directly in the SQL Editor has round 0, so start it at 1.
  UPDATE public.orders
     SET rider_id = NULL, status = 'rider_requested', accepted_at = NULL, arrived_pickup_at = NULL,
         payee_account_id = NULL, dispatch_round = greatest(dispatch_round, 1), dispatch_started_at = now()
   WHERE id = o.id;
  PERFORM public.offer_next_rider(o.id);
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_offer() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_my_active_job() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.accept_offer(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.decline_offer(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.mark_arrived_at_pickup(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.mark_picked_up(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rider_cancel_job(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_offer() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_active_job() TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_offer(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.decline_offer(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_arrived_at_pickup(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_picked_up(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rider_cancel_job(uuid, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Customer
-- ---------------------------------------------------------------------------
-- Replaces cancel_order() from 20261125100000: free before a rider accepts; counted
-- after acceptance (review flag at the threshold); refused after pickup.
CREATE OR REPLACE FUNCTION public.cancel_order(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  uid uuid := auth.uid();
  o public.orders%ROWTYPE;
BEGIN
  PERFORM public.lock_dispatch();
  SELECT * INTO o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND OR o.customer_id IS DISTINCT FROM uid THEN
    RAISE EXCEPTION 'Order not found';
  END IF;

  IF o.status IN ('created', 'rider_requested', 'no_rider_found') THEN
    PERFORM public.withdraw_pending_offers(o.id);
    UPDATE public.orders SET status = 'cancelled_by_customer', cancelled_at = now() WHERE id = o.id;
    INSERT INTO public.cancellation_events (order_id, cancelled_by, role, stage, counted)
    VALUES (o.id, uid, 'customer', 'before_accept', false);
  ELSIF o.status = 'accepted' THEN
    UPDATE public.orders SET status = 'cancelled_by_customer', cancelled_at = now() WHERE id = o.id;
    INSERT INTO public.cancellation_events (order_id, cancelled_by, role, stage, counted)
    VALUES (o.id, uid, 'customer', 'after_accept', true);
    PERFORM public.flag_after_late_cancels(uid, 'customer');
  ELSIF o.status = 'picked_up' THEN
    RAISE EXCEPTION 'After pickup, only Dispatch support can cancel';
  ELSE
    RAISE EXCEPTION 'This order can no longer be cancelled in the app';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.retry_dispatch(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  o public.orders%ROWTYPE;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND OR o.customer_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Order not found';
  END IF;
  IF o.status <> 'no_rider_found' THEN
    RAISE EXCEPTION 'This order is not waiting for a retry';
  END IF;
  PERFORM public.begin_dispatch(o.id);
END;
$$;

-- The assigned rider, for this order's customer (and admins): from acceptance until
-- delivery. Bank details only while the order is awaiting payment.
CREATE OR REPLACE FUNCTION public.get_order_rider(p_order_id uuid)
RETURNS TABLE (
  rider_name text,
  bike_make_model text,
  bike_colour text,
  plate_number text,
  bank_name text,
  account_number text,
  account_name text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  o public.orders%ROWTYPE;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND OR o.rider_id IS NULL
     OR NOT (o.customer_id = auth.uid() OR public.is_admin())
     OR o.status NOT IN ('accepted', 'picked_up') THEN
    RAISE EXCEPTION 'Rider details are not available for this order';
  END IF;
  RETURN QUERY
    SELECT rd.full_name, rd.bike_make_model, rd.bike_colour, rd.plate_number,
           CASE WHEN o.payment_status = 'awaiting_payment' THEN b.bank_name END,
           CASE WHEN o.payment_status = 'awaiting_payment' THEN b.account_number END,
           CASE WHEN o.payment_status = 'awaiting_payment' THEN coalesce(b.verified_name, b.account_name) END
      FROM public.rider_details rd
      LEFT JOIN public.rider_bank_accounts b ON b.id = o.payee_account_id
     WHERE rd.user_id = o.rider_id;
END;
$$;

-- The assigned rider's last position, for this order's customer: after acceptance
-- and until the order ends.
CREATE OR REPLACE FUNCTION public.get_assigned_rider_location(p_order_id uuid)
RETURNS TABLE (
  lat double precision,
  lng double precision,
  accuracy_m real,
  updated_at timestamptz,
  distance_to_pickup_m integer,
  distance_to_dropoff_m integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  o public.orders%ROWTYPE;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND OR o.rider_id IS NULL
     OR NOT (o.customer_id = auth.uid() OR public.is_admin())
     OR o.status NOT IN ('accepted', 'picked_up') THEN
    RAISE EXCEPTION 'The rider''s location is not available for this order';
  END IF;
  RETURN QUERY
    SELECT rl.lat, rl.lng, rl.accuracy_m, rl.updated_at,
           round(public.distance_between_m(rl.lat, rl.lng, o.pickup_lat, o.pickup_lng))::integer,
           round(public.distance_between_m(rl.lat, rl.lng, o.dropoff_lat, o.dropoff_lng))::integer
      FROM public.rider_locations rl
     WHERE rl.rider_id = o.rider_id;
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_order(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.retry_dispatch(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_order_rider(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_assigned_rider_location(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_order(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.retry_dispatch(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_order_rider(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_assigned_rider_location(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- create_order_from_quote: as in 20261125100000, plus the search starts at once.
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

  -- Look for a rider straight away (the sweep keeps trying if nobody is free yet).
  PERFORM public.begin_dispatch(new_id);
  RETURN new_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_order_from_quote(uuid, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_order_from_quote(uuid, text, text, text) TO authenticated, service_role;
