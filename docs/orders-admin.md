# Customer orders: setup and admin guide

Customers create deliveries in the app (SPEC.md §3.1, §10.2, §10.4, §10.6). Prices are
worked out **only on the server**:
1. The app searches places through the `places` Edge Function. The Google key never
   leaves Supabase.
2. The app asks the `quote-order` Edge Function for a price, sending only Google
   place ids, or the phone's location for "use my current location".
3. The function looks the places up, measures the **road distance with one Routes
   call** (driving), and the database prices and stores the quote.
4. The customer confirms, and `create_order_from_quote()` creates the order by
   copying every price, distance and address field from the quote.

Rules the database enforces, whatever the app does:
- **Price:** base fee + per-km rate **per started 100 m**, rounded **up** to the
  nearest ₦50. For example, 2.35 km = ₦600 + 24 × ₦60 = ₦2,040, which rounds up to
  **₦2,050**. Commission (`commission_bps`) is worked out at the same time and stored
  on the order.
- **Fallback distance:** if the Routes call fails, the distance is the straight line
  × 1.3, and the quote and order are marked `straight_line_fallback`
  (`orders.priced_with_fallback = true`).
- **Where:** pickup and drop-off must both be inside an **active service area**, and
  the distance must be no more than `max_order_distance_m`.
- **Quotes:** each one is held for `quote_valid_minutes`, can be used for one order
  only, and can't be changed.
- **Fixed orders:** once an order exists, its addresses, coordinates, price,
  commission and package **can't be changed by anyone**, the database owner included.
  A wrong address means cancelling and ordering again.
- **Who can write orders:**
  - customers can't insert or update orders directly; they create them from a quote
    and cancel them through functions;
  - the SQL Editor (database owner) and `service_role` can still insert orders
    and change their status, rider and payment status.
- **Cancelling:** a customer can cancel until a rider accepts. After that it is
  refused in the app. Counted late cancels and admin-only cancelling after pickup come
  with dispatch.
- **Limits:**
  - `quotes_per_hour` and `place_searches_per_hour` per user;
  - `google_calls_per_day` in total, by Lagos day, counted **before** any Google call;
  - `max_active_orders_per_customer` (default 2).
- **Phone numbers:** the receiver's name and phone are in `order_contacts`, which only
  the customer and admins can read. A rider gets the customer's and receiver's numbers
  only through `get_order_contact_details()`, after accepting and before delivery.
  No phone number is stored on `orders`.

> **Privacy:** the queries below show addresses and phone numbers. Use them only to
> run deliveries, and don't share screenshots of them.

---

## 0. Before deploying the migration (read-only, once)

Run this in the **SQL Editor** on the hosted project **before**
`supabase db push --remote`:

```sql
SELECT
  (SELECT max(version) FROM supabase_migrations.schema_migrations)   AS latest_migration,       -- must be 20261124120000
  (SELECT count(*) FROM public.app_settings)                         AS app_settings_rows,      -- must be 1
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'app_settings'
      AND column_name = 'commission_bps')                            AS commission_bps_present, -- must be 1
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'app_settings'
      AND column_name IN ('max_order_distance_m', 'quote_valid_minutes', 'quotes_per_hour',
                          'place_searches_per_hour', 'google_calls_per_day',
                          'max_active_orders_per_customer'))         AS new_settings_present,   -- must be 0
  (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname IN ('service_areas', 'api_usage', 'order_quotes', 'order_contacts'))
                                                                     AS new_tables_present,     -- must be 0
  (SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public' AND t.typname = 'order_distance_source')
                                                                     AS new_enum_present,       -- must be 0
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'orders'
      AND column_name IN ('quote_id', 'distance_m', 'distance_source', 'priced_with_fallback',
                          'base_fee_kobo', 'per_km_rate_kobo', 'commission_bps',
                          'package_description', 'pickup_place_id', 'dropoff_place_id'))
                                                                     AS new_order_columns,      -- must be 0
  (SELECT count(*) FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'orders'
      AND policyname IN ('orders_insert_as_customer', 'orders_update_participant_or_admin'))
                                                                     AS old_order_policies,     -- must be 2
  (SELECT base_fee_kobo::text || ' / ' || per_km_rate_kobo::text FROM public.app_settings)
                                                                     AS fees_now,               -- info: both become 60000
  (SELECT count(*) FROM public.orders)                               AS orders_total,           -- info: kept, and locked
  (SELECT count(*) FROM public.orders
    WHERE status IN ('created', 'rider_requested', 'accepted', 'picked_up'))
                                                                     AS orders_not_ended;       -- info
```

If any "must be" value differs, stop and ask before pushing.

Then deploy the database change:
```
supabase db push --remote --dry-run   # should list only 20261125100000_customer_order_creation.sql
supabase db push --remote
```

