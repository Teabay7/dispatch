# Change proposal: direct payment to riders, commission ledger

Status: **APPROVED 2026-11-23**, with the decisions below. Where the body of this
proposal differs from "Approved decisions", the approved decisions win.

## Approved decisions

| # | Decision |
|---|---|
| D1 | Commission is rounded half-up to the kobo. Distance is billed per started 100 m. The price is rounded up to the nearest ₦50. |
| D2 | Road distance from Google Routes, one call per quote. If it fails, use straight-line × 1.3, and **mark the order as priced with the fallback**. Quotes are **rate-limited per user**. |
| D3 | **Manual admin name check first.** Paystack Resolve is built behind an `app_settings` switch and used only once you provide the secret key. The key lives in Supabase secrets, never in the repo. |
| D4 | An admin approves every rider bank account in the pilot, even a name match. |
| D5 | The full amount owed must be paid to unblock. Partial payments are recorded but the rider stays blocked. Overpayment carries forward as credit. The rider is taken offline immediately after the 4th delivered trip. |
| D6 | No "hand over unpaid": the rider holds the goods until they confirm payment. |
| D7 | A customer is flagged for admin review after 2 abandons. A rider can mark an order refused after 15 minutes in `awaiting_payment`. |
| D8 | Disputes are text-only in the pilot. Screenshot evidence comes later. |
| D9 | Bank account changes are in-app only for the pilot, and the admin phones the rider before approving. SMS is added once Termii is live. |
| D10 | 15% is treated as VAT-inclusive, with an in-app receipt per recorded payment. Confirm with an accountant before public launch. |
| D11 | Plate numbers are unique, so duplicate rider accounts are blocked. An admin can override for a genuine change of bike owner. |
| D12 | Drop `payments`, `wallet_entries` and `withdrawals` after the hosted check confirms 0 rows. |
| D13 | Claude drafts the CLAUDE.md and SPEC.md edits. They are committed only after review. |

Additions:
- **Cancelling after pickup:** a rider cannot cancel after pickup except through an admin.
- **Which trips count:** a trip with a confirmed payment counts toward the 4-trip cycle however it ends.
- **False disputes:**
  - when an admin finds a dispute false, it is recorded against the user who raised it (rider or customer);
  - after 3 false disputes, the user is flagged for admin review.
- **Recording commission payments:** an admin must fill in a free-text "recorded by" and "note" with every payment recorded.

Build order, one branch and PR each, with pgTAP tests and hosted read-only pre-push checks, and with no edits to applied migrations:
1. **Cleanup:**
   - this proposal;
   - SPEC.md and CLAUDE.md drafts;
   - drop the wallet, withdrawal and payment objects and `min_withdrawal_kobo`.
2. **Rider bank account:**
   - its own table, written only by the server or an admin;
   - name check and admin approval;
   - unique plate check;
   - drop `rider_details.bank_account_ref`.
3. **Commission ledger:**
   - the 4-trip cycle and the due state;
   - the going-online block in the database;
   - admin payment recording and reversing entries;
   - `commission_percent` replaced by `commission_bps`.

Price values (`base_fee_kobo` and `per_km_rate_kobo` = 60000) are set in the pricing/ordering step.

---

## Summary of the new model

| | Old (SPEC today) | New |
|---|---|---|
| Who the customer pays | Company, via a Paystack virtual account | **The rider**, by bank transfer to the rider's own account, at delivery |
| Who confirms payment | Paystack webhook | **The rider** (they can see their own bank alert); customer can report "I paid" |
| Rider earnings | Wallet credited (price − commission), withdraw via Paystack Transfers | Rider keeps the whole fare; no wallet, no withdrawals |
| Commission | Deducted before crediting the wallet | **Owed by the rider**: 15% per delivered trip, paid every 4 trips by bank transfer to the company |
| Price | base + per-km, values undecided | ₦600 base + ₦600/km (60000 + 60000 kobo), in `app_settings` |

This **contradicts CLAUDE.md**, which only you can edit:
- non-negotiable rules 3 and 4;
- the Payments stack line;
- the wallet and webhook money rules.

The CLAUDE.md changes are listed in §1.3. They are part of approving this proposal.

---

## 1. What changes

### 1.1 SPEC.md, section by section

