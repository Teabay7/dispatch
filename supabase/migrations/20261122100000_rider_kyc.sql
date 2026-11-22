-- Rider KYC (feature 2): rider_details fields, review rules, the "go online" rule,
-- and a private Storage bucket for ID photos and selfies.
--
-- BEFORE `supabase db push` to the hosted project, check rider_details is empty
-- (this migration adds NOT NULL columns):
--   SELECT count(*) AS rider_details_rows FROM public.rider_details;
-- It must return 0. If not, stop and ask.

-- ---------------------------------------------------------------------------
-- rider_details: KYC fields and review fields
-- ---------------------------------------------------------------------------
ALTER TABLE public.rider_details
  -- Name as submitted for KYC (what the admin checks against the ID). A snapshot:
  -- changing the profile name later does not change it.
  ADD COLUMN full_name text NOT NULL,
  ADD COLUMN bike_make_model text NOT NULL,
  ADD COLUMN bike_colour text NOT NULL,
  ADD COLUMN rejection_reason text,
  ADD COLUMN submitted_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN reviewed_at timestamptz,
  ADD COLUMN reviewed_by uuid REFERENCES public.profiles (id);

ALTER TABLE public.rider_details
  ALTER COLUMN id_photo_path SET NOT NULL,
  ALTER COLUMN selfie_path SET NOT NULL;

ALTER TABLE public.rider_details
  ADD CONSTRAINT rider_details_required_not_blank CHECK (
    btrim(full_name) <> ''
    AND btrim(bike_make_model) <> ''
    AND btrim(bike_colour) <> ''
    AND btrim(plate_number) <> ''
    AND btrim(id_photo_path) <> ''
    AND btrim(selfie_path) <> ''
  ),
  ADD CONSTRAINT rider_details_rejection_reason CHECK (
    (kyc_status = 'rejected' AND rejection_reason IS NOT NULL AND btrim(rejection_reason) <> '')
    OR (kyc_status <> 'rejected' AND rejection_reason IS NULL)
  ),
  ADD CONSTRAINT rider_details_online_requires_approval CHECK (
    NOT is_online OR kyc_status = 'approved'
  ),
  ADD CONSTRAINT rider_details_distinct_photos CHECK (id_photo_path <> selfie_path);

CREATE INDEX rider_details_pending_idx
  ON public.rider_details (submitted_at)
  WHERE kyc_status = 'pending';

-- ---------------------------------------------------------------------------
-- Helpers (SECURITY DEFINER; only callable from the triggers below)
-- ---------------------------------------------------------------------------

-- Is this user's rider role active? Checks the given user, not the caller, so it
-- is correct when an admin or the server updates someone else's row.
CREATE OR REPLACE FUNCTION public.rider_role_is_active(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles
    WHERE user_id = p_user_id
      AND role = 'rider'
      AND status = 'active'
  );
$$;

-- Is this path an uploaded file in the user's own folder of the rider-kyc bucket?
CREATE OR REPLACE FUNCTION public.is_own_kyc_file(p_user_id uuid, p_path text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p_path LIKE p_user_id::text || '/%'
     AND EXISTS (
       SELECT 1
       FROM storage.objects
       WHERE bucket_id = 'rider-kyc'
         AND name = p_path
     );
$$;

REVOKE ALL ON FUNCTION public.rider_role_is_active(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.is_own_kyc_file(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rider_role_is_active(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.is_own_kyc_file(uuid, text) TO service_role;

-- ---------------------------------------------------------------------------
-- rider_details rules (replaces the version from the data model migration)
--
-- Rider (from the app):
--   * creates their row once, as pending, with an active rider role and their own photos
--   * cannot change kyc_status, except rejected -> pending (resubmit), which needs an
--     active rider role and clears the rejection reason
--   * can change KYC details only when resubmitting; details are locked while
--     pending and after approval
--   * never sets rejection_reason, reviewed_at, reviewed_by or submitted_at
-- Admin / server (SQL editor, service role):
--   * changes kyc_status; reviewed_at / reviewed_by are recorded automatically
-- Everyone:
--   * is_online can only be turned on with KYC approved AND an active rider role;
--     a rider who loses either is taken offline
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

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.protect_rider_details() FROM PUBLIC, anon, authenticated;

-- The trigger itself (rider_details_protect) already exists and now runs this body.

-- Suspending someone's rider role takes them offline at once. Their customer role
-- is untouched.
CREATE OR REPLACE FUNCTION public.take_suspended_rider_offline()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.role = 'rider' AND NEW.status = 'suspended' THEN
    UPDATE public.rider_details
       SET is_online = false
     WHERE user_id = NEW.user_id
       AND is_online;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.take_suspended_rider_offline() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER user_roles_take_suspended_rider_offline
  AFTER UPDATE OF status ON public.user_roles
  FOR EACH ROW
  EXECUTE FUNCTION public.take_suspended_rider_offline();

-- ---------------------------------------------------------------------------
-- Existing SECURITY DEFINER functions: no EXECUTE for PUBLIC / anon.
-- is_admin and has_active_role are used inside RLS policies for signed-in users.
-- handle_new_user and log_order_event are trigger functions (no direct calls).
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.is_admin() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.has_active_role(public.app_role) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.has_active_role(public.app_role) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.handle_new_user() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.log_order_event() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Storage: private bucket for KYC photos. Files live at <user_id>/<file>.
-- Riders upload and read only their own folder; admins read everything.
-- No UPDATE or DELETE policies: files cannot be overwritten or removed from the app.
-- ---------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('rider-kyc', 'rider-kyc', false, 2097152, ARRAY['image/jpeg', 'image/png', 'image/webp'])
ON CONFLICT (id) DO UPDATE
  SET public = false,
      file_size_limit = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

CREATE POLICY rider_kyc_read_own_or_admin
  ON storage.objects FOR SELECT TO authenticated
  USING (
    bucket_id = 'rider-kyc'
    AND (
      (storage.foldername(name))[1] = (SELECT auth.uid())::text
      OR public.is_admin()
    )
  );

CREATE POLICY rider_kyc_upload_own_active_rider
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'rider-kyc'
    AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
    AND public.has_active_role('rider')
  );