What changes straight away:
- `base_fee_kobo` and `per_km_rate_kobo` become **60000** (₦600 each).
- The Ede service area is created: centre 7.7333, 4.4333, radius 10 km. Check it with §4.
- Existing orders (for example the commission test orders) stay as they are, with the
  new columns empty. Their addresses and prices are locked too. Your commission test
  scripts (Script A and B) still work: the SQL Editor can still insert orders and
  change their status.

---

## 1. Google Cloud (once)

In the Google Cloud console, for the project that bills Dispatch:

1. **Turn on all three APIs** (APIs & Services → Library). All three are needed:
   - **Places API (New)**: place search and place details. Not the legacy "Places API".
   - **Routes API**: the road distance for each quote.
   - **Geocoding API**: turns "use my current location" into an address. Without it,
     quotes from the current location fail with "We could not find one of those
     places".
2. **Create an API key** (APIs & Services → Credentials → Create credentials → API key).
3. **Restrict it:**
   - **API restrictions:** "Restrict key", and tick only Places API (New), Routes API
     and Geocoding API.
   - **Application restrictions:** leave as **None**. The key is only used from
     Supabase Edge Functions, which don't have fixed IP addresses. It is never in the
     app or the repo, so keep it secret.
4. **Cap the spend:**
   - set a **budget with alerts** (Billing → Budgets & alerts);
   - optionally set per-API **quotas** (APIs & Services → each API → Quotas).

   Dispatch also has its own daily cap, `google_calls_per_day`.

## 2. Supabase secrets and function deploys (once, and after function changes)

```
supabase secrets set GOOGLE_MAPS_API_KEY=<paste the key here, never commit it>
supabase functions deploy places
supabase functions deploy quote-order
```

Check:
```
supabase secrets list            # GOOGLE_MAPS_API_KEY is listed (its value is hidden)
supabase functions list          # places and quote-order are ACTIVE
```

- Both functions require a signed-in user (`verify_jwt = true` in
  `supabase/config.toml`).
- They use the `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` that Supabase provides
  automatically.
- They log only short error codes (like `routes timeout (fallback)`), never addresses,
  coordinates or search text. To see them: Dashboard → Edge Functions → the function
  → Logs.

---

## 3. Settings

```sql
SELECT base_fee_kobo, per_km_rate_kobo, commission_bps, max_order_distance_m,
       quote_valid_minutes, quotes_per_hour, place_searches_per_hour,
       google_calls_per_day, max_active_orders_per_customer
FROM public.app_settings;
```

Examples (kobo: ₦1 = 100):

```sql
UPDATE public.app_settings SET base_fee_kobo = 60000, per_km_rate_kobo = 60000;  -- ₦600 + ₦600/km
UPDATE public.app_settings SET max_order_distance_m = 20000;          -- 20 km (1,000..100,000)
UPDATE public.app_settings SET quote_valid_minutes = 15;              -- 1..120
UPDATE public.app_settings SET quotes_per_hour = 20;                  -- per customer
UPDATE public.app_settings SET place_searches_per_hour = 300;         -- per customer
UPDATE public.app_settings SET google_calls_per_day = 2000;           -- all users, per Lagos day
UPDATE public.app_settings SET max_active_orders_per_customer = 2;    -- 1..20
```

- Price changes apply to **new quotes** only. Quotes and orders keep the prices they
  were made with.
- A quote can make up to **3** Google calls (two place lookups and one route), and
  each place search makes 1, so 2,000 calls a day is roughly 400 quotes plus 800
  searches. Keystrokes are batched by the app (at least 3 characters, 0.4 s pause).

## 4. The service area

**See it:**

```sql
SELECT name, center_lat, center_lng, radius_m, active, created_at
FROM public.service_areas
ORDER BY created_at;
```

**Adjust it.** To find a centre, right-click the spot in Google Maps and copy the
coordinates:

```sql
UPDATE public.service_areas
   SET center_lat = 7.7333, center_lng = 4.4333, radius_m = 10000   -- metres (500..50,000)
 WHERE name = 'Ede, Osun State';
```

**Check whether a point is inside:**

```sql
SELECT public.point_in_service_area(7.7450, 4.4450) AS inside;
```

- **More areas later:**
  `INSERT INTO public.service_areas (name, center_lat, center_lng, radius_m) VALUES (...)`.
  Pickup and drop-off must each be inside an active area.
- **Turn an area off:** `UPDATE public.service_areas SET active = false WHERE name = ...`.
- **Place search:** suggestions are limited to the **first active** area.

## 5. Recent quotes and fallback use

