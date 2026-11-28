-- Delivery handover, payment confirmation, disputes and the unpaid-order block
-- (SPEC 3, 5, 10.4, 10.5, 10.9, 10.11; payment-model-change D5-D8).
--
--   * After pickup the rider marks arrival at the drop-off. Their last location must be
--     fresh and near the drop-off (an admin can override). The order then awaits payment.
--   * The customer pays the rider by bank transfer and may report it ("I've paid"). That
--     is only a claim: it never changes payment_status.
--   * Only the rider (or an admin) confirms payment. Confirming creates a 4-digit
--     delivery PIN that only the customer can read. The rider hands over and marks the
--     order delivered with the receiver's PIN. Nothing is delivered unpaid (D6).
--   * After awaiting_payment_refuse_after_minutes the rider can mark the order refused
--     (payment_failed), unless the customer has reported paying: then the rider raises
--     a dispute and an admin decides. Refusals count as abandons; a review flag opens
--     after customer_unpaid_flag_after.
--   * Disputes are text only, one open per order, raised during payment or within
--     dispute_window_days after the order ends. An admin resolves them; a dispute found
--     false counts against whoever raised it, and a flag opens after
--     false_dispute_flag_after.
--   * A customer with an open dispute raised by a rider, or a delivered order that is
--     not paid, cannot place new orders.
--   * Commission: unchanged. The existing orders_accrue_commission trigger counts an
--     order that ends delivered, or ends any other way with payment confirmed.
--   * No phone or account numbers in disputes, admin actions, flags, events or errors.
--     Every function here sets an empty search_path.

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
ALTER TABLE public.app_settings
  ADD COLUMN awaiting_payment_refuse_after_minutes integer NOT NULL DEFAULT 15
    CONSTRAINT app_settings_refuse_after_range CHECK (awaiting_payment_refuse_after_minutes BETWEEN 5 AND 120),
  ADD COLUMN customer_unpaid_flag_after integer NOT NULL DEFAULT 2
    CONSTRAINT app_settings_customer_unpaid_flag_range CHECK (customer_unpaid_flag_after BETWEEN 1 AND 20),
  ADD COLUMN false_dispute_flag_after integer NOT NULL DEFAULT 3
    CONSTRAINT app_settings_false_dispute_flag_range CHECK (false_dispute_flag_after BETWEEN 1 AND 20),
  ADD COLUMN delivery_pin_max_attempts integer NOT NULL DEFAULT 5
    CONSTRAINT app_settings_pin_attempts_range CHECK (delivery_pin_max_attempts BETWEEN 3 AND 10),
  ADD COLUMN dispute_window_days integer NOT NULL DEFAULT 7
    CONSTRAINT app_settings_dispute_window_range CHECK (dispute_window_days BETWEEN 1 AND 30),
  ADD COLUMN dropoff_arrival_radius_m integer NOT NULL DEFAULT 500
    CONSTRAINT app_settings_dropoff_radius_range CHECK (dropoff_arrival_radius_m BETWEEN 100 AND 5000);

-- ---------------------------------------------------------------------------
-- orders: delivery and payment fields (written only by the functions below)
-- ---------------------------------------------------------------------------
ALTER TABLE public.orders
  ADD COLUMN arrived_dropoff_at timestamptz,
  ADD COLUMN customer_reported_paid_at timestamptz,
  ADD COLUMN payment_confirmed_at timestamptz,
  ADD COLUMN payment_confirmed_by text CHECK (payment_confirmed_by IN ('rider', 'admin')),
  ADD COLUMN delivered_at timestamptz,
  ADD COLUMN payment_failed_at timestamptz,
  -- For the transfer narration. Six hex characters: never a long run of digits.
  ADD COLUMN payment_reference text
    GENERATED ALWAYS AS ('DSP-' || upper(substr(replace(id::text, '-', ''), 1, 6))) STORED;

