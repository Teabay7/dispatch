# Dispatch: setup, admin and test guide

Dispatch finds a rider for each new order. It all runs **in the database**, so it
doesn't depend on anyone's phone staying open:

- **Starting a search:**
  - an order created in the app starts searching at once;
  - an order inserted in the SQL Editor as `created` is picked up by the **sweep**
    within about 10 seconds.
- **Who gets the offer:** the **nearest eligible rider** within `dispatch_max_radius_m`
  of the pickup. Eligible means all of these:
  - online, with a location sent within the stale window;
  - KYC approved, with an active rider role;
  - a **verified bank account**;
  - **no commission due**;
  - **no active job** and no other pending offer.
- **One offer at a time** per order and per rider. Each offer lasts
  `offer_timeout_seconds` (30 s).
- **Decline or timeout** move it to the next nearest rider. Nobody is offered the same
  order twice in one search.
- **When the search ends:** after `dispatch_max_attempts` offers, or
  `dispatch_search_minutes` with nobody eligible, the order becomes **no rider
  found**. The customer sees **Search again**, which starts a new search round.
- **Accepting is race-safe:**
  - an expired offer can't be accepted;
  - two riders can never both be assigned;
  - a rider can have only **one active job**, enforced by a database index.

  Accepting also fixes the rider's verified bank account as the order's payee.
- **Job steps:** the rider marks **arrived at pickup**, then **picked up**. Delivery
  and payment confirmation come in a later feature; for now, move the order on in SQL
  (§6).
- **Cancelling** (SPEC §10.6):
  - **Customer:** free until a rider accepts. After acceptance and before pickup it's
    allowed but **counted**, and `customer_late_cancel_flag_after` (3) late cancels
    open a review flag. After pickup it's refused.
  - **Rider:** can cancel after accepting and before pickup, with a listed reason.
    It's **counted**, and `rider_late_cancel_flag_after` (3) opens a review flag. The
    order goes back to searching, and that rider is never offered it again.
  - **After pickup:** only an admin can cancel (§4).
- **What each side sees** (only through server functions):
  - **Riders:** an offer shows the area, the distance and direction to pickup, the
    trip and the price, with **no address**. After accepting they see the addresses,
    plus the customer's and receiver's phone numbers until delivery.
  - **Customers:** after acceptance they see the rider's name, bike and plate, and the
    rider's location (distance from pickup or drop-off, with a Maps link) until the
    order ends. They see the rider's **bank details only while the order is awaiting
    payment**.
- **No numbers in records:** phone numbers, addresses and account numbers never go
  into offers, cancellation records, order events, review flags, errors or logs.
  Cancellation reasons with 7 or more digits in a row are refused.
- **No push notifications yet:** riders get offers only while the app is open on
  screen and they're online. The app says so.

> **Privacy:** some queries below show addresses or phone numbers. Use them only to
> run deliveries, and don't share screenshots of them.

---

## 0. Before deploying the migration (read-only, once)

Run this in the **SQL Editor** on the hosted project **before**
`supabase db push --remote`:

```sql
SELECT
  (SELECT max(version) FROM supabase_migrations.schema_migrations)   AS latest_migration,          -- must be 20261125100000
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'app_settings'
      AND column_name IN ('offer_timeout_seconds', 'dispatch_max_attempts', 'dispatch_max_radius_m',
                          'dispatch_search_minutes', 'customer_late_cancel_flag_after',
                          'rider_late_cancel_flag_after'))           AS new_settings_present,      -- must be 0
  (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname IN ('dispatch_offers', 'cancellation_events', 'admin_review_flags'))
                                                                     AS new_tables_present,        -- must be 0
  (SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public' AND t.typname IN ('dispatch_offer_status', 'cancel_stage'))
                                                                     AS new_enums_present,         -- must be 0
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'orders'
      AND column_name IN ('dispatch_round', 'dispatch_started_at', 'accepted_at', 'arrived_pickup_at',
                          'picked_up_at', 'cancelled_at', 'payee_account_id'))
                                                                     AS new_order_columns,         -- must be 0
  (SELECT count(*) FROM (SELECT rider_id FROM public.orders
                          WHERE rider_id IS NOT NULL AND status IN ('accepted', 'picked_up')
                          GROUP BY rider_id HAVING count(*) > 1) x)  AS riders_with_2_active_jobs, -- must be 0
  (SELECT count(*) FROM pg_extension WHERE extname = 'pg_cron')      AS pg_cron_installed,         -- must be 1
  (SELECT count(*) FROM public.orders WHERE status IN ('created', 'rider_requested'))
                                                                     AS orders_waiting_now,        -- info: the sweep will start/continue them
  (SELECT count(*) FROM public.orders WHERE status IN ('accepted', 'picked_up'))
                                                                     AS orders_with_rider_now;     -- info
```

