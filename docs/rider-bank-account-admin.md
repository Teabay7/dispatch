# Rider bank accounts: admin guide (until the admin panel exists)

Customers pay riders directly, into the rider's own bank account (SPEC.md §10.4 and
§10.8). Every rider adds that account in the app, and an admin approves it by hand
before the rider can go online. Until the admin panel is built, do this in the
**Supabase dashboard → SQL Editor**.

Rules the database enforces, whatever you do:
- **Who can write:** only the rider (through the app) can submit an account. Only an
  admin (or the SQL Editor) can approve, reject or revoke one. Nobody can edit an
  account's bank, number or name, or delete a record. A different account is always
  a new record that must be approved again.
- **Status:**
  - `pending`: submitted, waiting for you;
  - `verified`: customers pay into it;
  - `rejected`: you refused it, with a reason the rider sees;
  - `withdrawn`: the rider fixed a mistake before review;
  - `replaced`: a newer account was approved;
  - `revoked`: you removed a verified account, with a reason.
- **Limits:** one pending and one verified account per rider. The same bank and number
  can't be pending or verified for two riders.
- **Going online:** needs approved KYC, an active rider role **and** a verified bank
  account. Revoking the account takes the rider offline at once.
- **Name check:** the database compares names with the rider's KYC name, ignoring
  case, punctuation, titles (MR, ALHAJI, CHIEF…) and order:
  - `match`: 2 or more shared names;
  - `partial`: 1 shared name;
  - `mismatch`: none.

  It checks both the name the rider typed (`name_match`) and the name from your own
  enquiry (`verified_name_match`). If either is a `mismatch`, you can only approve
  with a review note.
- **Recorded by:** every approve, reject or revoke needs a free-text `recorded_by`
  (your name). The SQL Editor has no signed-in user, so this is the only record of
  who did it.

> **Privacy:** account numbers are personal financial data.
> - Look them up only to review an account.
> - Never paste them into chats or emails, or share screenshots that show them.
> - The app only shows them masked (`******6789`), except to the rider on their own
>   form.

---

## 0. Before deploying the migration (read-only, once)

Run this in the **SQL Editor** on the hosted project **before**
`supabase db push --remote`:

```sql
SELECT
  (SELECT max(version) FROM supabase_migrations.schema_migrations)   AS latest_migration,       -- must be 20261123120000
  (to_regclass('public.rider_bank_accounts') IS NOT NULL)            AS bank_table_exists,      -- must be false
  (SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public' AND t.typname IN ('bank_account_status', 'bank_name_match'))
                                                                     AS new_enums_present,      -- must be 0
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'rider_details'
      AND column_name = 'plate_released')                            AS plate_released_present, -- must be 0
  (SELECT count(*) FROM public.rider_details
    WHERE bank_account_ref IS NOT NULL)                              AS bank_refs_filled,       -- must be 0
  (SELECT count(*) FROM (SELECT upper(btrim(plate_number))
                           FROM public.rider_details
                          GROUP BY 1 HAVING count(*) > 1) d)         AS duplicate_plates,       -- must be 0
  (SELECT count(*) FROM public.rider_details WHERE kyc_status = 'approved')
                                                                     AS approved_riders,        -- info: each needs a verified account
  (SELECT count(*) FROM public.rider_details WHERE is_online)        AS riders_online_now;      -- info: set offline by the migration
```

If any "must be" value differs, stop and ask before pushing. In particular:
- If `latest_migration` is older, push the earlier migrations first.
- If `duplicate_plates` is above 0, the unique-plate index can't be created. Find the
  duplicates with:
  ```sql
  SELECT upper(btrim(plate_number)) AS plate, array_agg(user_id) AS riders
  FROM public.rider_details GROUP BY 1 HAVING count(*) > 1;
  ```

Then deploy:
```
supabase db push --remote --dry-run   # should list only 20261124100000_rider_bank_account.sql
supabase db push --remote
```

**What changes straight away:**
- Every rider who is online is set offline, and their location is deleted.
- No approved rider can go online until you verify a bank account for them. Approved
  riders see "Add your bank account" on the home screen.

---

## 1. Accounts waiting for review (oldest first)

```sql
SELECT b.id AS account_id, p.phone, rd.full_name AS kyc_name,
       b.bank_name, b.account_number, b.account_name, b.name_match,
       (SELECT v.bank_name || ' ' || right(v.account_number, 4)
          FROM public.rider_bank_accounts v
         WHERE v.rider_id = b.rider_id AND v.status = 'verified') AS current_verified,
       b.created_at
FROM public.rider_bank_accounts b
JOIN public.rider_details rd ON rd.user_id = b.rider_id
JOIN public.profiles p ON p.id = b.rider_id
WHERE b.status = 'pending'
ORDER BY b.created_at;
```

If `current_verified` is filled in, this is a **change of account**: follow §3 before
approving.

---

## 2. The name enquiry (check the account really exists and whose it is)

Do this for every pending account, from the **company** bank app or internet
banking. **Do not send any money.**

1. Start a new transfer ("Send money" / "Transfer to other bank").
2. Choose the rider's bank (`bank_name`) and type the `account_number`.
3. Wait for the app to show the account holder's name (the name enquiry), and write
   it down exactly as shown.
4. **Cancel the transfer.** Don't enter an amount or a PIN.