-- ---------------------------------------------------------------------------
-- Delivery PINs: reachable only through functions (no client policies)
-- ---------------------------------------------------------------------------
CREATE TABLE public.order_delivery_pins (
  order_id uuid PRIMARY KEY REFERENCES public.orders (id),
  pin text NOT NULL CHECK (pin ~ '^[0-9]{4}$'),
  wrong_attempts integer NOT NULL DEFAULT 0 CHECK (wrong_attempts >= 0),
  locked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.order_delivery_pins ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.order_delivery_pins FROM anon, authenticated;

CREATE TRIGGER order_delivery_pins_no_delete
  BEFORE DELETE ON public.order_delivery_pins
  FOR EACH ROW EXECUTE FUNCTION public.reject_ledger_mutation();
CREATE TRIGGER order_delivery_pins_no_truncate
  BEFORE TRUNCATE ON public.order_delivery_pins
  FOR EACH STATEMENT EXECUTE FUNCTION public.reject_ledger_mutation();

-- ---------------------------------------------------------------------------
-- Payment disputes
-- ---------------------------------------------------------------------------
CREATE TABLE public.order_payment_disputes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders (id),
  raised_by uuid NOT NULL REFERENCES public.profiles (id),
  raised_as text NOT NULL CHECK (raised_as IN ('customer', 'rider')),
  reason text NOT NULL CHECK (reason IN ('paid_not_confirmed', 'payment_not_received', 'wrong_amount', 'other')),
  details text CHECK (details IS NULL OR (length(details) <= 500 AND details !~ '[0-9]{7,}')),
  -- Set when an admin opened it on the user's behalf.
  opened_by_admin text CHECK (opened_by_admin IS NULL OR opened_by_admin !~ '[0-9]{7,}'),
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved', 'withdrawn')),
  outcome text CHECK (outcome IN ('paid', 'not_paid')),
  found_false boolean NOT NULL DEFAULT false,
  resolution_note text CHECK (resolution_note IS NULL OR resolution_note !~ '[0-9]{7,}'),
  resolved_by text CHECK (resolved_by IS NULL OR resolved_by !~ '[0-9]{7,}'),
  resolved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT order_payment_disputes_resolution CHECK (
    (status = 'open' AND outcome IS NULL AND resolved_at IS NULL AND NOT found_false)
    OR (status = 'resolved' AND outcome IS NOT NULL AND resolved_at IS NOT NULL
        AND btrim(coalesce(resolved_by, '')) <> '')
    OR (status = 'withdrawn' AND outcome IS NULL AND resolved_at IS NOT NULL AND NOT found_false)
  )
);

CREATE UNIQUE INDEX order_payment_disputes_one_open
  ON public.order_payment_disputes (order_id) WHERE status = 'open';
CREATE INDEX order_payment_disputes_raised_by_idx ON public.order_payment_disputes (raised_by);

ALTER TABLE public.order_payment_disputes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.order_payment_disputes FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.order_payment_disputes FROM authenticated;
CREATE POLICY order_payment_disputes_select_admin
  ON public.order_payment_disputes FOR SELECT TO authenticated USING (public.is_admin());

CREATE TRIGGER order_payment_disputes_no_delete
  BEFORE DELETE ON public.order_payment_disputes
  FOR EACH ROW EXECUTE FUNCTION public.reject_ledger_mutation();
CREATE TRIGGER order_payment_disputes_no_truncate
  BEFORE TRUNCATE ON public.order_payment_disputes
  FOR EACH STATEMENT EXECUTE FUNCTION public.reject_ledger_mutation();

-- ---------------------------------------------------------------------------
-- Admin actions on orders (append-only audit: who, why)
-- ---------------------------------------------------------------------------
CREATE TABLE public.order_admin_actions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders (id),
  action text NOT NULL CHECK (action IN ('arrived_dropoff', 'confirm_payment', 'complete_delivery', 'open_dispute')),
  note text NOT NULL CHECK (btrim(note) <> '' AND length(note) <= 500 AND note !~ '[0-9]{7,}'),
  recorded_by text NOT NULL CHECK (btrim(recorded_by) <> '' AND recorded_by !~ '[0-9]{7,}'),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX order_admin_actions_order_idx ON public.order_admin_actions (order_id);

ALTER TABLE public.order_admin_actions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.order_admin_actions FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.order_admin_actions FROM authenticated;
CREATE POLICY order_admin_actions_select_admin
  ON public.order_admin_actions FOR SELECT TO authenticated USING (public.is_admin());

CREATE TRIGGER order_admin_actions_no_update
  BEFORE UPDATE OR DELETE ON public.order_admin_actions
  FOR EACH ROW EXECUTE FUNCTION public.reject_ledger_mutation();
CREATE TRIGGER order_admin_actions_no_truncate
  BEFORE TRUNCATE ON public.order_admin_actions
  FOR EACH STATEMENT EXECUTE FUNCTION public.reject_ledger_mutation();

-- ---------------------------------------------------------------------------
-- Review flags: two new reasons
-- ---------------------------------------------------------------------------
ALTER TABLE public.admin_review_flags DROP CONSTRAINT admin_review_flags_reason_check;
ALTER TABLE public.admin_review_flags ADD CONSTRAINT admin_review_flags_reason_check
  CHECK (reason IN ('late_cancels', 'unpaid_abandons', 'false_disputes'));