```sql
-- Last 50 quotes, newest first
SELECT q.created_at, p.phone AS customer, q.distance_m, q.distance_source,
       q.price_kobo, q.commission_kobo, (q.order_id IS NOT NULL) AS ordered,
       q.expires_at < now() AND q.order_id IS NULL AS expired_unused,
       q.pickup_address, q.dropoff_address
FROM public.order_quotes q
JOIN public.profiles p ON p.id = q.customer_id
ORDER BY q.created_at DESC
LIMIT 50;

-- How often the straight-line fallback was used, by Lagos day
SELECT (q.created_at AT TIME ZONE 'Africa/Lagos')::date AS day,
       count(*) AS quotes,
       count(*) FILTER (WHERE q.distance_source = 'straight_line_fallback') AS fallback,
       round(100.0 * count(*) FILTER (WHERE q.distance_source = 'straight_line_fallback') / count(*), 1) AS fallback_pct,
       count(*) FILTER (WHERE q.order_id IS NOT NULL) AS became_orders
FROM public.order_quotes q
GROUP BY 1
ORDER BY 1 DESC
LIMIT 30;
```

A sudden rise in fallback use usually means the Routes API isn't enabled, the key
was restricted wrongly, or billing has stopped. The function logs show
`routes 403` or similar.

## 6. Google API usage by day (from `api_usage`)

Every place search and quote is counted **before** Google is called. `google_calls`
is the most it could cost: 1 per search, 3 per quote.

```sql
-- Per Lagos day: requests and paid Google calls, against the daily cap
SELECT (u.created_at AT TIME ZONE 'Africa/Lagos')::date AS day,
       count(*) FILTER (WHERE u.kind = 'place_search') AS place_searches,
       count(*) FILTER (WHERE u.kind = 'quote')        AS quotes,
       sum(u.google_calls)                              AS google_calls,
       (SELECT google_calls_per_day FROM public.app_settings) AS daily_cap
FROM public.api_usage u
GROUP BY 1
ORDER BY 1 DESC
LIMIT 30;

-- Today's heaviest users (Lagos day)
SELECT p.phone, count(*) AS requests, sum(u.google_calls) AS google_calls
FROM public.api_usage u
JOIN public.profiles p ON p.id = u.user_id
WHERE u.created_at >= date_trunc('day', now() AT TIME ZONE 'Africa/Lagos') AT TIME ZONE 'Africa/Lagos'
GROUP BY p.phone
ORDER BY google_calls DESC
LIMIT 20;
```

Requests refused by a limit are **not** counted, because they never reach Google.
These counts are Dispatch's own estimate; Google's billing page is the real bill.

---

## 7. Testing orders before dispatch exists

Dispatch (finding a rider) is the next feature. Until then, a new order waits as
`created` ("Searching for a rider" in the app). Use this in the SQL Editor to move a
test order along. Use test phone numbers only.

**Find the order:**

```sql
SELECT o.id, o.status, o.price_kobo, o.commission_kobo, o.distance_m, o.priced_with_fallback,
       o.pickup_address, o.dropoff_address, o.created_at
FROM public.orders o
JOIN public.profiles p ON p.id = o.customer_id
WHERE p.phone = '2348000000102'        -- the test customer (no "+")
ORDER BY o.created_at DESC
LIMIT 5;
```

**Move it along, one step at a time.** Run each block separately and check the app
after each:

```sql
-- 1. Assign a verified test rider and accept (the app now shows "A rider is on the way";
--    the customer can no longer cancel in the app)
UPDATE public.orders
   SET rider_id = (SELECT id FROM public.profiles WHERE phone = '2348000000101'),  -- the test rider
       status = 'accepted'
 WHERE id = '<order id>';

-- 2. Picked up
UPDATE public.orders SET status = 'picked_up' WHERE id = '<order id>';

-- 3. Payment confirmed and delivered. This charges the rider's commission
--    (the commission ledger trigger), using the commission fixed at quote time.
UPDATE public.orders SET payment_status = 'paid', status = 'delivered' WHERE id = '<order id>';
```

**Check the rider can get the phone numbers after acceptance.** In the SQL Editor
(as admin) this always works. In the app it will be wired in with dispatch.

```sql
SELECT * FROM public.get_order_contact_details('<order id>');
```

**Check the commission it charged:**

```sql
SELECT e.type, e.amount_kobo, e.balance_after_kobo, c.reference_code, c.trip_count, c.status
FROM public.commission_entries e
JOIN public.commission_cycles c ON c.id = e.cycle_id
WHERE e.order_id = '<order id>';
```

**Clean up** test riders' commission afterwards with the commission cleanup script
(Script B).

**If something goes wrong:** you can't edit an order's address or price. Set the
status to a cancellation instead:

```sql
UPDATE public.orders SET status = 'cancelled_by_customer' WHERE id = '<order id>';
```