If any "must be" value differs, stop and ask before pushing. In particular:
- **`riders_with_2_active_jobs` above 0:** the one-job-per-rider index can't be
  created. Find and end the extra jobs first.
- **`orders_waiting_now` above 0:** these orders (for example old test orders) will
  start searching as soon as the sweep is scheduled. Cancel them first if you don't
  want that (§7).

Then deploy:
```
supabase db push --remote --dry-run   # should list only 20261126100000_dispatch.sql
supabase db push --remote
```

---

## 1. Schedule the dispatch sweep (pg_cron, once)

pg_cron is already enabled for the stale-rider sweep. In the **SQL Editor**:

```sql
SELECT cron.schedule(
  'dispatch-sweep',
  '10 seconds',
  $$SELECT public.run_dispatch_sweep()$$
);
```

Running it again updates the same job; it doesn't add a second one.

**Confirm the job:**

```sql
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname IN ('dispatch-sweep', 'expire-stale-riders');
```

You should see `dispatch-sweep` with schedule `10 seconds` and `active = true`.

**See recent runs:**

```sql
SELECT r.start_time, r.end_time, r.status, r.return_message
FROM cron.job_run_details r
JOIN cron.job j ON j.jobid = r.jobid
WHERE j.jobname = 'dispatch-sweep'
ORDER BY r.start_time DESC
LIMIT 20;
```

`status` should be `succeeded`. When nothing is searching, the sweep stops after two
cheap checks.

**Trim the run history.** This job runs about **8,640 times a day**, so trim the
history **daily**, not weekly. This replaces the optional weekly `trim-cron-history`
job from the stale-rider guide, and covers every job:

```sql
SELECT cron.unschedule('trim-cron-history')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'trim-cron-history');

SELECT cron.schedule(
  'trim-cron-history-daily',
  '0 3 * * *',
  $$DELETE FROM cron.job_run_details WHERE end_time < now() - interval '2 days'$$
);
```

**To stop dispatching** (for example during maintenance). New orders still start at
once in the app, but timeouts won't move on until you schedule the sweep again:

```sql
SELECT cron.unschedule('dispatch-sweep');
```

---

## 2. Settings

```sql
SELECT offer_timeout_seconds, dispatch_max_attempts, dispatch_max_radius_m, dispatch_search_minutes,
       customer_late_cancel_flag_after, rider_late_cancel_flag_after
FROM public.app_settings;

UPDATE public.app_settings SET offer_timeout_seconds = 30;           -- 10..300
UPDATE public.app_settings SET dispatch_max_attempts = 5;            -- 1..30 offers per search
UPDATE public.app_settings SET dispatch_max_radius_m = 5000;         -- 500..50,000 m from pickup
UPDATE public.app_settings SET dispatch_search_minutes = 10;         -- 1..60 minutes
UPDATE public.app_settings SET customer_late_cancel_flag_after = 3;  -- 1..20
UPDATE public.app_settings SET rider_late_cancel_flag_after = 3;     -- 1..20
```

## 3. Watching dispatch

```sql
-- Orders searching or with a rider, with their current offer
SELECT o.id, o.status, o.dispatch_round, o.dispatch_started_at, o.accepted_at, o.arrived_pickup_at,
       o.picked_up_at, rp.full_name AS rider,
       d.attempt_no, d.distance_to_pickup_m, d.expires_at, rd2.full_name AS offered_to
FROM public.orders o
LEFT JOIN public.rider_details rp ON rp.user_id = o.rider_id
LEFT JOIN public.dispatch_offers d ON d.order_id = o.id AND d.status = 'pending'
LEFT JOIN public.rider_details rd2 ON rd2.user_id = d.rider_id
WHERE o.status IN ('created', 'rider_requested', 'accepted', 'picked_up', 'no_rider_found')
ORDER BY o.created_at DESC;

-- Every offer for one order
SELECT d.round_no, d.attempt_no, rd.full_name, d.distance_to_pickup_m, d.offered_at, d.expires_at,
       d.status, d.responded_at
FROM public.dispatch_offers d JOIN public.rider_details rd ON rd.user_id = d.rider_id
WHERE d.order_id = '<order id>'
ORDER BY d.round_no, d.attempt_no;

-- Riders who could get an offer right now
SELECT rd.full_name, rl.updated_at AS last_location_at, public.rider_is_dispatchable(rd.user_id) AS dispatchable
FROM public.rider_details rd
LEFT JOIN public.rider_locations rl ON rl.rider_id = rd.user_id
WHERE rd.is_online
ORDER BY dispatchable DESC, rd.full_name;
```