Then compare the name you saw with:
- `kyc_name` (the name on the rider's ID): it must be the same person. Name order
  and middle names often differ, which is fine.
- `account_name` (what the rider typed): a big difference suggests a typo or the
  wrong account.

If the bank app shows no name or an error, the number is wrong. Reject the account
(§5) with "We could not find this account. Check the number and bank."

---

## 3. Checking that a change of account is really the rider's

A change redirects every future payment, so treat it as a security check. The old
account keeps receiving payments until you approve the new one, so there's no rush.

1. **Phone the rider on the number registered in Dispatch** (`phone` in §1). Never
   use a number given in a message, an email or by someone else.
2. Ask them to confirm:
   - that they asked for the change;
   - the new bank;
   - the **last 4 digits** of the new number;
   - why they're changing.

   Don't read the number out to them.
3. Do the name enquiry (§2) on the new account. It must be in the rider's own name,
   matching `kyc_name`.
4. Be suspicious and reject (or call again later) if:
   - the rider doesn't know about the change;
   - the call goes to someone else;
   - the new account is in another person's name;
   - the change comes just after the rider reported a lost phone or SIM;
   - there were several changes in a short time (check §7).
5. Approve only when all checks pass. In the note, say that you phoned them and what
   they confirmed.

---

## 4. Approve

```sql
SELECT public.approve_rider_bank_account(
  p_account_id    => '<account_id from §1>',
  p_verified_name => '<name exactly as your name enquiry showed it>',
  p_recorded_by   => '<your name>',
  p_note          => NULL   -- required if the name is a mismatch; recommended for changes
);
```

Example for a change of account:

```sql
SELECT public.approve_rider_bank_account(
  '<account_id>', 'OKAFOR ADEBAYO', 'Admin Ade',
  'Phoned rider on registered number 24 Nov; confirmed new OPay ending 6789, old account closed');
```

If the rider had a verified account, it becomes `replaced` in the same step. The
rider can go online once their KYC is also approved.

**Approving a mismatch** (e.g. a joint or family account). Only do this if you're sure
it's acceptable, and explain why in the note:

```sql
SELECT public.approve_rider_bank_account(
  '<account_id>', 'CHIDI OBI', 'Admin Ade',
  'Account belongs to the rider''s brother; rider confirmed by phone; allowed for pilot');
```

Without a note, the database refuses with "A name mismatch can only be approved with
a review note".

---

## 5. Reject

The rider sees the reason, so make it something they can act on:

```sql
SELECT public.reject_rider_bank_account(
  '<account_id>',
  'The account name does not match your ID. Use an account in your own name.',
  '<your name>'
);
```

Rejecting a **change** leaves the rider's current verified account in place.

---

## 6. Revoke a verified account

Use this for fraud, a closed account, customers reporting that payments don't arrive,
or a rider who asks you to stop using an account. The rider goes offline at once and
can't go online until a new account is verified.

```sql
-- Find the verified account
SELECT b.id AS account_id, p.phone, rd.full_name, b.bank_name, right(b.account_number, 4) AS last4
FROM public.rider_bank_accounts b
JOIN public.rider_details rd ON rd.user_id = b.rider_id
JOIN public.profiles p ON p.id = b.rider_id
WHERE b.status = 'verified' AND p.phone = '2348031234567';   -- no "+"

SELECT public.revoke_rider_bank_account(
  '<account_id>',
  'Customers reported that payments to this account do not arrive. Add a new account.',
  '<your name>'
);
```

---

## 7. Recent account changes, by rider

Every submission, review and revocation in the last 30 days, newest first. Only the
last 4 digits are shown.

```sql
SELECT p.phone, rd.full_name AS kyc_name,
       b.created_at AS submitted_at, b.bank_name, right(b.account_number, 4) AS last4,
       b.account_name, b.name_match, b.status,
       b.verified_name, b.verified_name_match, b.reviewed_at, b.recorded_by, b.review_note,
       b.reason, b.revoked_at, b.revoked_recorded_by
FROM public.rider_bank_accounts b
JOIN public.rider_details rd ON rd.user_id = b.rider_id
JOIN public.profiles p ON p.id = b.rider_id
WHERE b.created_at > now() - interval '30 days'
   OR b.reviewed_at > now() - interval '30 days'
   OR b.revoked_at  > now() - interval '30 days'
ORDER BY p.phone, b.created_at DESC;
```

Riders with many submissions recently (worth a look):

```sql
SELECT p.phone, rd.full_name, count(*) AS submissions_30d,
       count(*) FILTER (WHERE b.status = 'rejected') AS rejected,
       max(b.created_at) AS last_submission
FROM public.rider_bank_accounts b
JOIN public.rider_details rd ON rd.user_id = b.rider_id
JOIN public.profiles p ON p.id = b.rider_id
WHERE b.created_at > now() - interval '30 days'
GROUP BY p.phone, rd.full_name
HAVING count(*) >= 3
ORDER BY submissions_30d DESC;
```

---

## 8. Releasing a plate number (bike changed owner)

Plate numbers are unique, so a new rider can't register a plate that another rider
still holds. They see "This plate number is already registered to another rider".
If the bike really has a new owner, check with both riders, then free the plate on
the **old** owner's record:

```sql
SELECT p.phone, rd.full_name, rd.plate_number, rd.kyc_status, rd.is_online, rd.user_id
FROM public.rider_details rd JOIN public.profiles p ON p.id = rd.user_id
WHERE rd.plate_number = upper(btrim('EDE 123 AA'));

UPDATE public.rider_details SET plate_released = true
WHERE user_id = '<old owner user_id>';
```

The new owner can then submit their KYC with that plate. The old owner's record
keeps the plate for history. If they're still riding, choose one:
- reject their KYC with a reason such as "Your bike changed owner. Resubmit with your
  new bike's details", so they can resubmit;
- suspend their rider role.

Approved KYC details are locked, so they can't change the plate themselves.