-- ---------------------------------------------------------------------------
-- Helpers (not callable by API roles)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_admin_caller()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(auth.role(), 'service_role') = 'service_role' OR public.is_admin();
$$;

-- Opens a review flag unless one is already open for this user, role and reason.
CREATE OR REPLACE FUNCTION public.open_review_flag(p_user_id uuid, p_role text, p_reason text)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  INSERT INTO public.admin_review_flags (user_id, role, reason)
  SELECT p_user_id, p_role, p_reason
   WHERE NOT EXISTS (SELECT 1 FROM public.admin_review_flags
                      WHERE user_id = p_user_id AND role = p_role AND reason = p_reason AND resolved_at IS NULL);
$$;

-- Abandons: orders the customer left unpaid that ended as refused.
CREATE OR REPLACE FUNCTION public.flag_after_unpaid_abandons(p_customer_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF (SELECT count(*) FROM public.orders
       WHERE customer_id = p_customer_id AND status = 'payment_failed' AND payment_status = 'failed')
     >= (SELECT customer_unpaid_flag_after FROM public.app_settings WHERE id = 1) THEN
    PERFORM public.open_review_flag(p_customer_id, 'customer', 'unpaid_abandons');
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.flag_after_false_disputes(p_user_id uuid, p_role text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF (SELECT count(*) FROM public.order_payment_disputes
       WHERE raised_by = p_user_id AND raised_as = p_role AND found_false)
     >= (SELECT false_dispute_flag_after FROM public.app_settings WHERE id = 1) THEN
    PERFORM public.open_review_flag(p_user_id, p_role, 'false_disputes');
  END IF;
END;
$$;

-- A delivered order that is not paid, or an open dispute raised by a rider.
CREATE OR REPLACE FUNCTION public.customer_unsettled_order(p_customer_id uuid)
RETURNS TABLE (reason text, order_id uuid)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT x.reason, x.order_id FROM (
    SELECT 'rider_dispute'::text AS reason, o.id AS order_id, d.created_at AS at
      FROM public.order_payment_disputes d JOIN public.orders o ON o.id = d.order_id
     WHERE o.customer_id = p_customer_id AND d.status = 'open' AND d.raised_as = 'rider'
    UNION ALL
    SELECT 'unpaid_delivery', o.id, o.delivered_at
      FROM public.orders o
     WHERE o.customer_id = p_customer_id AND o.status IN ('delivered', 'completed') AND o.payment_status <> 'paid'
  ) x
  ORDER BY x.at
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.customer_has_unsettled_order(p_customer_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (SELECT 1 FROM public.customer_unsettled_order(p_customer_id));
$$;

-- When an order ended (for the dispute window).
CREATE OR REPLACE FUNCTION public.order_ended_at(o public.orders)
RETURNS timestamptz
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT CASE
    WHEN o.status IN ('delivered', 'completed') THEN o.delivered_at
    WHEN o.status = 'payment_failed' THEN o.payment_failed_at
    ELSE NULL
  END;
$$;

-- Can this user (as customer or rider) raise a dispute on this order now?
CREATE OR REPLACE FUNCTION public.can_raise_dispute(o public.orders, p_role text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT NOT EXISTS (SELECT 1 FROM public.order_payment_disputes WHERE order_id = o.id AND status = 'open')
     AND (
       -- During payment
       (o.status = 'picked_up' AND o.payment_status = 'awaiting_payment'
         AND (p_role = 'rider' OR o.customer_reported_paid_at IS NOT NULL))
       -- After the order ends, within the window
       OR (public.order_ended_at(o) IS NOT NULL
           AND now() <= public.order_ended_at(o)
                        + make_interval(days => (SELECT dispute_window_days FROM public.app_settings WHERE id = 1))
           AND (p_role = 'customer' OR o.status IN ('delivered', 'completed')))
     );
$$;

CREATE OR REPLACE FUNCTION public.new_delivery_pin()
RETURNS text
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
  -- gen_random_uuid() is cryptographically random; three of its bytes give 0..16.7M.
  SELECT lpad(((get_byte(b, 0) * 65536 + get_byte(b, 1) * 256 + get_byte(b, 2)) % 10000)::text, 4, '0')
    FROM (SELECT uuid_send(gen_random_uuid()) AS b) r;
$$;

-- Marks an order paid and creates its PIN if it is still waiting for handover.
-- Caller holds the order row lock.
CREATE OR REPLACE FUNCTION public.apply_payment_confirmed(p_order_id uuid, p_by text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  o public.orders%ROWTYPE;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_order_id;
  IF o.payment_status = 'paid' THEN
    RETURN;
  END IF;
  UPDATE public.orders
     SET payment_status = 'paid', payment_confirmed_at = now(), payment_confirmed_by = p_by
   WHERE id = o.id;
  IF o.status = 'picked_up' THEN
    INSERT INTO public.order_delivery_pins (order_id, pin)
    VALUES (o.id, public.new_delivery_pin())
    ON CONFLICT (order_id) DO NOTHING;
  END IF;
  -- Money arrived: any open dispute on this order is closed (not counted against anyone).
  UPDATE public.order_payment_disputes SET status = 'withdrawn', resolved_at = now()
   WHERE order_id = o.id AND status = 'open';
END;
$$;

-- Ends an order unpaid (refused). Counts as an abandon. Caller holds the row lock.
CREATE OR REPLACE FUNCTION public.apply_payment_refused(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_customer uuid;
BEGIN
  UPDATE public.orders
     SET status = 'payment_failed', payment_status = 'failed', payment_failed_at = now()
   WHERE id = p_order_id
  RETURNING customer_id INTO v_customer;
  UPDATE public.order_payment_disputes SET status = 'withdrawn', resolved_at = now()
   WHERE order_id = p_order_id AND status = 'open';
  PERFORM public.flag_after_unpaid_abandons(v_customer);
END;
$$;

CREATE OR REPLACE FUNCTION public.check_admin_text(p_note text, p_recorded_by text)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF btrim(coalesce(p_note, '')) = '' OR btrim(coalesce(p_recorded_by, '')) = '' THEN
    RAISE EXCEPTION 'A note and who is recording it are required';
  END IF;
  IF p_note ~ '[0-9]{7,}' OR p_recorded_by ~ '[0-9]{7,}' THEN
    RAISE EXCEPTION 'Do not put phone or account numbers in the note';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.is_admin_caller() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.open_review_flag(uuid, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.flag_after_unpaid_abandons(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.flag_after_false_disputes(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.customer_unsettled_order(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.customer_has_unsettled_order(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.order_ended_at(public.orders) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.can_raise_dispute(public.orders, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.new_delivery_pin() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.apply_payment_confirmed(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.apply_payment_refused(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.check_admin_text(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.customer_has_unsettled_order(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- Rider
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mark_arrived_at_dropoff(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  o public.orders%ROWTYPE;
  loc public.rider_locations%ROWTYPE;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND OR o.rider_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Job not found';
  END IF;
  IF o.status <> 'picked_up' OR o.arrived_dropoff_at IS NOT NULL THEN
    RAISE EXCEPTION 'You can mark arrival at the drop-off only once, after pickup';
  END IF;

  SELECT * INTO loc FROM public.rider_locations WHERE rider_id = o.rider_id;
  IF NOT FOUND OR loc.updated_at < public.rider_stale_cutoff() THEN
    RAISE EXCEPTION 'We can''t see your current location. Turn on location, keep the app open and try again';
  END IF;
  IF public.distance_between_m(loc.lat, loc.lng, o.dropoff_lat, o.dropoff_lng)
     > (SELECT dropoff_arrival_radius_m FROM public.app_settings WHERE id = 1) THEN
    RAISE EXCEPTION 'You are not at the drop-off yet. Move closer and try again';
  END IF;

  UPDATE public.orders SET arrived_dropoff_at = now(), payment_status = 'awaiting_payment' WHERE id = o.id;
END;
$$;

-- Only after seeing the money in the rider's own bank app or bank SMS. Repeating is a no-op.
CREATE OR REPLACE FUNCTION public.confirm_payment_received(p_order_id uuid)
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
  IF o.status = 'picked_up' AND o.payment_status = 'paid' THEN
    RETURN;
  END IF;
  IF o.status <> 'picked_up' OR o.payment_status <> 'awaiting_payment' THEN
    RAISE EXCEPTION 'You can confirm payment only at the drop-off, while payment is due';
  END IF;
  PERFORM public.apply_payment_confirmed(o.id, 'rider');
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_payment_refused(p_order_id uuid)
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
  IF o.status <> 'picked_up' OR o.payment_status <> 'awaiting_payment' THEN
    RAISE EXCEPTION 'You can mark an order unpaid only while payment is due';
  END IF;
  IF o.customer_reported_paid_at IS NOT NULL THEN
    RAISE EXCEPTION 'The customer says they have paid. Report a problem instead, and Dispatch will decide';
  END IF;
  -- No arrival time (set outside the app): the wait never starts; an admin decides.
  IF o.arrived_dropoff_at IS NULL OR now() < o.arrived_dropoff_at
             + make_interval(mins => (SELECT awaiting_payment_refuse_after_minutes FROM public.app_settings WHERE id = 1)) THEN
    RAISE EXCEPTION 'Give the customer more time to pay before marking the order unpaid';
  END IF;
  PERFORM public.apply_payment_refused(o.id);
END;
$$;

-- Wrong PINs are counted, so this returns a result instead of raising for them.
CREATE OR REPLACE FUNCTION public.complete_delivery(p_order_id uuid, p_pin text)
RETURNS TABLE (result text, attempts_left integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  o public.orders%ROWTYPE;
  p public.order_delivery_pins%ROWTYPE;
  v_max integer;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND OR o.rider_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Job not found';
  END IF;
  SELECT delivery_pin_max_attempts INTO v_max FROM public.app_settings WHERE id = 1;
  IF o.status IN ('delivered', 'completed') THEN
    RETURN QUERY SELECT 'delivered'::text, NULL::integer;
    RETURN;
  END IF;
  IF o.status <> 'picked_up' OR o.payment_status <> 'paid' THEN
    RAISE EXCEPTION 'Confirm the payment before handing over';
  END IF;

  SELECT * INTO p FROM public.order_delivery_pins WHERE order_id = o.id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Ask Dispatch support to complete this delivery';
  END IF;
  IF p.locked_at IS NOT NULL THEN
    RETURN QUERY SELECT 'locked'::text, 0;
    RETURN;
  END IF;
  IF p_pin IS NULL OR p_pin !~ '^[0-9]{4}$' OR p_pin <> p.pin THEN
    UPDATE public.order_delivery_pins
       SET wrong_attempts = wrong_attempts + 1,
           locked_at = CASE WHEN wrong_attempts + 1 >= v_max THEN now() END
     WHERE order_id = o.id
    RETURNING * INTO p;
    IF p.locked_at IS NOT NULL THEN
      RETURN QUERY SELECT 'locked'::text, 0;
    ELSE
      RETURN QUERY SELECT 'wrong_pin'::text, v_max - p.wrong_attempts;
    END IF;
    RETURN;
  END IF;

  UPDATE public.orders SET status = 'delivered', delivered_at = now() WHERE id = o.id;
  RETURN QUERY SELECT 'delivered'::text, NULL::integer;
END;
$$;

-- What the rider's job screen needs about payment and handover.
CREATE OR REPLACE FUNCTION public.get_job_payment_info(p_order_id uuid)
RETURNS TABLE (
  refuse_available_at timestamptz,
  pin_attempts_left integer,
  pin_locked boolean,
  open_dispute_raised_as text,
  can_raise_dispute boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  o public.orders%ROWTYPE;
  s public.app_settings%ROWTYPE;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND OR o.rider_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Job not found';
  END IF;
  SELECT * INTO s FROM public.app_settings WHERE id = 1;
  RETURN QUERY
    SELECT CASE WHEN o.arrived_dropoff_at IS NULL THEN NULL
                ELSE o.arrived_dropoff_at + make_interval(mins => s.awaiting_payment_refuse_after_minutes) END,
           s.delivery_pin_max_attempts - coalesce(p.wrong_attempts, 0),
           p.locked_at IS NOT NULL,
           (SELECT d.raised_as FROM public.order_payment_disputes d WHERE d.order_id = o.id AND d.status = 'open'),
           public.can_raise_dispute(o, 'rider')
      FROM (SELECT 1) one
      LEFT JOIN public.order_delivery_pins p ON p.order_id = o.id;
END;
$$;

REVOKE ALL ON FUNCTION public.mark_arrived_at_dropoff(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.confirm_payment_received(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.mark_payment_refused(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.complete_delivery(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_job_payment_info(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_arrived_at_dropoff(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_payment_received(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_payment_refused(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.complete_delivery(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_job_payment_info(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- Customer
-- ---------------------------------------------------------------------------
-- "I've paid": only a claim. Repeating is a no-op.
CREATE OR REPLACE FUNCTION public.report_payment_sent(p_order_id uuid)
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
  IF o.status <> 'picked_up' OR o.payment_status <> 'awaiting_payment' THEN
    RAISE EXCEPTION 'Payment is not due on this order';
  END IF;
  IF o.customer_reported_paid_at IS NULL THEN
    UPDATE public.orders SET customer_reported_paid_at = now() WHERE id = o.id;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_delivery_pin(p_order_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
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
  IF o.status <> 'picked_up' OR o.payment_status <> 'paid' THEN
    RAISE EXCEPTION 'The delivery PIN shows after the rider confirms your payment';
  END IF;
  RETURN (SELECT pin FROM public.order_delivery_pins WHERE order_id = o.id);
END;
$$;

-- For a paid order: what was paid, to whom (account number masked) and when.
CREATE OR REPLACE FUNCTION public.get_order_receipt(p_order_id uuid)
RETURNS TABLE (
  order_status public.order_status,
  price_kobo bigint,
  payment_reference text,
  payment_confirmed_at timestamptz,
  payment_confirmed_by text,
  delivered_at timestamptz,
  rider_name text,
  plate_number text,
  bank_name text,
  account_masked text,
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
  IF NOT FOUND OR NOT (o.customer_id = auth.uid() OR public.is_admin()) THEN
    RAISE EXCEPTION 'Order not found';
  END IF;
  IF o.payment_status <> 'paid' THEN
    RAISE EXCEPTION 'There is no receipt until the payment is confirmed';
  END IF;
  RETURN QUERY
    SELECT o.status, o.price_kobo, o.payment_reference, o.payment_confirmed_at, o.payment_confirmed_by,
           o.delivered_at, rd.full_name, rd.plate_number, b.bank_name,
           CASE WHEN b.account_number IS NULL THEN NULL ELSE '••••' || right(b.account_number, 4) END,
           coalesce(b.verified_name, b.account_name)
      FROM public.rider_details rd
      LEFT JOIN public.rider_bank_accounts b ON b.id = o.payee_account_id
     WHERE rd.user_id = o.rider_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_my_order_block()
RETURNS TABLE (reason text, order_id uuid)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT u.reason, u.order_id FROM public.customer_unsettled_order(auth.uid()) u WHERE auth.uid() IS NOT NULL;
$$;

REVOKE ALL ON FUNCTION public.report_payment_sent(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_delivery_pin(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_order_receipt(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_my_order_block() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.report_payment_sent(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_delivery_pin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_order_receipt(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_order_block() TO authenticated;

-- ---------------------------------------------------------------------------
-- Disputes (customer or rider)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.raise_payment_dispute(p_order_id uuid, p_reason text, p_details text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  uid uuid := auth.uid();
  o public.orders%ROWTYPE;
  v_role text;
  v_details text := NULLIF(regexp_replace(btrim(coalesce(p_details, '')), '\s+', ' ', 'g'), '');
  new_id uuid;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND OR uid IS NULL OR uid NOT IN (o.customer_id, coalesce(o.rider_id, o.customer_id)) THEN
    RAISE EXCEPTION 'Order not found';
  END IF;
  v_role := CASE WHEN uid = o.rider_id THEN 'rider' ELSE 'customer' END;
  IF p_reason IS NULL OR p_reason NOT IN ('paid_not_confirmed', 'payment_not_received', 'wrong_amount', 'other') THEN
    RAISE EXCEPTION 'Choose a reason';
  END IF;
  IF v_details IS NOT NULL AND length(v_details) > 500 THEN
    RAISE EXCEPTION 'Keep the details shorter';
  END IF;
  -- Also catches numbers typed with spaces, dots or dashes ("0803 123 4567").
  IF regexp_replace(v_details, '[\s.-]', '', 'g') ~ '[0-9]{7,}' THEN
    RAISE EXCEPTION 'Do not put phone or account numbers in the details';
  END IF;
  IF EXISTS (SELECT 1 FROM public.order_payment_disputes WHERE order_id = o.id AND status = 'open') THEN
    RAISE EXCEPTION 'A problem is already open on this order. Dispatch will contact you';
  END IF;
  IF NOT public.can_raise_dispute(o, v_role) THEN
    RAISE EXCEPTION 'You can''t report a payment problem on this order now';
  END IF;

  INSERT INTO public.order_payment_disputes (order_id, raised_by, raised_as, reason, details)
  VALUES (o.id, uid, v_role, p_reason, v_details)
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

-- The latest dispute on an order, for its customer or rider (without the other side's text).
CREATE OR REPLACE FUNCTION public.get_order_dispute(p_order_id uuid)
RETURNS TABLE (
  can_raise boolean,
  dispute_status text,
  raised_as text,
  reason text,
  outcome text,
  created_at timestamptz,
  resolved_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  uid uuid := auth.uid();
  o public.orders%ROWTYPE;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND OR uid IS NULL OR uid NOT IN (o.customer_id, coalesce(o.rider_id, o.customer_id)) THEN
    RAISE EXCEPTION 'Order not found';
  END IF;
  RETURN QUERY
    SELECT public.can_raise_dispute(o, CASE WHEN uid = o.rider_id THEN 'rider' ELSE 'customer' END),
           d.status, d.raised_as, d.reason, d.outcome, d.created_at, d.resolved_at
      FROM (SELECT 1) one
      LEFT JOIN LATERAL (SELECT * FROM public.order_payment_disputes x
                          WHERE x.order_id = o.id ORDER BY x.created_at DESC LIMIT 1) d ON true;
END;
$$;

REVOKE ALL ON FUNCTION public.raise_payment_dispute(uuid, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_order_dispute(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.raise_payment_dispute(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_order_dispute(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- Admin (in the app as an admin, the server, or the SQL Editor)
-- ---------------------------------------------------------------------------
-- outcome 'paid': payment confirmed by admin (before handover a PIN is created; a
-- refused order becomes paid and counts as a trip). outcome 'not_paid': an order still
-- awaiting payment ends refused; a delivered order is marked failed (the customer is
-- blocked until it is settled). p_found_false counts the dispute against its raiser.
CREATE OR REPLACE FUNCTION public.resolve_payment_dispute(
  p_dispute_id uuid,
  p_outcome text,
  p_found_false boolean,
  p_note text,
  p_recorded_by text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  d public.order_payment_disputes%ROWTYPE;
  o public.orders%ROWTYPE;
BEGIN
  IF NOT public.is_admin_caller() THEN
    RAISE EXCEPTION 'Only an admin can resolve disputes';
  END IF;
  PERFORM public.check_admin_text(p_note, p_recorded_by);
  IF p_outcome IS NULL OR p_outcome NOT IN ('paid', 'not_paid') THEN
    RAISE EXCEPTION 'The outcome must be paid or not_paid';
  END IF;

  SELECT * INTO d FROM public.order_payment_disputes WHERE id = p_dispute_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Dispute not found';
  END IF;
  SELECT * INTO o FROM public.orders WHERE id = d.order_id FOR UPDATE;
  SELECT * INTO d FROM public.order_payment_disputes WHERE id = p_dispute_id FOR UPDATE;
  IF d.status <> 'open' THEN
    RAISE EXCEPTION 'This dispute is not open';
  END IF;

  UPDATE public.order_payment_disputes
     SET status = 'resolved', outcome = p_outcome, found_false = coalesce(p_found_false, false),
         resolution_note = btrim(p_note), resolved_by = btrim(p_recorded_by), resolved_at = now()
   WHERE id = d.id;

  IF p_outcome = 'paid' THEN
    PERFORM public.apply_payment_confirmed(o.id, 'admin');
  ELSIF o.status = 'picked_up' AND o.payment_status = 'awaiting_payment' THEN
    PERFORM public.apply_payment_refused(o.id);
  ELSIF o.status IN ('delivered', 'completed') AND o.payment_status = 'paid' THEN
    UPDATE public.orders SET payment_status = 'failed' WHERE id = o.id;
  END IF;

  IF coalesce(p_found_false, false) THEN
    PERFORM public.flag_after_false_disputes(d.raised_by, d.raised_as);
  END IF;
END;
$$;

-- Settle an order later (for example the customer paid after delivery or after refusal).
CREATE OR REPLACE FUNCTION public.admin_confirm_payment(p_order_id uuid, p_note text, p_recorded_by text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  o public.orders%ROWTYPE;
BEGIN
  IF NOT public.is_admin_caller() THEN
    RAISE EXCEPTION 'Only an admin can confirm payment this way';
  END IF;
  PERFORM public.check_admin_text(p_note, p_recorded_by);
  SELECT * INTO o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND OR o.rider_id IS NULL THEN
    RAISE EXCEPTION 'Order not found';
  END IF;
  IF o.payment_status = 'paid' THEN
    RAISE EXCEPTION 'This order is already paid';
  END IF;
  IF NOT (o.status = 'picked_up' AND o.payment_status = 'awaiting_payment')
     AND o.status NOT IN ('delivered', 'completed', 'payment_failed') THEN
    RAISE EXCEPTION 'Payment can be confirmed only at or after the drop-off';
  END IF;
  INSERT INTO public.order_admin_actions (order_id, action, note, recorded_by)
  VALUES (o.id, 'confirm_payment', btrim(p_note), btrim(p_recorded_by));
  PERFORM public.apply_payment_confirmed(o.id, 'admin');
END;
$$;

-- The PIN is locked or the receiver can't be reached; the payment is confirmed.
CREATE OR REPLACE FUNCTION public.admin_complete_delivery(p_order_id uuid, p_note text, p_recorded_by text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  o public.orders%ROWTYPE;
BEGIN
  IF NOT public.is_admin_caller() THEN
    RAISE EXCEPTION 'Only an admin can complete a delivery this way';
  END IF;
  PERFORM public.check_admin_text(p_note, p_recorded_by);
  SELECT * INTO o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order not found';
  END IF;
  IF o.status <> 'picked_up' OR o.payment_status <> 'paid' THEN
    RAISE EXCEPTION 'Only a picked-up order with a confirmed payment can be completed';
  END IF;
  INSERT INTO public.order_admin_actions (order_id, action, note, recorded_by)
  VALUES (o.id, 'complete_delivery', btrim(p_note), btrim(p_recorded_by));
  UPDATE public.orders SET status = 'delivered', delivered_at = now() WHERE id = o.id;
END;
$$;

-- The rider is at the drop-off but their location can't confirm it.
CREATE OR REPLACE FUNCTION public.admin_mark_arrived_at_dropoff(p_order_id uuid, p_note text, p_recorded_by text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  o public.orders%ROWTYPE;
BEGIN
  IF NOT public.is_admin_caller() THEN
    RAISE EXCEPTION 'Only an admin can mark arrival this way';
  END IF;
  PERFORM public.check_admin_text(p_note, p_recorded_by);
  SELECT * INTO o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order not found';
  END IF;
  IF o.status <> 'picked_up' OR o.arrived_dropoff_at IS NOT NULL THEN
    RAISE EXCEPTION 'Arrival can be marked only once, after pickup';
  END IF;
  INSERT INTO public.order_admin_actions (order_id, action, note, recorded_by)
  VALUES (o.id, 'arrived_dropoff', btrim(p_note), btrim(p_recorded_by));
  UPDATE public.orders SET arrived_dropoff_at = now(), payment_status = 'awaiting_payment' WHERE id = o.id;
END;
$$;

-- For a rider (or customer) who reports a problem to support outside the app's windows,
-- for example after handover. Ignores the dispute window.
CREATE OR REPLACE FUNCTION public.admin_open_payment_dispute(
  p_order_id uuid,
  p_raised_as text,
  p_reason text,
  p_details text,
  p_recorded_by text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  o public.orders%ROWTYPE;
  v_raiser uuid;
  new_id uuid;
BEGIN
  IF NOT public.is_admin_caller() THEN
    RAISE EXCEPTION 'Only an admin can open a dispute this way';
  END IF;
  PERFORM public.check_admin_text(p_details, p_recorded_by);
  IF p_raised_as IS NULL OR p_raised_as NOT IN ('customer', 'rider') THEN
    RAISE EXCEPTION 'Open it for the customer or the rider';
  END IF;
  IF p_reason IS NULL OR p_reason NOT IN ('paid_not_confirmed', 'payment_not_received', 'wrong_amount', 'other') THEN
    RAISE EXCEPTION 'Choose a reason';
  END IF;
  SELECT * INTO o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND OR o.rider_id IS NULL THEN
    RAISE EXCEPTION 'Order not found';
  END IF;
  IF EXISTS (SELECT 1 FROM public.order_payment_disputes WHERE order_id = o.id AND status = 'open') THEN
    RAISE EXCEPTION 'A dispute is already open on this order';
  END IF;
  v_raiser := CASE p_raised_as WHEN 'rider' THEN o.rider_id ELSE o.customer_id END;
  INSERT INTO public.order_admin_actions (order_id, action, note, recorded_by)
  VALUES (o.id, 'open_dispute', btrim(p_details), btrim(p_recorded_by));
  INSERT INTO public.order_payment_disputes (order_id, raised_by, raised_as, reason, details, opened_by_admin)
  VALUES (o.id, v_raiser, p_raised_as, p_reason, btrim(p_details), btrim(p_recorded_by))
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_payment_dispute(uuid, text, boolean, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_confirm_payment(uuid, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_complete_delivery(uuid, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_mark_arrived_at_dropoff(uuid, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_open_payment_dispute(uuid, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolve_payment_dispute(uuid, text, boolean, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_confirm_payment(uuid, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_complete_delivery(uuid, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_mark_arrived_at_dropoff(uuid, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_open_payment_dispute(uuid, text, text, text, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Ordering: the unpaid-order block.
-- Replaces create_order_from_quote() from 20261126100000_dispatch.sql (same body,
-- plus the block check).
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
  IF public.customer_has_unsettled_order(uid) THEN
    RAISE EXCEPTION 'Settle your unpaid order before placing a new one';
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
