# Delivery and payment: setup, admin and test guide

After pickup, the order moves like this. Every step goes through a database function;
nobody can change payment status directly.

1. **Arrival at the drop-off.** The rider taps "I've arrived at the drop-off". The
   database checks that the rider's last location is fresh (within
   `rider_stale_after_minutes`) and within `dropoff_arrival_radius_m` (500 m) of the
   drop-off. If not, the rider sees a fixed message, and an admin can override (§4).
   The order now **awaits payment**.
2. **The customer pays the rider** by bank transfer, into the account shown in the app,
   with the order's payment reference (`DSP-XXXXXX`) in the note. They may tap
   **"I've paid"**: that is only a claim and changes nothing about payment.
3. **Only the rider confirms payment**, after seeing it in their own bank app or bank
   SMS. An admin can also confirm (§4).
4. Confirming creates a **4-digit delivery PIN** that only the customer can see. The
   customer gives it to the receiver.
5. **Handover.** The rider enters the receiver's PIN and the order is **delivered**.
   After `delivery_pin_max_attempts` (5) wrong PINs, handover locks and an admin
   completes it (§4). Nothing is ever handed over unpaid.

**When the customer doesn't pay:**
- After `awaiting_payment_refuse_after_minutes` (15) the rider can tap "Customer didn't
  pay". The order ends **payment_failed** and the rider keeps the package (they take it
  back to the pickup point). It counts as an **abandon**; after
  `customer_unpaid_flag_after` (2) abandons a review flag opens.
- **If the customer tapped "I've paid", the rider can't mark it unpaid.** They report a
  payment problem instead, and an admin decides.

**Payment problems (disputes):** text only, one open per order.
- **Customer:** after tapping "I've paid", or on a refused or delivered order within
  `dispute_window_days` (7).
- **Rider:** while payment is due, or on a delivered order within the window. After
  handover the rider has no in-app screen yet, so support opens it for them (§4).
- An admin resolves each one as **paid** or **not paid** (§4). A dispute found false
  counts against whoever raised it; after `false_dispute_flag_after` (3) a review flag
  opens.

**The unpaid-order block:** a customer can't place new orders while they have:
- an **open dispute raised by a rider**, or
- a **delivered order that is not paid** (only possible after a dispute resolved as not
  paid).

