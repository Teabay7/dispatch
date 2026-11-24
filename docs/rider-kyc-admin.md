# Rider KYC: admin guide (until the admin panel exists)

Riders submit their name, an ID photo (front), a selfie and bike details from the
app. An admin approves or rejects each rider by hand (SPEC.md §10.7). Until the
admin panel is built, do it from the **Supabase dashboard**:
- the **SQL Editor** for queries and decisions;
- **Storage** for viewing photos.

Rules the database enforces, whatever you do:
- **Status:** `pending` (submitted, waiting for you), `approved` or `rejected`.
  A rejection **must** have a reason; the rider sees it and can fix and resubmit.
- **Locking:** riders cannot change their details while `pending` or after approval.
  They cannot change their status or the reason.
- **Going online:** a rider can only go online with KYC `approved`, an active rider
  role **and** a verified bank account (see `rider-bank-account-admin.md`). Rejecting an online rider, or suspending their rider role, takes them
  offline straight away.
- **Suspension is per role:** suspending the rider role does not affect the same
  person's customer role.

> In the SQL Editor you run as the database owner, so the review is recorded with
> `reviewed_at`, but `reviewed_by` stays empty. The admin panel will record who
> reviewed.

---

## 0. Before deploying the KYC migration (once)

Run this on the hosted project **before** `supabase db push`. The migration adds
required columns to `rider_details`, so it must be empty:

```sql
SELECT count(*) AS rider_details_rows FROM public.rider_details;
```

It must return `0`. If it doesn't, stop and ask before pushing.

---

## 1. List riders waiting for review

```sql
SELECT p.phone, rd.full_name, rd.bike_make_model, rd.bike_colour, rd.plate_number,
       rd.submitted_at, rd.id_photo_path, rd.selfie_path, rd.user_id
FROM public.rider_details rd
JOIN public.profiles p ON p.id = rd.user_id
WHERE rd.kyc_status = 'pending'
ORDER BY rd.submitted_at;   -- oldest first
```

Phone numbers are stored without the `+`, e.g. `2348031234567`.

To see every rider with their status and whether the rider role is suspended:

```sql
SELECT p.phone, rd.full_name, rd.kyc_status, ur.status AS rider_role_status,
       rd.rejection_reason, rd.submitted_at, rd.reviewed_at, rd.is_online
FROM public.rider_details rd
JOIN public.profiles p ON p.id = rd.user_id
LEFT JOIN public.user_roles ur ON ur.user_id = rd.user_id AND ur.role = 'rider'
ORDER BY rd.submitted_at DESC;
```

---

## 2. View the rider's photos (private)

The `rider-kyc` bucket is **private**: there are no public links. Use one of these
two options.

**Option A: Dashboard Storage (easiest)**
1. Go to **Storage → Buckets → `rider-kyc`**.
2. Open the folder named after the rider's `user_id` (from the query above).
3. Click the files named in `id_photo_path` and `selfie_path`. The dashboard shows a
   preview using a temporary signed link.

   A rider who retook a photo has extra, older files in their folder. Only the
   paths in `rider_details` are the submitted ones.

**Option B: A short-lived signed URL**
In the file's menu in Storage, choose **Get URL** and pick a short expiry (e.g.
60 seconds).

Checks before you approve:
- **Name:** the name on the ID matches `full_name`.
- **Selfie:** it shows the same person as the ID.
- **ID photo:** it's readable, with all four corners visible.
- **Bike:** the details look plausible. Bikes only during the pilot.

Privacy:
- Do not download KYC photos to personal devices.
- Do not paste signed URLs into chats or tickets.
- Do not screenshot ID documents.

---

## 3. Approve a rider

Replace the phone number:

```sql
UPDATE public.rider_details rd
   SET kyc_status = 'approved'
  FROM public.profiles p
 WHERE p.id = rd.user_id
   AND p.phone = '2348031234567'
   AND rd.kyc_status = 'pending'
RETURNING rd.user_id, rd.full_name, rd.kyc_status, rd.reviewed_at;
```

It should say `UPDATE 1`. `UPDATE 0` means the phone number is wrong or the rider
isn't pending.

## 4. Reject a rider (with a reason)

Write the reason for the rider: say what to fix, in plain words. They see it exactly as
written.

```sql
UPDATE public.rider_details rd
   SET kyc_status = 'rejected',
       rejection_reason = 'Your ID photo is blurry. Please retake it in good light with all four corners showing.'
  FROM public.profiles p
 WHERE p.id = rd.user_id
   AND p.phone = '2348031234567'
   AND rd.kyc_status = 'pending'
RETURNING rd.user_id, rd.full_name, rd.kyc_status, rd.rejection_reason;
```

A rejection without a reason fails with a `rider_details_rejection_reason` check
error. That is intentional.

When the rider fixes and resubmits:
- the status goes back to `pending`;
- the reason is cleared;
- they reappear in the list from section 1.

You can also reject an already-approved rider the same way. Change the last
condition to `rd.kyc_status = 'approved'`. This also takes them offline.

## 5. Suspend or reinstate a rider (rider role only)

Suspending the rider role stops them going online, and stops them submitting or
resubmitting KYC. Their customer role keeps working.

```sql
-- Suspend
UPDATE public.user_roles ur
   SET status = 'suspended', suspended_reason = 'Reason for the record (not shown in the app yet)'
  FROM public.profiles p
 WHERE p.id = ur.user_id AND p.phone = '2348031234567' AND ur.role = 'rider'
RETURNING ur.user_id, ur.role, ur.status;

-- Reinstate
UPDATE public.user_roles ur
   SET status = 'active', suspended_reason = NULL
  FROM public.profiles p
 WHERE p.id = ur.user_id AND p.phone = '2348031234567' AND ur.role = 'rider'
RETURNING ur.user_id, ur.role, ur.status;
```

## Alternative: Table Editor

You can also edit `rider_details` in **Table Editor**:
- set `kyc_status` to `approved`;
- or set it to `rejected` and fill in `rejection_reason` in the same save.

The same rules apply. The SQL above is safer because it matches on phone number
and current status, so you can't edit the wrong row by mistake.
