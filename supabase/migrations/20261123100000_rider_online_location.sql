-- Rider online/offline and live location (feature 3).
--
-- Before `supabase db push` on the hosted project, run the read-only check in
-- docs/rider-online-location.md ("Before deploying this migration").
--
-- What this does:
--   1. app_settings.rider_stale_after_minutes (default 5): a rider with no location
--      update for this long is treated as offline.
--   2. rider_details.online_since: when the rider last went online (server time).
--   3. rider_locations: server-set updated_at on insert AND update, accuracy_m,
--      index on updated_at.
--   4. Privacy: only the rider and admins can read a rider's location. Customer
--      access returns with dispatch, limited to accepted orders.
--   5. A rider can write their location only while online, approved and active.
--   6. Going offline (by the rider, suspension, rejection or the stale sweep)
--      deletes the rider's location row. Only the current position is kept.
--   7. expire_stale_riders(): sets stale riders offline. Scheduled with pg_cron as a
--      dashboard step (see the docs), not in this migration.

-- ---------------------------------------------------------------------------
-- 1. Setting
-- ---------------------------------------------------------------------------
ALTER TABLE public.app_settings
  ADD COLUMN rider_stale_after_minutes integer NOT NULL DEFAULT 5
    CONSTRAINT app_settings_rider_stale_after_minutes_range
    CHECK (rider_stale_after_minutes BETWEEN 1 AND 60);

-- ---------------------------------------------------------------------------
-- 2. online_since: set by the server whenever is_online turns on, cleared when off.
--    Runs after rider_details_protect (triggers fire in name order), so it sees the
--    final is_online value.
-- ---------------------------------------------------------------------------
ALTER TABLE public.rider_details ADD COLUMN online_since timestamptz;

-- Riders already online before this migration: give them the normal grace period.
-- (Runs before the stamp trigger exists, which would otherwise keep the old NULL.)
UPDATE public.rider_details SET online_since = now() WHERE is_online AND online_since IS NULL;

CREATE OR REPLACE FUNCTION public.stamp_rider_online_since()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF NOT NEW.is_online THEN
    NEW.online_since := NULL;
  ELSIF TG_OP = 'INSERT' OR NOT OLD.is_online THEN
    NEW.online_since := now();
  ELSE
    NEW.online_since := OLD.online_since; -- clients cannot move it
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.stamp_rider_online_since() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER rider_details_stamp_online_since
  BEFORE INSERT OR UPDATE ON public.rider_details
  FOR EACH ROW
  EXECUTE FUNCTION public.stamp_rider_online_since();

-- ---------------------------------------------------------------------------
-- 3. rider_locations: the server sets updated_at on insert too, so a client
--    cannot send a future time and never look stale.
-- ---------------------------------------------------------------------------
ALTER TABLE public.rider_locations
  ADD COLUMN accuracy_m real
    CONSTRAINT rider_locations_accuracy_m_non_negative CHECK (accuracy_m IS NULL OR accuracy_m >= 0);

DROP TRIGGER rider_locations_touch ON public.rider_locations;
CREATE TRIGGER rider_locations_touch
  BEFORE INSERT OR UPDATE ON public.rider_locations
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_rider_location();

CREATE INDEX rider_locations_updated_at_idx ON public.rider_locations (updated_at);

-- ---------------------------------------------------------------------------
-- 4 + 5. Policies
-- ---------------------------------------------------------------------------
-- Replaces a policy that let a customer read the rider's location from
-- 'rider_requested', before the rider had accepted.
DROP POLICY rider_locations_select_own_assigned_or_admin ON public.rider_locations;
CREATE POLICY rider_locations_select_own_or_admin
  ON public.rider_locations FOR SELECT TO authenticated
  USING (rider_id = (SELECT auth.uid()) OR public.is_admin());

DROP POLICY rider_locations_insert_own ON public.rider_locations;
CREATE POLICY rider_locations_insert_own_while_online
  ON public.rider_locations FOR INSERT TO authenticated
  WITH CHECK (
    rider_id = (SELECT auth.uid())
    AND public.has_active_role('rider')
    AND EXISTS (
      SELECT 1 FROM public.rider_details rd
      WHERE rd.user_id = (SELECT auth.uid())
        AND rd.kyc_status = 'approved'
        AND rd.is_online
    )
  );

DROP POLICY rider_locations_update_own ON public.rider_locations;
CREATE POLICY rider_locations_update_own_while_online
  ON public.rider_locations FOR UPDATE TO authenticated
  USING (rider_id = (SELECT auth.uid()))
  WITH CHECK (
    rider_id = (SELECT auth.uid())
    AND public.has_active_role('rider')
    AND EXISTS (
      SELECT 1 FROM public.rider_details rd
      WHERE rd.user_id = (SELECT auth.uid())
        AND rd.kyc_status = 'approved'
        AND rd.is_online
    )
  );
-- No DELETE policy: the row is removed by the trigger below.

-- ---------------------------------------------------------------------------
-- 6. Going offline deletes the current position (no location history is kept).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.clear_rider_location_when_offline()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF OLD.is_online AND NOT NEW.is_online THEN
    DELETE FROM public.rider_locations WHERE rider_id = NEW.user_id;
  END IF;
  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION public.clear_rider_location_when_offline() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER rider_details_clear_location_when_offline
  AFTER UPDATE ON public.rider_details -- not "OF is_online": the protect trigger can turn it off
  FOR EACH ROW
  EXECUTE FUNCTION public.clear_rider_location_when_offline();

-- ---------------------------------------------------------------------------
-- 7. Stale riders
-- A rider is "last seen" at their latest location update, or when they went online
-- if no location has arrived yet. Older than the cutoff = stale = treated as offline.
-- Dispatch must also filter on this at query time, so stale riders are never
-- offered orders between sweeps.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rider_stale_cutoff()
RETURNS timestamptz
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT now() - make_interval(mins => s.rider_stale_after_minutes)
  FROM public.app_settings s
  WHERE s.id = 1;
$$;
REVOKE ALL ON FUNCTION public.rider_stale_cutoff() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rider_stale_cutoff() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.expire_stale_riders()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  cutoff timestamptz := public.rider_stale_cutoff();
  expired integer;
BEGIN
  UPDATE public.rider_details rd
     SET is_online = false
   WHERE rd.is_online
     AND COALESCE(
           (SELECT rl.updated_at FROM public.rider_locations rl WHERE rl.rider_id = rd.user_id),
           rd.online_since,
           '-infinity'::timestamptz
         ) < cutoff;
  GET DIAGNOSTICS expired = ROW_COUNT;
  RETURN expired;
END;
$$;
REVOKE ALL ON FUNCTION public.expire_stale_riders() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.expire_stale_riders() TO service_role;
