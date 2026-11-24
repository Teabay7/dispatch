# Commission: admin guide (until the admin panel exists)

Riders keep the fare. They owe Dispatch a commission on every counted trip, and pay
it every few trips by bank transfer to the company account (SPEC.md §10.3, §10.9,
§10.10). Until the admin panel is built, you record those payments in the
**Supabase dashboard → SQL Editor**.

Rules the database enforces, whatever you do:
- **Rate:** commission is `app_settings.commission_bps` basis points of the trip price
  (1500 = 15%), rounded half-up to the kobo. It is fixed when the order is priced.
- **Which trips count:**
  - every trip that ends `delivered` or `completed`;
  - a trip that ends any other way (cancelled, no rider, payment failed) **only if
    its payment was confirmed**;
  - a cancelled trip with no payment never counts.
- **No double charges:** each order is charged at most once, ever.
- **Cycles:** trips are counted in cycles of `app_settings.commission_trips_per_cycle`
  (default 4). On the last trip of a cycle, the cycle becomes **due** and the rider is
  **set offline in the same step**. While a cycle is due, the database refuses to let
  the rider go online.
- **Unblocking:** only when the rider's **whole balance** is paid. Part payments are
  recorded but the rider stays offline. Anything paid above the balance is **credit**,
  which later trips use up. If credit already covers a cycle when it becomes due, it
  is marked paid at once and the rider stays online.
- **Append-only ledger:** entries can't be edited or deleted, by anyone. Mistakes are
  fixed with a **reversing entry**.
- **No duplicate transfers:** the same bank transfer (bank transaction reference)
  can't be recorded twice, unless the first recording was reversed.
- **Reference codes:** every cycle has one, e.g. `DSP-42501F66-C004`. Riders write it
  in the transfer narration. It is unique; if two riders' ids start the same way, the
  code is longer for the second rider.

**Money is in kobo** in every query and function: ₦1 = 100 kobo, so ₦1,080 =
`108000` and ₦277.50 = `27750`. Balances: **positive = the rider owes**, **negative =
credit**.

> In the SQL Editor you run as the database owner, so there is no signed-in user.
> That's why every payment, reversal and account change asks for a free-text
> `recorded_by`: it is the only record of who did it.

---

## 0. Before deploying the migration (read-only, once)

Run this in the **SQL Editor** on the hosted project **before**
`supabase db push --remote`:

```sql
SELECT
  (SELECT max(version) FROM supabase_migrations.schema_migrations)   AS latest_migration,           -- must be 20261124100000
  (SELECT count(*) FROM public.app_settings)                         AS app_settings_rows,          -- must be 1
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'app_settings'
      AND column_name = 'commission_percent')                        AS commission_percent_present, -- must be 1
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'app_settings'
      AND column_name IN ('commission_bps', 'commission_trips_per_cycle'))
                                                                     AS new_settings_present,       -- must be 0
  (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname IN ('commission_cycles', 'commission_entries',
                        'company_payment_account', 'company_payment_account_changes'))
                                                                     AS new_tables_present,         -- must be 0
  (SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public'
      AND t.typname IN ('commission_cycle_status', 'commission_entry_type'))
                                                                     AS new_enums_present,          -- must be 0
  (SELECT count(*) FROM public.orders
    WHERE status IN ('delivered', 'completed') OR payment_status = 'paid')
                                                                     AS orders_that_would_count,    -- must be 0
  (SELECT count(*) FROM public.orders)                               AS orders_total,               -- info
  (SELECT count(*) FROM public.rider_details WHERE is_online)        AS riders_online_now;          -- info: unaffected
```

If any "must be" value differs, stop and ask before pushing. In particular, if
`orders_that_would_count` is above 0, those trips would never be charged: decide what
to do about them first.

Then deploy:
```
supabase db push --remote --dry-run   # should list only 20261124120000_commission_ledger.sql
supabase db push --remote
```

After the push:
- the rate is 15% and the cycle is 4 trips;
- the company account is **empty** until you set it (§1). Until then, a rider with a
  due cycle sees "Contact Dispatch support for the account details".

---

## 1. Set the company account (do this once, straight after deploying)

Riders pay commission into the **business account of TESNEEM LOGISTICS LTD**. Use the
exact bank name, the 10-digit account number and the account name as the bank shows
it. Copy them from the company's bank documents, not from a message.

```sql
SELECT public.set_company_payment_account(
  p_bank_name      => '<bank name, e.g. GTBank>',
  p_account_number => '<10-digit company account number>',
  p_account_name   => 'TESNEEM LOGISTICS LTD',   -- exactly as the bank's name enquiry shows it
  p_changed_by     => '<your name>'
);
```