## 4. Admin cancel, and review flags

**Cancel any order that hasn't ended**, including after pickup. It isn't counted
against anyone. Never put phone or account numbers in the reason; the database
refuses them.

```sql
SELECT public.admin_cancel_order(
  p_order_id     => '<order id>',
  p_on_behalf_of => 'customer',          -- or 'rider'
  p_reason       => 'Customer called support: package no longer needed',
  p_recorded_by  => '<your name>'
);
```

**Open review flags** (late cancels):

```sql
SELECT f.id AS flag_id, f.role, f.reason, f.created_at, p.phone,
       (SELECT count(*) FROM public.cancellation_events c
         WHERE c.cancelled_by = f.user_id AND c.role = f.role AND c.counted) AS counted_cancels
FROM public.admin_review_flags f
JOIN public.profiles p ON p.id = f.user_id
WHERE f.resolved_at IS NULL
ORDER BY f.created_at;
```

**Resolve a flag** after you've looked into it, for example by phoning the user. To
take action, suspend their customer or rider role as in the KYC guide.

```sql
SELECT public.resolve_review_flag('<flag_id>', 'Phoned the customer; genuine emergencies', '<your name>');
```

A new flag opens if they keep cancelling, because the count isn't reset.

---

## 5. Testing without Google (SQL Editor)

Google setup isn't needed. Test orders are inserted directly in the SQL Editor.

**Before you start:**
1. **Labels:** everything below is labelled **TEST** and placed inside the **Ede
   service area**. Run §7 when you're done.
2. **Sign in each test phone number in the app once first**, so the user exists:
   - one customer;
   - two riders, for example `+234 800 000 0101` and `+234 800 000 0103`.
3. **About phone locations:** a rider whose app is online sends the phone's **real
   GPS position** every few minutes, which replaces the TEST location below. So:
   - **riders on phones physically in Ede** get offers normally;
   - **outside Ede**, use the SQL-only riders below, or tell me and I'll prepare a
     clearly labelled temporary TEST service area around you, with its removal step.

### 5a. Make two TEST riders ready (approved, verified bank, online in Ede)

This only fills in what's missing, so riders who did KYC and bank details in the app
keep theirs.

```sql
DO $$
DECLARE
  -- Test rider phone numbers (no "+"), and where each one stands in Ede.
  riders text[][] := ARRAY[
    ARRAY['2348000000101', '7.7377', '4.4360'],   -- about 300 m north of the test pickup
    ARRAY['2348000000103', '7.7422', '4.4360']    -- about 800 m north of the test pickup
  ];
  r text[];
  uid uuid;
BEGIN
  FOREACH r SLICE 1 IN ARRAY riders LOOP
    SELECT id INTO uid FROM public.profiles WHERE phone = r[1];
    IF uid IS NULL THEN
      RAISE EXCEPTION 'Sign in with % in the app first', r[1];
    END IF;
    INSERT INTO public.user_roles (user_id, role) VALUES (uid, 'rider') ON CONFLICT DO NOTHING;
    INSERT INTO public.rider_details (user_id, full_name, bike_make_model, bike_colour, plate_number,
                                      id_photo_path, selfie_path, kyc_status)
    VALUES (uid, 'TEST Rider ' || right(r[1], 3), 'TEST Bike', 'Red', 'TEST-' || right(r[1], 3),
            uid || '/test-id.jpg', uid || '/test-selfie.jpg', 'approved')
    ON CONFLICT (user_id) DO NOTHING;
    UPDATE public.rider_details SET kyc_status = 'approved' WHERE user_id = uid AND kyc_status <> 'approved';
    IF NOT public.rider_has_verified_bank_account(uid) THEN
      INSERT INTO public.rider_bank_accounts (rider_id, bank_name, account_number, account_name, name_match,
                                              status, verified_name, verified_name_match, recorded_by, reviewed_at)
      VALUES (uid, 'TEST BANK', '9' || lpad(right(r[1], 9), 9, '0'), 'TEST RIDER ' || right(r[1], 3), 'match',
              'verified', 'TEST RIDER ' || right(r[1], 3), 'match', 'dispatch test setup', now());
    END IF;
    UPDATE public.rider_details SET is_online = true WHERE user_id = uid;
    INSERT INTO public.rider_locations (rider_id, lat, lng) VALUES (uid, r[2]::float8, r[3]::float8)
    ON CONFLICT (rider_id) DO UPDATE SET lat = EXCLUDED.lat, lng = EXCLUDED.lng;
  END LOOP;
END $$;

-- Check: both should be dispatchable
SELECT p.phone, rd.full_name, public.rider_is_dispatchable(rd.user_id) AS dispatchable
FROM public.rider_details rd JOIN public.profiles p ON p.id = rd.user_id
WHERE p.phone IN ('2348000000101', '2348000000103');
```

