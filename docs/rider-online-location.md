# Rider online/offline and live location

How it works:
- An **approved** rider with an **active** rider role, a **verified bank account**
  (see `rider-bank-account-admin.md`) and **no commission due** (see
  `commission-admin.md`) sees an Online/Offline switch on home. The database refuses
  everyone else, whatever the app does.
- While online, the app sends the rider's position to `rider_locations` (one row per
  rider: the current position only):
  - after moving at least 50 m, at most every 30 s;
  - and at least every 2 minutes while standing still (a heartbeat).
- `updated_at` is set by the server, so a phone cannot fake freshness.
- A rider with no update for `app_settings.rider_stale_after_minutes` (default **5**)
  is **stale**: treated as offline. A pg_cron job (below) sets stale riders offline
  every minute.
- Going offline deletes the rider's location row. This covers every way of going
  offline:
  - the rider turns the switch off;
  - suspension of the rider role;
  - KYC rejection;
  - the stale sweep.
- Who can read a location: only the rider themselves and admins. Customers cannot,
  not even with an order. Customer access comes with dispatch, limited to accepted
  orders.
- Retention: no location history is kept. Nothing older than the stale window
  exists for online riders, and nothing at all exists for offline riders.

## Foreground-only limitation (must stay visible to riders)

This version sends location **only while Dispatch is open on screen**. Updates stop
when the rider:
- locks the phone;
- switches apps;
- or closes the app.

After the stale window, they are set offline.

**Any build given to riders must keep showing this clearly.** The online card says:
"Keep Dispatch open while you are online…". Do not remove or hide that notice until
background location (its own feature, with an EAS build and the Play Store
declaration) has shipped. Riders who don't know will think they are online and miss
deliveries.

---

## 0. Before deploying this migration (read-only, once)

Run this in the **SQL Editor** on the hosted project **before**
`supabase db push`:

```sql
SELECT
  (SELECT count(*) FROM public.app_settings)                           AS app_settings_rows,        -- must be 1
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema = 'public'
      AND (table_name, column_name) IN (('app_settings', 'rider_stale_after_minutes'),
                                        ('rider_details', 'online_since'),
                                        ('rider_locations', 'accuracy_m')))   AS new_columns_present,      -- must be 0
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('expire_stale_riders', 'rider_stale_cutoff',
                        'clear_rider_location_when_offline', 'stamp_rider_online_since')) AS new_functions_present, -- must be 0
  (SELECT count(*) FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'rider_locations'
      AND policyname IN ('rider_locations_select_own_assigned_or_admin',
                         'rider_locations_insert_own', 'rider_locations_update_own')) AS old_policies_present,     -- must be 3
  (SELECT count(*) FROM pg_trigger WHERE tgname = 'rider_locations_touch')  AS touch_trigger_present,    -- must be 1
  (SELECT max(version) FROM supabase_migrations.schema_migrations)     AS latest_migration,         -- must be 20261122100000
  (SELECT count(*) FROM public.rider_details WHERE is_online)          AS riders_online_now;        -- for information
```

If any value differs from the comment, stop and ask before pushing. The migration
drops the three old policies and the trigger by name, so it fails if they are
missing.

Then deploy:
```
supabase db push
```

---

## 1. Turn on the stale sweep (pg_cron, once)

**Enable the extension.** Use either route:
- **Database → Extensions**: search `pg_cron` and switch it on. Keep the default
  schema.
- **Integrations → Cron**: click **Enable pg_cron**.

**Schedule the job** in the **SQL Editor**. It runs every minute. Re-running this
updates the same job; it does not create a second one:

```sql
SELECT cron.schedule(
  'expire-stale-riders',
  '* * * * *',
  $$SELECT public.expire_stale_riders()$$
);
```

**Confirm the job exists:**

```sql
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'expire-stale-riders';
```

You should see one row with `active = true`.

**See recent runs:**

```sql
SELECT r.start_time, r.end_time, r.status, r.return_message
FROM cron.job_run_details r
JOIN cron.job j ON j.jobid = r.jobid
WHERE j.jobname = 'expire-stale-riders'
ORDER BY r.start_time DESC
LIMIT 20;
```

Reading the results:
- `status` should be `succeeded`. `return_message` is just `1 row`; it does not
  show how many riders were expired.
- A `failed` row shows the error in `return_message`.

**Optional housekeeping.** pg_cron keeps a row per run: about 1,440 a day for this
job. To trim the history weekly, schedule a second job:

```sql
SELECT cron.schedule(
  'trim-cron-history',
  '0 3 * * 0',
  $$DELETE FROM cron.job_run_details WHERE end_time < now() - interval '7 days'$$
);
```

**To stop the sweep:**
```sql
SELECT cron.unschedule('expire-stale-riders');
```

Without the job, the rule still applies: stale riders will be filtered out by
dispatch (below). But `is_online` stays `true` and their last position stays in the
table until they go offline.

---

## 2. Settings

The stale window is in minutes, between 1 and 60:

```sql
UPDATE public.app_settings SET rider_stale_after_minutes = 5;
```

Keep it well above 2 minutes, the app's heartbeat. Otherwise riders who are standing
still get set offline.

## 3. Admin queries

Online riders, when they were last heard from, and whether they are stale:

```sql
SELECT p.phone, rd.full_name, rd.online_since, rl.updated_at AS last_location_at,
       rl.accuracy_m,
       COALESCE(rl.updated_at, rd.online_since) < public.rider_stale_cutoff() AS stale
FROM public.rider_details rd
JOIN public.profiles p ON p.id = rd.user_id
LEFT JOIN public.rider_locations rl ON rl.rider_id = rd.user_id
WHERE rd.is_online
ORDER BY last_location_at DESC NULLS LAST;
```

To run the sweep by hand (this **changes data**: stale riders go offline):

```sql
SELECT public.expire_stale_riders() AS riders_set_offline;
```

Privacy:
- Do not copy rider positions out of the dashboard.
- Do not share screenshots that show them.

## 4. Dispatch

Dispatch is built: see `dispatch-admin.md`. It uses the rule below (a fresh location,
not just `is_online`) in `rider_can_take_job()`.


When picking riders, never rely on `is_online` alone. Also require a fresh location,
so a stale rider is never offered an order between sweeps:

```sql
... FROM public.rider_details rd
JOIN public.rider_locations rl ON rl.rider_id = rd.user_id
JOIN public.user_roles ur ON ur.user_id = rd.user_id AND ur.role = 'rider' AND ur.status = 'active'
WHERE rd.is_online
  AND rd.kyc_status = 'approved'
  AND rl.updated_at >= public.rider_stale_cutoff()
```

Dispatch is also where customer read access to `rider_locations` comes back: only
for the customer's own order, and only from `accepted` onwards.