- This is the **only** way to change the account. A direct `UPDATE` is refused, even
  in the SQL Editor.
- Every field that changes is logged with who changed it, when, the old value and the
  new value. The log can't be edited.
- Riders never read the table directly. The app gets the details through
  `get_company_payment_account()`, which only riders and admins can call.

**Check it** (do a name enquiry from another bank app to confirm the name, without
sending money):

```sql
SELECT bank_name, account_number, account_name, updated_at
FROM public.company_payment_account;
```

**Change history:**

```sql
SELECT changed_at, changed_by, changed_by_user, field, old_value, new_value
FROM public.company_payment_account_changes
ORDER BY changed_at DESC;
```

Changing the company account is sensitive: it redirects every rider's payments.
Agree changes with the company's directors, and tell riders through a known channel.

---

## 2. Settings

```sql
SELECT commission_bps, commission_trips_per_cycle FROM public.app_settings;

-- 15% commission (basis points: 1500 = 15%, allowed 0..10000)
UPDATE public.app_settings SET commission_bps = 1500;

-- 4 trips per cycle (allowed 1..50)
UPDATE public.app_settings SET commission_trips_per_cycle = 4;
```

- **The rate** applies to orders priced after the change. Orders already priced keep
  their commission.
- **The cycle length** applies to cycles that open after the change. A cycle already
  open keeps its own number of trips.

---

## 3. Riders with amounts owed

Every rider who owes anything or has credit, most blocked first, then largest balance:

```sql
WITH latest AS (
  SELECT DISTINCT ON (rider_id) rider_id, balance_after_kobo, created_at
  FROM public.commission_entries
  ORDER BY rider_id, entry_no DESC
)
SELECT p.phone, rd.full_name,
       l.balance_after_kobo                    AS balance_kobo,      -- positive = owes, negative = credit
       l.balance_after_kobo / 100.0            AS balance_naira,
       due.reference_code                      AS due_reference,
       due.due_at,
       op.trip_count || ' of ' || op.trips_required AS open_cycle_trips,
       rd.is_online,
       l.created_at                            AS last_entry_at
FROM latest l
JOIN public.rider_details rd ON rd.user_id = l.rider_id
JOIN public.profiles p ON p.id = l.rider_id
LEFT JOIN public.commission_cycles due ON due.rider_id = l.rider_id AND due.status = 'due'
LEFT JOIN public.commission_cycles op  ON op.rider_id  = l.rider_id AND op.status  = 'open'
WHERE l.balance_after_kobo <> 0 OR due.id IS NOT NULL
ORDER BY (due.id IS NULL), l.balance_after_kobo DESC;
```

Riders with a `due_reference` are blocked until they pay.

---

## 4. Find a transfer by its reference code

When a transfer arrives in the company account, read the narration. Riders often
mistype, so search with part of the code (the 8 characters after `DSP-` are usually
enough):

```sql
SELECT c.reference_code, c.status, c.trip_count || ' of ' || c.trips_required AS trips,
       c.due_at, c.paid_at, p.phone, rd.full_name,
       public.rider_commission_balance(c.rider_id) AS balance_kobo
FROM public.commission_cycles c
JOIN public.rider_details rd ON rd.user_id = c.rider_id
JOIN public.profiles p ON p.id = c.rider_id
WHERE c.reference_code ILIKE '%' || '42501F66' || '%'    -- part of the code from the narration
ORDER BY c.cycle_no DESC;
```

No reference, or one you can't match? Search by the sender's name or phone instead:

```sql
SELECT p.phone, rd.full_name, c.reference_code, c.status
FROM public.rider_details rd
JOIN public.profiles p ON p.id = rd.user_id
LEFT JOIN public.commission_cycles c ON c.rider_id = rd.user_id AND c.status IN ('due', 'open')
WHERE rd.full_name ILIKE '%okafor%' OR p.phone LIKE '%8031234567';
```

If you're not sure whose transfer it is, phone the rider on their registered number
before recording anything.

---

## 5. Record a payment

```sql
SELECT public.record_commission_payment(
  p_reference_code => 'DSP-42501F66-C004',       -- from §4
  p_amount_kobo    => 108000,                    -- the amount received, in kobo (₦1,080)
  p_bank_reference => '<bank transaction reference / session ID>',
  p_paid_at        => '2026-11-24 10:12+01',     -- when the transfer arrived (Lagos time is +01)
  p_recorded_by    => '<your name>',
  p_note           => 'Transfer from OKAFOR ADEBAYO, narration DSP-42501F66-C004'
) AS balance_after_kobo;
```