| Section | Change |
|---|---|
| §1 Overview | Replace "All transactions start and end inside the app" with: orders, prices and payment confirmation happen in the app. Money moves directly from the customer to the rider's bank account. Riders pay the company's commission by bank transfer. |
| §2 Roles | **Customer:** "pay the rider by bank transfer at delivery", not "via generated account number". **Rider:** "receive payment directly; pay accrued commission every N trips", not "earn into wallet, withdraw". **Admin:** "record commission payments, verify rider bank accounts, resolve payment disputes", not "monitor payouts". |
| §3.1 Customer | Step 6 is rewritten: after the rider accepts, the app shows the rider's verified account (bank, number, name), the exact amount and a payment reference. The customer transfers at delivery and can tap "I've paid". Remove "The customer never pays the rider". |
| §3.2 Rider | **Step 1:** add bank account (bank and account number) at registration. **Step 5:** the rider confirms receipt in the app after checking their own bank alert. **Step 6:** replaced by commission accrual and the 4-trip cycle. |
| §3.3 Rider wallet | **Removed.** Replaced by a new §3.3 "Rider commission", covering the ledger, the cycle, how to pay, and being blocked until paid. |
| §4 Functional | **Removed:** "Payment via generated account number; webhook confirmation", "Rider wallet and bank withdrawals", "payouts". **Added:** rider bank account capture and verification, commission ledger, payment confirmation and disputes. |
| §5 Status flow | Payment happens between arrival and handover; see §4 of this proposal. `payment_failed` stays (customer refused to pay and the goods went back). |
| §6 Data model | Remove `payments`, `wallet_entries`, `withdrawals` and `bank_account_ref`. Add `rider_bank_accounts`, `commission_cycles`, `commission_entries` and `order_payment_disputes`. Change the `orders` and `app_settings` columns. |
| §7 Non-functional | "verified, idempotent webhooks" no longer applies to payments. The compliance line changes: the company no longer holds customer funds. Check whether commission needs a receipt or VAT treatment (decision D10). |
| §9 Open questions | Q7 (minimum withdrawal) is gone. Q1 and Q2 are answered. |
| §10 Pilot decisions | **10.2:** add ₦600 base fee and ₦600/km. **10.3:** 15%, owed every 4 delivered trips. **10.4:** rewritten for direct payment. **10.5:** kept; "settled" means confirmed by the rider or resolved by an admin. **10.8:** removed. **New 10.9:** commission payment by bank transfer with a reference code, recorded by an admin in the SQL Editor. |

### 1.2 Database objects

All changes go in **new** migrations. The three applied migrations are not edited.

**Remove** (all empty on hosted; the pre-push check will confirm 0 rows):

| Object | Defined in | Notes |
|---|---|---|
| table `payments` + `payments_order_id_idx` + policy `payments_select_participant_or_admin` | data model | Paystack VA records |
| table `wallet_entries` + index + policy `wallet_entries_select_own_or_admin` | data model | |
| triggers `wallet_entries_no_update`, `wallet_entries_no_delete`, function `reject_wallet_mutation()` | data model | Replaced by a generic `reject_ledger_mutation()` for the commission ledger |
| table `withdrawals` + index + policy `withdrawals_select_own_or_admin` | data model | |
| enums `payment_record_status`, `wallet_entry_type`, `withdrawal_status` | data model | |
| column `app_settings.min_withdrawal_kobo` | data model | |
| column `rider_details.bank_account_ref` | data model | Replaced by `rider_bank_accounts`. **Existing gap:** `protect_rider_details()` does not check this column, so today a rider can change it freely. Removing it closes the gap. |

**Change:**

| Object | Change |
|---|---|
| `app_settings` | Set `base_fee_kobo = 60000`, `per_km_rate_kobo = 60000`. Replace `commission_percent numeric` with `commission_bps integer` (1500 = 15%) so the maths stays integer. Add `commission_trips_per_cycle integer` (default 4, 1–50). Add `customer_unpaid_flag_after integer` (abandons before admin review; D7). |
| `orders` | Keep `price_kobo` and `commission_kobo`, set by the server only. **Add:** `distance_m`, the pricing snapshot (`base_fee_kobo`, `per_km_rate_kobo`, `commission_bps` at quote time), `payee_account_id` (the rider bank account used for this order, fixed at accept), `payment_reference`, `arrived_at`, `customer_reported_paid_at`, `rider_confirmed_paid_at`. |
| enum `payment_status` | Today it is `unpaid`, `awaiting_payment`, `paid`, `failed`. **Add** `customer_reported_paid` and `disputed`. Postgres cannot drop enum values, so `failed` stays and means refused or never paid. |
| `protect_order_fields()` | Still blocks direct client changes to money and payment fields. Payment steps go through SECURITY DEFINER functions (§4), so the trigger needs no new client paths. |
| `protect_rider_details()` | The go-online check also requires a **verified bank account** and **no unpaid due commission cycle**. It also takes the rider offline when either stops being true. |
| `profiles.has_unsettled_unpaid_order`, `unpaid_abandon_count` | **Replace with derived functions** (`customer_has_unsettled_order(uid)`, a count query). A stored flag can drift from the orders. `flagged_for_admin_review` stays. |
| `types/database.ts` | Regenerated. |