Riders put online in SQL go **stale after `rider_stale_after_minutes` (5)**, and the
stale sweep sets them offline. Re-run 5a to refresh them, or use phones in Ede.

**If a rider isn't dispatchable,** the usual causes are:
- commission due: see the commission guide, Script B;
- an active job still open;
- the location is stale.

### 5b. Create a TEST order in Ede (`created`)

```sql
INSERT INTO public.orders
  (customer_id, status, pickup_address, pickup_lat, pickup_lng, dropoff_address, dropoff_lat, dropoff_lng,
   price_kobo, commission_kobo, distance_m, distance_source, package_description)
SELECT id, 'created',
       'TEST ORDER (dispatch test) pickup, Ede', 7.7350, 4.4360,
       'TEST ORDER (dispatch test) drop-off, Ede', 7.7450, 4.4450,
       205000, 30750, 2350, 'routes', 'TEST package'
FROM public.profiles WHERE phone = '2348000000102'     -- the TEST customer
RETURNING id;
```

- **The receiver's phone:** add one so the rider's contact details show a receiver:
  ```sql
  INSERT INTO public.order_contacts (order_id, receiver_name, receiver_phone)
  VALUES ('<order id>', 'TEST Receiver', '2348000000104');
  ```
- **When it starts:** the sweep starts it within about 10 seconds. To start it at once:
  `SELECT public.start_dispatch('<order id>');`
- **Where to see it:** the nearest TEST rider sees the offer card in the app within
  5 seconds, as long as the app is open and online. Use §3 to watch it.

### 5c. Act as a rider in SQL (when you have only one phone)

Wrap the call in a `DO` block that signs in as that rider for the transaction:

```sql
-- Rider 0103 declines their current offer (the order moves to the next nearest rider)
DO $$
BEGIN
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', (SELECT id FROM public.profiles WHERE phone = '2348000000103'),
                      'role', 'authenticated')::text, true);
  PERFORM public.decline_offer((SELECT id FROM public.dispatch_offers
                                 WHERE rider_id = (SELECT id FROM public.profiles WHERE phone = '2348000000103')
                                   AND status = 'pending'));
END $$;
```

- **Accepting instead:** replace `decline_offer` with `accept_offer`.
- **Arriving and picking up:** use `mark_arrived_at_pickup('<order id>')` and
  `mark_picked_up('<order id>')`.
- **A timeout:** just don't answer. After 30 s, the next sweep (within 10 s) moves the
  offer on.

## 6. Finishing a TEST job (until delivery confirmation exists)

```sql
-- Show the customer the rider's bank details (payment due)
UPDATE public.orders SET payment_status = 'awaiting_payment' WHERE id = '<order id>';

-- Delivered and paid: this also charges the rider's commission (the commission guide)
UPDATE public.orders SET payment_status = 'paid', status = 'delivered' WHERE id = '<order id>';
```

## 7. Clean up TEST data

This cancels every TEST order that hasn't ended and takes the TEST riders offline,
which also deletes their location. Nothing is deleted from append-only tables:
offers, cancellation records and ledger entries stay as history. For the riders'
commission from delivered test orders, use the commission guide's Script B.

```sql
DO $$
DECLARE
  o record;
  n integer := 0;
BEGIN
  FOR o IN
    SELECT id FROM public.orders
     WHERE pickup_address LIKE 'TEST ORDER (dispatch test)%'
       AND status IN ('created', 'rider_requested', 'accepted', 'picked_up', 'no_rider_found')
  LOOP
    PERFORM public.admin_cancel_order(o.id, 'customer', 'Cleanup of dispatch test data', 'dispatch test cleanup');
    n := n + 1;
  END LOOP;

  UPDATE public.rider_details SET is_online = false
   WHERE is_online
     AND (full_name LIKE 'TEST %'
          OR user_id IN (SELECT id FROM public.profiles WHERE phone IN ('2348000000101', '2348000000103')));

  RAISE NOTICE 'Cancelled % TEST order(s); TEST riders are offline', n;
END $$;

-- Check: nothing TEST is searching or online
SELECT
  (SELECT count(*) FROM public.orders WHERE pickup_address LIKE 'TEST ORDER (dispatch test)%'
     AND status IN ('created', 'rider_requested', 'accepted', 'picked_up', 'no_rider_found')) AS test_orders_open,  -- expect 0
  (SELECT count(*) FROM public.rider_details WHERE is_online AND full_name LIKE 'TEST %')    AS test_riders_online; -- expect 0
```