It returns the rider's new balance:
- **0**: fully paid. The due cycle is marked paid and the rider can go online.
- **Positive**: a part payment. The rider still owes this much and stays offline.
- **Negative**: overpaid. This much is credit for later trips.

**The bank transaction reference** is the bank's own ID for the transfer (session ID,
transaction reference). It's what stops the same transfer being recorded twice. A
second attempt fails with "This bank transfer is already recorded".

**Part payment** (the rider owes ₦1,080 and sends ₦500):

```sql
SELECT public.record_commission_payment('DSP-42501F66-C004', 50000, '<bank ref 1>',
  '2026-11-24 10:12+01', '<your name>', 'Part payment; rider says the rest is coming tomorrow');
-- returns 58000: ₦580 still owed, the rider stays offline
```

When the rest arrives, record it the same way with its own bank reference. The
balance reaches 0 and the rider is unblocked.

**Overpayment** (the rider owes ₦1,080 and sends ₦1,200):

```sql
SELECT public.record_commission_payment('DSP-42501F66-C004', 120000, '<bank ref>',
  '2026-11-24 10:12+01', '<your name>', 'Rider rounded up to ₦1,200');
-- returns -12000: ₦120 credit, used by the rider's next trips
```

Don't refund small overpayments by hand. Leave them as credit. If a rider asks for
a refund, agree it with them, send it from the company account, then reverse the
payment and record the amount actually kept (§6).

A transfer that arrives **before** a cycle is due (a rider paying early) is recorded
the same way, against their current cycle's reference code. It becomes credit.

---

## 6. Reverse a mistaken entry

Reversals add an opposite entry. Nothing is edited or deleted, so the history stays
complete.

**Find the entry:**

```sql
SELECT e.id AS entry_id, e.entry_no, e.type, e.amount_kobo, e.balance_after_kobo,
       c.reference_code, e.order_id, e.bank_reference, e.paid_at,
       e.recorded_by, e.note, e.created_at,
       EXISTS (SELECT 1 FROM public.commission_entries r WHERE r.reverses_entry_id = e.id) AS already_reversed
FROM public.commission_entries e
JOIN public.commission_cycles c ON c.id = e.cycle_id
JOIN public.profiles p ON p.id = e.rider_id
WHERE p.phone = '2348031234567'      -- no "+"
ORDER BY e.entry_no DESC;
```

**Reverse it:**

```sql
SELECT public.reverse_commission_entry(
  p_entry_id    => '<entry_id>',
  p_reason      => 'Recorded ₦1,800 instead of ₦1,080',
  p_recorded_by => '<your name>'
) AS balance_after_kobo;
```

What happens:
- **Reversing a payment:** the amount is owed again. If that payment had settled a
  cycle, the cycle is due again and the rider is set offline.
- **Reversing a commission** (a trip that should not have been charged): the rider is
  credited. The trip still counts towards the cycle; only the money is reversed.
- **Limits:** an entry can be reversed only once, and a reversal can't be reversed.

**Fixing a payment recorded with the wrong amount:**
1. Reverse it.
2. Record it again with the correct amount and the **same** bank reference. That's
   allowed because the first recording was reversed.

---

## 7. Check a rider's cycle and ledger

```sql
-- Cycles (newest first)
SELECT c.cycle_no, c.reference_code, c.status, c.trip_count, c.trips_required,
       c.opened_at, c.due_at, c.paid_at
FROM public.commission_cycles c
JOIN public.profiles p ON p.id = c.rider_id
WHERE p.phone = '2348031234567'
ORDER BY c.cycle_no DESC;

-- Balance now, and whether they can go online
SELECT public.rider_commission_balance(p.id)  AS balance_kobo,
       public.rider_has_commission_due(p.id)  AS commission_due,
       rd.is_online
FROM public.profiles p JOIN public.rider_details rd ON rd.user_id = p.id
WHERE p.phone = '2348031234567';
```

Use the entries query in §6 for the full ledger. Its last `balance_after_kobo` is the
balance, and it always equals the sum of all the rider's `amount_kobo`.

---

## 8. The delivered-trip step (for developers)

Trips are charged by `public.accrue_trip_commission(order_id)`. A trigger on `orders`
calls it automatically when an order ends in a way that counts, so the order flow
doesn't need to call it. Calling it again is harmless; it returns `false`.

If the list of order statuses ever changes, a pgTAP test fails on purpose. Review
`public.order_counts_as_trip()` before changing that test.

**Privacy:**
- Don't share screenshots of riders' balances or the company account outside the
  admin team.
- The SQL above shows phone numbers. Use them only to contact riders about their
  commission.