**Tests that depend on removed objects:** `supabase/tests/00_schema_baseline.test.sql`

| Line(s) | What it does | Change |
|---|---|---|
| 23 | Expected table list | Update the list. |
| 61–79 | Wallet append-only checks | Move to the commission ledger. |
| 87 | `app_settings` insert including `min_withdrawal_kobo` and `commission_percent` | Update the columns. |
| 121–123 | `payment_status = 'paid'` refused for clients | Keep. |
| 147–150 | Client cannot write to the wallet | Move to the commission ledger. |

`01_rider_kyc` and `02_rider_online_location` insert orders with `price_kobo`/`commission_kobo` = 0. They should still pass. Some need a verified bank account seeded once going online requires one.

**Not affected:**
- No Paystack code exists yet: no webhook, no Edge Function.
- `send-sms` does not change.
- The app has no wallet or payment screens yet.

### 1.3 CLAUDE.md (your file, for you to edit)

- **Stack:** "Payments: none in the pilot. Customers pay riders directly by bank transfer. Paystack is used only to look up account names" (if D3 = Paystack), or remove the line.
- **Rule 3:** "Customers pay the rider directly into the rider's verified bank account, shown in the app only after the rider accepts."
- **Rule 4:** "Riders keep the fare. Commission accrues per delivered trip in an append-only ledger. After N delivered trips the rider must pay it before going online again."
- **Money rules:**
  - "The wallet is an append-only ledger" becomes "The commission ledger is an append-only ledger".
  - Remove the webhook rule for now. Keep "server-side only", "integers in kobo" and "tests for every money change".

---

## 2. Commission ledger

### 2.1 Tables

**`commission_cycles`**: one row per rider per batch of N trips.

| Column | Notes |
|---|---|
| `id`, `rider_id`, `cycle_no` | Unique `(rider_id, cycle_no)`. |
| `trips_required` | Snapshot of `commission_trips_per_cycle` when the cycle opens, so a settings change doesn't move a cycle's target. |
| `trip_count` | Delivered trips in this cycle. |
| `status` | `open` → `due` → `paid`. |
| `reference_code` | Unique, e.g. `DSP-R0042-C007`. The rider writes it in the transfer narration. |
| `opened_at`, `due_at`, `paid_at` | |

**`commission_entries`**: append-only ledger. Updates and deletes are rejected by trigger, like the old wallet.

| Column | Notes |
|---|---|
| `id`, `rider_id`, `cycle_id` | |
| `type` | `commission` (+), `payment` (−), `adjustment` (±, admin, reason required). |
| `amount_kobo` | Non-zero bigint. |
| `order_id` | **Unique where `type = 'commission'`**. One order can never accrue twice. |
| `bank_reference` | **Unique where `type = 'payment'`**. The same bank transfer can't be recorded twice. |
| `balance_after_kobo` | The rider's running amount owed. |
| `recorded_by`, `note`, `created_at` | |

There is no stored balance anywhere. "Amount owed" is the latest `balance_after_kobo`, and it can always be recomputed from `sum(amount_kobo)`.

### 2.2 A delivered trip creates an entry

- An `AFTER UPDATE OF status ON orders` trigger fires when status becomes `delivered`. It calls the SECURITY DEFINER function `accrue_commission(order_id)`, with an explicit `search_path` and EXECUTE revoked from public, anon and authenticated.
- The function locks the rider's open cycle (`FOR UPDATE`), or opens a new one.
- It inserts a `commission` entry for the order's `commission_kobo`:
  - `commission_kobo` = `round_half_up(price_kobo × commission_bps / 10000)`, fixed when the price is quoted.
  - Example: a ₦1,800 trip (2 km) gives ₦270 commission (180000 × 1500 / 10000 = 27000 kobo).