The app shows a red banner, and the database refuses the order. A refused order does
**not** block (the goods weren't handed over); it counts as an abandon instead.

**Commission:** unchanged. The existing trigger charges a trip when an order ends
delivered, or ends any other way with the payment confirmed (for example refused, then
found paid by an admin). A refused, unpaid order is not charged.

**No numbers in records:** phone and account numbers never go into disputes, admin
actions, flags, order events or error messages. Dispute details and admin notes with 7
or more digits in a row (ignoring spaces, dots and dashes in disputes) are refused. The
customer's receipt shows only the last 4 digits of the rider's account.

> **Privacy:** some queries below show addresses or phone numbers. Use them only to run
> deliveries, and don't share screenshots of them.

---

## 0. Before deploying the migration (read-only, once)

Run this in the **SQL Editor** on the hosted project **before** `supabase db push --remote`:

```sql
SELECT
  (SELECT max(version) FROM supabase_migrations.schema_migrations)               AS latest_migration,         -- must be 20261126100000
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'app_settings'
      AND column_name IN ('awaiting_payment_refuse_after_minutes', 'customer_unpaid_flag_after',
                          'false_dispute_flag_after', 'delivery_pin_max_attempts',
                          'dispute_window_days', 'dropoff_arrival_radius_m'))           AS new_settings_present,     -- must be 0
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'orders'
      AND column_name IN ('arrived_dropoff_at', 'customer_reported_paid_at', 'payment_confirmed_at',
                          'payment_confirmed_by', 'delivered_at', 'payment_failed_at',
                          'payment_reference'))                                          AS new_order_columns,        -- must be 0
  (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname IN ('order_delivery_pins', 'order_payment_disputes', 'order_admin_actions'))
                                                                                         AS new_tables_present,       -- must be 0
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('mark_arrived_at_dropoff', 'confirm_payment_received', 'mark_payment_refused',
                        'complete_delivery', 'get_job_payment_info', 'report_payment_sent', 'get_delivery_pin',
                        'get_order_receipt', 'get_my_order_block', 'raise_payment_dispute', 'get_order_dispute',
                        'resolve_payment_dispute', 'admin_confirm_payment', 'admin_complete_delivery',
                        'admin_mark_arrived_at_dropoff', 'admin_open_payment_dispute', 'is_admin_caller',
                        'open_review_flag', 'flag_after_unpaid_abandons', 'flag_after_false_disputes',
                        'customer_unsettled_order', 'customer_has_unsettled_order', 'order_ended_at',
                        'can_raise_dispute', 'new_delivery_pin', 'apply_payment_confirmed',
                        'apply_payment_refused', 'check_admin_text'))                    AS new_functions_present,    -- must be 0
  (SELECT count(*) FROM pg_constraint
    WHERE conname = 'admin_review_flags_reason_check'
      AND conrelid = 'public.admin_review_flags'::regclass)                              AS flag_reason_check_found,  -- must be 1
  (SELECT count(*) FROM public.orders
    WHERE status IN ('delivered', 'completed') AND payment_status <> 'paid')             AS delivered_not_paid,       -- must be 0 (each would block its customer)
  (SELECT count(*) FROM public.orders
    WHERE status = 'picked_up' AND payment_status <> 'unpaid')                           AS picked_up_with_payment,   -- must be 0
  (SELECT count(*) FROM public.orders WHERE status IN ('accepted', 'picked_up'))         AS jobs_in_progress,         -- info
  (SELECT count(*) FROM public.orders)                                                   AS orders_total;             -- info: the table is rewritten once
```

If any "must be" value differs, stop and ask before pushing. In particular:
- **`delivered_not_paid` above 0:** those customers would be blocked from ordering as
  soon as the migration lands. Look at them first (old TEST orders can be set paid, or
  cancelled, before deploying).
- **`picked_up_with_payment` above 0:** orders moved to "awaiting payment" by hand (the
  old dispatch guide §6). They have no arrival time, so the rider can never mark them
  unpaid. Finish or cancel them first.

Then deploy:
```
supabase db push --remote --dry-run   # should list only 20261128100000_delivery_and_payment.sql
supabase db push --remote
```

**After deploying**, check:

```sql
SELECT awaiting_payment_refuse_after_minutes, customer_unpaid_flag_after, false_dispute_flag_after,
       delivery_pin_max_attempts, dispute_window_days, dropoff_arrival_radius_m
FROM public.app_settings;                                  -- expect 15 | 2 | 3 | 5 | 7 | 500

SELECT relname, relrowsecurity FROM pg_class
WHERE relname IN ('order_delivery_pins', 'order_payment_disputes', 'order_admin_actions');  -- 3 rows, all true
```

Nothing else is needed in the dashboard: no new cron job, Edge Function or secret.

---

## 1. Settings

```sql
UPDATE public.app_settings SET awaiting_payment_refuse_after_minutes = 15;  -- 5..120
UPDATE public.app_settings SET customer_unpaid_flag_after = 2;             -- 1..20 abandons
UPDATE public.app_settings SET false_dispute_flag_after = 3;               -- 1..20 false disputes
UPDATE public.app_settings SET delivery_pin_max_attempts = 5;              -- 3..10 wrong PINs
UPDATE public.app_settings SET dispute_window_days = 7;                    -- 1..30 days after the order ends
UPDATE public.app_settings SET dropoff_arrival_radius_m = 500;             -- 100..5000 m from the drop-off
```

## 2. Watching deliveries

```sql
-- Jobs after pickup, and where each one stands
SELECT o.id, o.payment_reference, o.status, o.payment_status, o.arrived_dropoff_at,
       o.customer_reported_paid_at, o.payment_confirmed_at, o.payment_confirmed_by,
       rd.full_name AS rider, pn.wrong_attempts AS wrong_pins, pn.locked_at AS pin_locked_at,
       (SELECT d.raised_as || ' ' || d.reason FROM public.order_payment_disputes d
         WHERE d.order_id = o.id AND d.status = 'open') AS open_dispute
FROM public.orders o
LEFT JOIN public.rider_details rd ON rd.user_id = o.rider_id
LEFT JOIN public.order_delivery_pins pn ON pn.order_id = o.id
WHERE o.status = 'picked_up'
ORDER BY o.picked_up_at;

-- Customers blocked from ordering
SELECT p.phone, u.reason, u.order_id
FROM public.profiles p
CROSS JOIN LATERAL public.customer_unsettled_order(p.id) u;
```

## 3. Disputes

**Open disputes, oldest first:**

```sql
SELECT d.id AS dispute_id, d.created_at, d.raised_as, d.reason, d.details, d.opened_by_admin,
       o.payment_reference, o.status, o.payment_status, o.customer_reported_paid_at,
       cp.phone AS customer_phone, rp.phone AS rider_phone
FROM public.order_payment_disputes d
JOIN public.orders o ON o.id = d.order_id
JOIN public.profiles cp ON cp.id = o.customer_id
LEFT JOIN public.profiles rp ON rp.id = o.rider_id
WHERE d.status = 'open'
ORDER BY d.created_at;
```

Phone both sides. Ask the rider to check their bank app while you're on the phone, and
the customer for the time and sending bank of the transfer. Never accept a screenshot as
proof.

**Resolve it:**

```sql
SELECT public.resolve_payment_dispute(
  p_dispute_id  => '<dispute_id>',
  p_outcome     => 'paid',        -- or 'not_paid'
  p_found_false => false,         -- true: the person who raised it was not telling the truth
  p_note        => 'Rider found the credit while on the phone',
  p_recorded_by => '<your name>'
);
```

What each outcome does:

| Order now | `paid` | `not_paid` |
|---|---|---|
| Awaiting payment | Payment confirmed by admin, PIN created; the rider hands over | Ends refused (counts as an abandon) |
| Refused | Becomes paid; the trip is charged | No change |
| Delivered | Stays/becomes paid | Becomes **not paid**: the customer is blocked until settled (§4) |

A delivered order found not paid was already charged to the rider. To credit the rider
back, reverse that commission entry (commission guide §6).

## 4. Admin actions on an order

Each one needs a note and who is recording it, and is kept in `order_admin_actions`.
Never put phone or account numbers in the note.

```sql
-- The rider is at the drop-off but their location can't confirm it (GPS off, phone problem)
SELECT public.admin_mark_arrived_at_dropoff('<order id>', 'Rider phoned: GPS not working', '<your name>');

-- Confirm payment yourself (for example the customer paid after a refusal or after delivery)
SELECT public.admin_confirm_payment('<order id>', 'Rider confirmed the credit by phone', '<your name>');

-- PIN locked, or the receiver can't be reached; the payment must already be confirmed
SELECT public.admin_complete_delivery('<order id>', 'Receiver confirmed by phone', '<your name>');

-- Open a dispute for the rider (or customer) who phoned support, for example after handover
SELECT public.admin_open_payment_dispute(
  '<order id>', 'rider', 'payment_not_received', 'Rider called: credit never arrived', '<your name>');
-- raised_as: 'customer' or 'rider'
-- reason: 'paid_not_confirmed', 'payment_not_received', 'wrong_amount' or 'other'
```

**Review flags** (abandons and false disputes) appear in the dispatch guide §4 query,
with reason `unpaid_abandons` or `false_disputes`. Resolve them the same way, with
`resolve_review_flag`.

---

## 5. Testing with one phone (SQL Editor)

The phone stays signed in as the **customer** `0800 000 0102`. Riders `0101` and `0103`
are played in the SQL Editor. Each block below runs as **one transaction**, so no timer
can catch you out. Run them one at a time.

**Before you start:**
1. Expo runs from this branch until it's merged.
2. Run the §0 check if the migration isn't deployed yet.
3. Both TEST riders must have a verified bank account and **no commission due**: check
   with the commission guide §7. Each delivered TEST trip adds a trip to that rider's
   cycle, so this script spreads trips across both riders.

**Find the newest TEST order** (used by every block):
```sql
SELECT id, payment_reference, status, payment_status, arrived_dropoff_at,
       customer_reported_paid_at, payment_confirmed_by, delivered_at
FROM public.orders
WHERE pickup_address LIKE 'TEST ORDER (payment test)%'
ORDER BY created_at DESC LIMIT 1;
```
I'll call this **N**.

### 5a. A picked-up TEST order for one rider

This skips dispatch (tested in the dispatch guide) and creates the order already picked
up by the rider you name. Change `v_rider_phone` to choose the rider.

```sql
DO $$
DECLARE
  v_rider_phone text := '2348000000101';   -- or '2348000000103'
  v_rider uuid := (SELECT id FROM public.profiles WHERE phone = v_rider_phone);
  v_customer uuid := (SELECT id FROM public.profiles WHERE phone = '2348000000102');
  v_order uuid;
BEGIN
  IF v_rider IS NULL OR v_customer IS NULL THEN
    RAISE EXCEPTION 'Sign in with the rider and the customer numbers in the app once first';
  END IF;
  INSERT INTO public.orders
    (customer_id, rider_id, status, pickup_address, pickup_lat, pickup_lng, dropoff_address, dropoff_lat, dropoff_lng,
     price_kobo, commission_kobo, distance_m, distance_source, package_description,
     accepted_at, arrived_pickup_at, picked_up_at, payee_account_id)
  VALUES (v_customer, v_rider, 'picked_up',
          'TEST ORDER (payment test) pickup, Ede', 7.7350, 4.4360,
          'TEST ORDER (payment test) drop-off, Ede', 7.7450, 4.4450,
          205000, 30750, 2350, 'routes', 'TEST package', now(), now(), now(),
          (SELECT id FROM public.rider_bank_accounts WHERE rider_id = v_rider AND status = 'verified'))
  RETURNING id INTO v_order;
  INSERT INTO public.order_contacts (order_id, receiver_name, receiver_phone)
  VALUES (v_order, 'TEST Receiver', '2348000000104');
END $$;
```

- **Database (N):** `picked_up`, `unpaid`, a `DSP-…` reference.
- **Phone:** home (leave and come back) lists the order; open it. "Package picked up",
  the rider card, and no payment card yet.
- **If you get "duplicate key … orders_one_active_job_per_rider":** that rider still has
  a job open. Finish it or run the cleanup (§6).

### 5b. The rider arrives at the drop-off

```sql
DO $$
DECLARE
  v_rider_phone text := '2348000000101';   -- the rider from 5a
  v_rider uuid := (SELECT id FROM public.profiles WHERE phone = v_rider_phone);
  v_order uuid := (SELECT id FROM public.orders WHERE rider_id = v_rider AND status = 'picked_up'
                     AND pickup_address LIKE 'TEST ORDER (payment test)%' ORDER BY created_at DESC LIMIT 1);
BEGIN
  -- Stand the rider about 20 m from the drop-off, with a fresh location
  UPDATE public.rider_details SET is_online = true WHERE user_id = v_rider;
  INSERT INTO public.rider_locations (rider_id, lat, lng) VALUES (v_rider, 7.7452, 4.4450)
  ON CONFLICT (rider_id) DO UPDATE SET lat = EXCLUDED.lat, lng = EXCLUDED.lng;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_rider, 'role', 'authenticated')::text, true);
  PERFORM public.mark_arrived_at_dropoff(v_order);
END $$;
```

- **Database (N):** `awaiting_payment`, `arrived_dropoff_at` set.
- **Phone** (within about 8 s): the yellow "Pay the rider by bank transfer" box, and a
  **Payment due** card with ₦2,050, the reference and an **I've paid** button.
- **To try the distance check:** run the block with `7.7650` in place of `7.7452` on a
  fresh 5a order. Expect "You are not at the drop-off yet. Move closer and try again".

### 5c. The customer taps "I've paid" (phone)

Tap **I've paid**, then **I've paid** in the dialog.
- **Phone:** "You said you paid at HH:MM. Waiting for the rider to confirm…"
- **Database (N):** `customer_reported_paid_at` is set; `payment_status` is still
  `awaiting_payment`.

### 5d. The rider confirms payment

```sql
DO $$
DECLARE
  v_rider uuid := (SELECT id FROM public.profiles WHERE phone = '2348000000101');   -- the rider from 5a
  v_order uuid := (SELECT id FROM public.orders WHERE rider_id = v_rider AND status = 'picked_up'
                     AND pickup_address LIKE 'TEST ORDER (payment test)%' ORDER BY created_at DESC LIMIT 1);
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_rider, 'role', 'authenticated')::text, true);
  PERFORM public.confirm_payment_received(v_order);
END $$;
```

- **Database (N):** `paid`, `payment_confirmed_by = rider`.
- **Phone:** **Payment confirmed** with a big 4-digit **Delivery PIN**; the bank box is
  gone.

### 5e. Handover with the PIN

Read the PIN **from the phone** (that's what the receiver would tell the rider) and put
it in place of `<PIN>`. Try a wrong one first if you like.

```sql
DO $$
DECLARE
  v_rider uuid := (SELECT id FROM public.profiles WHERE phone = '2348000000101');   -- the rider from 5a
  v_order uuid := (SELECT id FROM public.orders WHERE rider_id = v_rider AND status = 'picked_up'
                     AND pickup_address LIKE 'TEST ORDER (payment test)%' ORDER BY created_at DESC LIMIT 1);
  r record;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_rider, 'role', 'authenticated')::text, true);
  SELECT * INTO r FROM public.complete_delivery(v_order, '<PIN>');
  RAISE NOTICE 'Result: %, tries left: %', r.result, r.attempts_left;
END $$;
```

- **Wrong PIN:** notice `wrong_pin, tries left: 4`. After 5 wrong tries: `locked`, and
  §4 `admin_complete_delivery` finishes it.
- **Right PIN:** notice `delivered`. **Phone:** "Delivered" and a **Receipt** card: paid
  to the rider's account name and bank with `••••` and the last 4 digits, rider and
  plate, time confirmed, reference.
- **Database:** N shows `delivered`, `paid`. The commission guide §6 "find the entry"
  query shows one new `commission` entry for this order.

### 5f. Refused: the customer doesn't pay (use rider 0103)

1. Run **5a** with `v_rider_phone := '2348000000103'`, then **5b** with the same rider.
   Don't tap "I've paid".
2. Make the wait pass (TEST only; it backdates the arrival by 16 minutes):
   ```sql
   UPDATE public.orders SET arrived_dropoff_at = now() - interval '16 minutes'
   WHERE id = (SELECT id FROM public.orders WHERE pickup_address LIKE 'TEST ORDER (payment test)%'
                ORDER BY created_at DESC LIMIT 1)
     AND status = 'picked_up';
   ```
3. Rider 0103 marks it unpaid:
   ```sql
   DO $$
   DECLARE
     v_rider uuid := (SELECT id FROM public.profiles WHERE phone = '2348000000103');
     v_order uuid := (SELECT id FROM public.orders WHERE rider_id = v_rider AND status = 'picked_up'
                        AND pickup_address LIKE 'TEST ORDER (payment test)%' ORDER BY created_at DESC LIMIT 1);
   BEGIN
     PERFORM set_config('request.jwt.claims', json_build_object('sub', v_rider, 'role', 'authenticated')::text, true);
     PERFORM public.mark_payment_refused(v_order);
   END $$;
   ```
- **Database (N):** `payment_failed`, `failed`. No commission entry.
- **Phone:** "Not delivered" and a **Report a payment problem** button. Home: no red
  banner (a refused order doesn't block).
- Without step 2 you get "Give the customer more time to pay before marking the order
  unpaid".

**Then the customer says they did pay (phone):** on that order tap **Report a payment
problem**, choose "I paid, but the rider hasn't confirmed", optionally add "Sent at noon
from GTBank", and tap **Send to Dispatch**. The phone shows "You reported a payment
problem". Resolve it as paid:

```sql
SELECT public.resolve_payment_dispute(
  (SELECT d.id FROM public.order_payment_disputes d JOIN public.orders o ON o.id = d.order_id
    WHERE o.pickup_address LIKE 'TEST ORDER (payment test)%' AND d.status = 'open'
    ORDER BY d.created_at DESC LIMIT 1),
  'paid', false, 'TEST: rider found the credit', 'payment test');
```

- **Database (N):** `payment_failed`, `paid`; a `commission` entry for rider 0103 (a
  confirmed payment counts however the order ends).
- **Phone:** "Dispatch confirmed your payment after the rider marked the order unpaid."

### 5g. Customer reported paid, so the rider must dispute (use rider 0101)

1. Run **5a** and **5b** with rider 0101. On the phone, tap **I've paid** (5c).
2. Backdate the arrival (5f step 2).
3. Try to mark it unpaid as rider 0101 (5f step 3, with `'2348000000101'`). Expect:
   "The customer says they have paid. Report a problem instead, and Dispatch will decide".
4. Rider 0101 reports the problem:
   ```sql
   DO $$
   DECLARE
     v_rider uuid := (SELECT id FROM public.profiles WHERE phone = '2348000000101');
     v_order uuid := (SELECT id FROM public.orders WHERE rider_id = v_rider AND status = 'picked_up'
                        AND pickup_address LIKE 'TEST ORDER (payment test)%' ORDER BY created_at DESC LIMIT 1);
   BEGIN
     PERFORM set_config('request.jwt.claims', json_build_object('sub', v_rider, 'role', 'authenticated')::text, true);
     PERFORM public.raise_payment_dispute(v_order, 'payment_not_received', 'TEST: nothing in my bank app');
   END $$;
   ```
- **Phone (order):** "The rider reported a payment problem. Dispatch will contact you."
- **Phone (home):** a red **"You can't place new orders yet"** banner, and **Send a
  package** is disabled. Opening **Send a package** directly shows the same banner.
5. Resolve it as not paid (the customer couldn't show a transfer):
   ```sql
   SELECT public.resolve_payment_dispute(
     (SELECT d.id FROM public.order_payment_disputes d JOIN public.orders o ON o.id = d.order_id
       WHERE o.pickup_address LIKE 'TEST ORDER (payment test)%' AND d.status = 'open'
       ORDER BY d.created_at DESC LIMIT 1),
     'not_paid', false, 'TEST: customer could not show a transfer', 'payment test');
   ```
- **Database (N):** `payment_failed`, `failed`. This counts as an abandon (the 5f order
  doesn't: it was later found paid). Check:
   ```sql
   SELECT
     (SELECT count(*) FROM public.orders o JOIN public.profiles p ON p.id = o.customer_id
       WHERE p.phone = '2348000000102' AND o.status = 'payment_failed' AND o.payment_status = 'failed') AS abandons,
     (SELECT count(*) FROM public.admin_review_flags f JOIN public.profiles p ON p.id = f.user_id
       WHERE p.phone = '2348000000102' AND f.reason = 'unpaid_abandons' AND f.resolved_at IS NULL) AS abandon_flags;
   ```
   One abandon so far, no flag. Repeat 5f steps 1–3 once (rider 0103, no dispute after)
   for the second abandon: then `abandons = 2` and `abandon_flags = 1`.
- **Phone (home):** the red banner is gone once the dispute is resolved.

**False disputes:** resolving with `p_found_false => true` counts the dispute against
whoever raised it; a third one opens a `false_disputes` flag. The pgTAP tests cover the
counting; to see it by hand, repeat 5g with `'paid', true` three times.

---

## 6. Clean up TEST data

Cancels open TEST orders, closes open TEST disputes, settles any delivered TEST order
left unpaid, resolves the TEST customer's and riders' flags from this test, and takes
the TEST riders offline. Append-only history (disputes, admin actions, ledger entries)
stays.

```sql
DO $$
DECLARE
  o record;
  d record;
  f record;
BEGIN
  FOR o IN SELECT id FROM public.orders
            WHERE pickup_address LIKE 'TEST ORDER (payment test)%'
              AND status IN ('created', 'rider_requested', 'accepted', 'picked_up', 'no_rider_found') LOOP
    PERFORM public.admin_cancel_order(o.id, 'customer', 'Cleanup of payment test data', 'payment test cleanup');
  END LOOP;

  FOR d IN SELECT dd.id, oo.payment_status FROM public.order_payment_disputes dd
             JOIN public.orders oo ON oo.id = dd.order_id
            WHERE oo.pickup_address LIKE 'TEST ORDER (payment test)%' AND dd.status = 'open' LOOP
    PERFORM public.resolve_payment_dispute(d.id, CASE WHEN d.payment_status = 'paid' THEN 'paid' ELSE 'not_paid' END,
                                           false, 'Cleanup of payment test data', 'payment test cleanup');
  END LOOP;

  FOR o IN SELECT id FROM public.orders
            WHERE pickup_address LIKE 'TEST ORDER (payment test)%'
              AND status IN ('delivered', 'completed') AND payment_status <> 'paid' LOOP
    PERFORM public.admin_confirm_payment(o.id, 'Cleanup of payment test data', 'payment test cleanup');
  END LOOP;

  FOR f IN SELECT fl.id FROM public.admin_review_flags fl JOIN public.profiles p ON p.id = fl.user_id
            WHERE p.phone IN ('2348000000101', '2348000000102', '2348000000103')
              AND fl.reason IN ('unpaid_abandons', 'false_disputes') AND fl.resolved_at IS NULL LOOP
    PERFORM public.resolve_review_flag(f.id, 'Payment test data', 'payment test cleanup');
  END LOOP;

  UPDATE public.rider_details SET is_online = false
   WHERE is_online AND user_id IN (SELECT id FROM public.profiles WHERE phone IN ('2348000000101', '2348000000103'));
END $$;

-- Check: expect 0 | 0 | 0 | 0
SELECT
  (SELECT count(*) FROM public.orders WHERE pickup_address LIKE 'TEST ORDER (payment test)%'
     AND status IN ('created', 'rider_requested', 'accepted', 'picked_up', 'no_rider_found'))      AS test_orders_open,
  (SELECT count(*) FROM public.order_payment_disputes d JOIN public.orders o ON o.id = d.order_id
    WHERE o.pickup_address LIKE 'TEST ORDER (payment test)%' AND d.status = 'open')                 AS test_disputes_open,
  (SELECT count(*) FROM public.profiles p, LATERAL public.customer_unsettled_order(p.id)
    WHERE p.phone = '2348000000102')                                                                AS customer_blocked,
  (SELECT count(*) FROM public.rider_details rd JOIN public.profiles p ON p.id = rd.user_id
    WHERE rd.is_online AND p.phone IN ('2348000000101', '2348000000103'))                           AS test_riders_online;
```

**Commission from TEST trips:** every delivered (or found-paid) TEST order charged its
rider. Reverse them so the riders owe nothing for test trips:

```sql
SELECT public.reverse_commission_entry(e.id, 'Payment test order, not a real trip', 'payment test cleanup')
FROM public.commission_entries e
JOIN public.orders o ON o.id = e.order_id
WHERE o.pickup_address LIKE 'TEST ORDER (payment test)%'
  AND e.type = 'commission'
  AND NOT EXISTS (SELECT 1 FROM public.commission_entries r WHERE r.reverses_entry_id = e.id);
```

The trips still count towards each rider's cycle (only the money is reversed), so check
the commission guide §7 before the next test.