- It increments `trip_count`.
- When `trip_count = trips_required`, it sets the cycle to `due` and **sets the rider offline** in the same transaction. The existing trigger then deletes their location.
- **Cancelled trips don't count.** Cancellation states never reach `delivered`, so they never accrue.
- Idempotent: the unique `order_id` means a retried trigger or a duplicate status update can't double-charge.

### 2.3 Paying and recording a payment

- The rider's home screen shows the amount owed, trips in this cycle (e.g. "3 of 4"), the company account and the reference code.
- The rider transfers. An admin sees the transfer in the company bank app and runs this in the SQL Editor:

```sql
SELECT public.record_commission_payment(
  p_reference_code => 'DSP-R0042-C007',
  p_amount_kobo    => 108000,
  p_bank_reference => '<bank transaction id>',
  p_paid_at        => '2026-11-24 10:12+01',
  p_note           => null);
```

What the function does:
- It is admin or `service_role` only, SECURITY DEFINER, with EXECUTE revoked from public, anon and authenticated.
- It finds the cycle by reference code and inserts a `payment` entry (negative amount).
- When the rider's balance reaches ≤ 0, it marks the cycle `paid`, and the rider may go online.
- Partial payments reduce the balance but keep the block. Overpayment leaves a credit that the next trips use up (D5).

Mistakes are corrected with `reverse_commission_payment(entry_id, reason)`:
- it inserts an opposite entry;
- it sets the cycle back to `due` if the balance is above 0;
- it never edits or deletes an entry.

The docs will include a ready-to-paste admin query for "riders who owe, oldest first".

### 2.4 Blocked from going online (enforced in the database)

- `protect_rider_details()`, the trigger that already enforces KYC and role rules, refuses `is_online = true` when `rider_has_commission_due(user_id)`. That function checks for any cycle with `status = 'due'`.
- The future accept-order function checks the same thing, so a rider can't take an order between the 4th delivery and the forced offline.
- `trips_per_cycle` and `commission_bps` live in `app_settings`, editable by admin. Changes apply from the **next** cycle (trips) and the **next** quote (rate).
- The app shows a friendly message for the new error, like the existing "cannot go online" message.

---

## 3. Rider receiving account

### 3.1 Capture

- New KYC step "Where customers pay you": pick a bank from a fixed list (bank name and CBN code), then enter the 10-digit account number.
- The NUBAN check digit is validated in the app and again on the server. This catches most typos before any lookup.
- Existing approved test riders add it from the home screen. They can't go online until it is verified.

### 3.2 Verification (account name match)

Table **`rider_bank_accounts`**:

| Column | Notes |
|---|---|
| `id`, `rider_id`, `bank_code`, `bank_name`, `account_number` | |
| `resolved_account_name` | From the lookup. |
| `name_match` | `match`, `partial` or `mismatch`. |
| `status` | `pending` → `verified` or `rejected`, then `replaced`. |
| `verified_at`, `verified_by`, `rejection_reason`, `created_at` | |

There is a partial unique index allowing at most one `verified` and one `pending` row per rider. Rows are never deleted, so the history stays.

The flow:
- The rider submits through an Edge Function `submit-bank-account`, not a table write. It:
  - validates the NUBAN;
  - looks up the account name (D3: Paystack "Resolve Account Number", which only reads a name and moves no money, or manual);
  - compares that name with `rider_details.full_name`, the KYC name.
- The name comparison:
  - normalises case, punctuation and titles (MR, MRS, ALH…);
  - **match** = surname and at least one other name appear in both, in any order, since Nigerian bank names are often "SURNAME FIRST MIDDLE";
  - **partial** = one shared name;
  - **mismatch** = otherwise.
- For the pilot an admin approves every account, even a `match`, with `approve_rider_bank_account(id)` or `reject_rider_bank_account(id, reason)` (D4). Auto-approving on `match` is a later switch.

### 3.3 Protection from tampering

- RLS: riders can **read** their own rows. There are no INSERT, UPDATE or DELETE policies for anyone but `service_role`. Admin changes go through the functions above.
- A trigger blocks changes to `bank_code`, `account_number` and `resolved_account_name` on existing rows, even for admins. A new account is always a new row that must be verified again.
- **Changing account:**
  - the rider submits again, which creates a new `pending` row;
  - the old verified account stays in use until an admin verifies the new one;
  - the old one then becomes `replaced` in the same transaction.
- On every change, an SMS goes to the rider's phone (D9), in case the phone was taken over.
- Orders snapshot `payee_account_id` at accept, so a change mid-trip can't redirect that order's payment.

### 3.4 When the customer sees it

- **Not** through a table policy. A SECURITY DEFINER function `get_order_payee(order_id)` returns bank name, account number, account name, amount and `payment_reference` **only if**:
  - the caller is that order's customer, and
  - the order status is `accepted`, `picked_up` or `delivered` with payment not yet confirmed.
- After the order is completed, the customer's receipt shows bank name, masked number (`******1234`) and account name only.
- Riders never see each other's accounts. Admins see all.

---

## 4. Payment confirmation without a provider

### 4.1 Flow at delivery

Each step is a SECURITY DEFINER function that checks the caller and the current state. Clients never update `payment_status` directly.

| Step | Who | Function | Effect |
|---|---|---|---|
| 1 | Rider | `rider_arrived(order)` | `arrived_at`, `payment_status = awaiting_payment`. The customer sees the account, the amount and the reference (`payment_reference`, e.g. `DSP-8F3K`, for the narration). |
| 2 | Customer (optional) | `customer_report_paid(order)` | `customer_reported_paid_at`, `payment_status = customer_reported_paid`. This only records the customer's claim; it is not proof of payment. |
| 3 | Rider | `rider_confirm_paid(order)` | After seeing the credit in **their own bank app or bank SMS**, never a screenshot. Sets `rider_confirmed_paid_at`, `payment_status = paid`. |
| 4 | Rider | `mark_delivered(order)` | Allowed only when `paid`, or with the explicit "hand over unpaid" option (D6). Commission accrues here (§2.2). The status goes `delivered`, then `completed` when paid. |

Only the rider can mark an order paid: they are the one who received the money. A rider who falsely says "not paid" gains nothing from the company, and the customer can dispute.

The app tells riders to wait for the real bank credit. Fake transfer alerts and screenshots are a known fraud in Nigeria.

### 4.2 Disputes

Table **`order_payment_disputes`**:

| Column | Notes |
|---|---|
| `id`, `order_id`, `raised_by`, `raised_as` | `raised_as` is `customer` or `rider`. |
| `reason` | `paid_not_acknowledged`, `not_received`, `wrong_amount` or `other`. |
| `customer_claim` | Amount, time and sending bank; free text. |
| `status` | `open`, `resolved_paid`, `resolved_unpaid` or `withdrawn`. |
| `resolution_note`, `resolved_by`, `resolved_at` | |

- **Opening one:** the customer can open one after reporting paid if the rider hasn't confirmed within X minutes. The rider can open one after `awaiting_payment` if no money arrives. Opening sets `payment_status = disputed`. There is one open dispute per order.
- **Resolving one:** the admin uses `resolve_payment_dispute(id, outcome, note)` in the SQL Editor after talking to both sides. Riders can't settle disputes themselves.
  - `resolved_paid`: the order becomes paid.
  - `resolved_unpaid`: the customer stays blocked (§4.3). If the goods were already handed over, the admin may add a commission `adjustment` crediting the rider back (D6).
- Screenshot uploads as evidence are a later feature (D8).

### 4.3 Customer unpaid-order block

- `customer_has_unsettled_order(uid)` is true when the customer has an order with either:
  - status `delivered` and payment not `paid`, or
  - an open dispute raised by the rider, or one resolved as `resolved_unpaid` with no later settlement.
- The `orders` insert check refuses new orders while it is true. The app shows "settle your last order".
- Abandons: an order that ends `payment_failed` (the customer refused and the goods went back) counts against the customer. After `customer_unpaid_flag_after` abandons, `flagged_for_admin_review = true`. The admin decides whether to suspend the customer role (SPEC 10.5, unchanged).

---

## 5. Risks, and what to build first

### 5.1 Risks

| Risk | Impact | Mitigation |
|---|---|---|
| **Off-app deals.** Rider and customer swap numbers and skip the app after the first trip. | Lost commission. This is the biggest weakness of direct payment. | Keep commission modest. Phone numbers are never shown in the app (calls through the app later). Track repeat customer-rider pairs. |
| **Rider marks a trip cancelled after collecting the money**, to avoid commission. | Lost commission. | Cancelling after `picked_up` needs a reason and notifies the customer, who can dispute "I paid and received the goods". Track admin cancellation rates. |
| **Fake transfer alerts** shown by the customer. | Rider loses the fare. | Only the rider confirms, from their own bank. Clear in-app warning. |
| **Customer pays the wrong account**, e.g. from an old order. | Dispute. | Show the account only during the order, with the account name in large text and the order reference. |
| **Rider account takeover** redirects payments. | Customers pay a fraudster. | Admin re-verification, SMS on change, per-order snapshot. |
| **Admin records the wrong payment.** | Wrong block or unblock. | Unique bank reference, append-only entries, reversal function, "owed" query. |
| **Rider creates a second account** to escape debt. | Lost commission. | One phone per account. Admins check plate number and ID at KYC; a database uniqueness check on plate number is a cheap add (D11). |
| **Manual admin load:** every account and every payment is manual. | Slow unblocks: a rider is offline until an admin records the payment. | Fine for an Ede pilot of a few riders. Admins check the company account at fixed times. Automation later. |
| **Price disputes** over distance. | Arguments at delivery. | Price fixed at quote time and shown before confirming. Road vs straight-line distance (D2). |
| **Regulatory.** The company no longer holds customer funds, which is simpler, but commission is company revenue. | Tax and receipts. | Confirm VAT and receipt needs before public launch (D10). |

### 5.2 Build order for the Ede pilot

These are one feature per task, each with its own migration, tests and PR:

1. **Payment model cleanup:**
   - update SPEC.md and CLAUDE.md;
   - migration: drop the wallet, withdrawal and payment objects and `bank_account_ref`, update `app_settings` to the new values;
   - fix the baseline tests.
   - Small, and it removes code that would mislead later work.
2. **Rider bank account:** table, Edge Function, name match, admin approve/reject, KYC step, and the go-online rule.
3. **Commission ledger:**
   - cycles, entries, accrual trigger, block rule;
   - admin record and reverse functions, admin docs.
   - Fully testable in pgTAP with synthetic delivered orders before ordering exists.
4. **Pricing and ordering:** distance, quote and order creation, plus the customer unpaid-order block.
5. **Dispatch and accept:** includes `payee_account_id` and the commission-due check on accept.
6. **Delivery and payment confirmation:** arrived, reported paid, confirmed, delivered, plus disputes.
7. **Rider commission screen:** amount owed, cycle progress, reference code, company account.

Steps 1–3 don't depend on ordering, so they can land before the order flow.

---

## Decisions you need to make

- **D1. Rounding.** Commission is rounded half-up to the kobo. Is the price rounded up to the nearest ₦50 so transfers are easy? Is distance billed per started 100 m, or exact?
- **D2. Distance.** Road distance (Google Routes, costs per call) or straight-line × a factor? It is fixed at quote time either way.
- **D3. Account name lookup.** Paystack "Resolve Account Number" (needs a Paystack secret key, moves no money) or fully manual admin check?
- **D4. Account approval.** Admin approves every rider bank account in the pilot, even a name match? (Recommended: yes.)
- **D5. Commission payments.**
  - Must the full amount be paid to unblock (partial payments allowed but still blocked)?
  - Does overpayment carry forward as credit?
  - Is the rider taken offline **immediately** after the 4th delivery? (Recommended: yes, otherwise a 5th trip can start.)
- **D6. Handover before payment.** Can a rider choose "hand over unpaid"?
  - If yes: commission still accrues at `delivered`, the customer is blocked, and the admin can credit the commission back if the customer never pays.
  - If no: the rider must hold the goods until paid.
- **D7. Customer abandons.** How many before admin review (`customer_unpaid_flag_after`)? How long can an order wait in `awaiting_payment` before the rider can mark it refused?
- **D8. Dispute evidence.** Disputes are text-only in the pilot, with screenshot upload later. Agreed?
- **D9. Bank account change SMS.** Send an SMS when a rider changes their bank account, using Termii (not live yet)? Or in-app only for the pilot?
- **D10. Tax.** Is the 15% VAT-inclusive? Do riders need a commission receipt?
- **D11. Duplicate riders.** Add a unique plate number check to block duplicate rider accounts?
- **D12. Old tables.** Drop the wallet, withdrawal and payment tables (recommended; they are empty), or keep them unused?
- **D13. CLAUDE.md.** You will update rules 3–4 and the money rules (wording in §1.3), or should I draft the edit for your approval?
