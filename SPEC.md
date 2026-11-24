# Dispatch — Product Spec (MVP)

## 1. Overview
Dispatch connects customers who need something delivered with nearby riders. It is a single app: users register as a customer, a rider, or both, on one account tied to one phone number. Orders, prices and payment confirmation happen in the app. The customer pays the rider directly, by bank transfer into the rider's verified bank account; the company never holds customer money. Riders pay the company's commission by bank transfer.

## 2. Roles
| Role | Can do |
|---|---|
| Customer | Create delivery orders, see nearby riders, track live, pay the rider by bank transfer at delivery, view history |
| Rider | Go online/offline, receive and accept orders, deliver, receive payment directly into their verified bank account, pay accrued commission every N delivered trips |
| Admin | View orders and users, suspend/reinstate per role, verify rider bank accounts, record commission payments, resolve payment disputes, manage pricing and commission settings |

Rules:
- One phone number = one account, which may hold both roles.
- Suspension applies per role. A suspended rider can still order as a customer. A fraudulent customer is suspended as a customer.

## 3. Core flows

### 3.1 Customer
1. Sign up/log in with phone OTP; choose customer role.
2. Enter pickup and drop-off (map search, Google Places; optional Nigerian postcode).
3. App shows nearby available riders and the delivery price.
4. Customer confirms the order; nearest available rider is notified.
5. Customer tracks the rider live on the map.
6. After the rider accepts, the app shows the rider's verified bank account (bank, account number, account name), the exact amount and a payment reference. At delivery the customer transfers that amount to the rider and may tap "I've paid".
7. Order completes once the rider confirms payment; customer sees receipt and history.

### 3.2 Rider
1. Register as a rider (profile, vehicle type, ID details for KYC, and the bank account customers will pay into).
2. Toggle online/offline; location is shared while online.
3. Receive an order notification; accept if close, or decline/let it time out.
4. Pick up, travel to the drop-off, mark arrived.
5. Confirm payment in the app after seeing the credit in their own bank app or bank SMS (never a screenshot), then hand over and mark delivered.
6. The rider keeps the full price. Commission accrues per trip (see 3.3).

### 3.3 Rider commission
- Commission is a percentage of the trip price, owed by the rider to the company.
- It is kept in an append-only ledger: one entry per counted trip, per payment and per adjustment. The amount owed is derived from the ledger, never stored as a bare balance.
- Trips are counted in cycles of N trips. After the Nth counted trip the cycle is due: the rider is taken offline and cannot go online again until the amount owed is paid.
- The rider pays by bank transfer to the company account, using the cycle's reference code. An admin records the payment.
- Mistakes are corrected with reversing entries, never by editing or deleting entries.
- The rider sees the amount owed, progress in the current cycle, the company account and the reference code.

## 4. Functional requirements (MVP)
- Phone OTP authentication; multi-role accounts with role switcher
- Rider KYC fields captured and reviewable by admin
- Rider bank account captured at registration, name-checked and approved by admin
- Live location for riders; live tracking for customers
- Nearby rider search and order dispatch with accept/decline/timeout and re-dispatch
- Pricing: base fee + per-km, values in the database settings table
- Direct payment to the rider at delivery, confirmed by the rider; payment disputes recorded and resolved by admin
- Commission ledger with N-trip cycles, admin-recorded payments and an online block while commission is due
- Push notifications for order events
- Ratings after delivery (simple 1–5)
- Admin dashboard: users, orders, suspensions, bank account approvals, commission owed and payments, disputes
- Nigerian postcode as an optional address field with a lookup dataset (no reliable public API)

## 5. Order status flow
`created → rider_requested → accepted → picked_up → delivered → completed`
Side exits: `cancelled_by_customer`, `cancelled_by_rider`, `no_rider_found`, `payment_failed`.
Every status change is logged with a timestamp and actor.

Payment happens between `picked_up` and `delivered`: the rider marks arrived, the customer pays, the rider confirms payment, then hands over (`delivered`). `payment_failed` means the customer refused or did not pay and the goods were not handed over.

## 6. Data model (draft)
- `profiles` (id, phone, full_name, created_at)
- `user_roles` (user_id, role, status [active|suspended], suspended_reason)
- `rider_details` (user_id, vehicle_type, kyc_status, is_online)
- `rider_bank_accounts` (id, rider_id, bank_code, account_number, resolved_account_name, name_match, status [pending|verified|rejected|replaced], verified_by, verified_at)
- `rider_locations` (rider_id, lat, lng, updated_at)
- `orders` (id, customer_id, rider_id, pickup, dropoff, distance_m, price_kobo, commission_kobo, status, payment_status, payee_account_id, payment_reference)
- `order_events` (order_id, status, actor_id, created_at)
- `order_payment_disputes` (id, order_id, raised_by, reason, status, resolution_note, resolved_by)
- `commission_cycles` (id, rider_id, cycle_no, trips_required, trip_count, status [open|due|paid], reference_code)
- `commission_entries` (id, rider_id, cycle_id, type [commission|payment|adjustment], amount_kobo, order_id, bank_reference, recorded_by, note, balance_after_kobo, created_at)
- `ratings` (order_id, from_id, to_id, score, comment)

## 7. Non-functional
- Security: Row Level Security on all tables; money logic (prices, commission, ledger, payment status) server-side only.
- Performance: rider location updates every few seconds while on a job, less often while idle.
- Reliability: works on low-end Android devices and patchy networks (retry, offline-tolerant states).
- Compliance: the company does not hold customer funds. Confirm the tax treatment of commission (VAT) and receipt requirements before public launch.

## 8. Out of scope for MVP
Scheduled deliveries, multi-stop orders, promo codes, in-app chat, iOS release, multiple cities.

## 9. Open questions (decide before building the relevant phase)
> All of these are now answered in §10, and §10 wins wherever it gives an answer.

1. Pricing model: flat rate, per-km, or per-km plus base fee?
2. Commission percentage taken from each order?
3. When does the customer pay: before pickup or after delivery? Paying before pickup greatly reduces non-payment fraud.
4. What happens if the customer never pays? (Suspension rules, retry, debt flag.)
5. Cancellation and refund policy, including fees after a rider has accepted.
6. Rider KYC requirements and who approves riders.
7. ~~Minimum withdrawal amount~~ (no longer applies: there are no withdrawals).
8. Pilot area and first vehicle types (bike only?).

## 10. Pilot decisions (confirmed)
1. Pilot area: Ede, Osun State only. Vehicle type: bikes only.
2. Pricing: base fee ₦600 + ₦600 per km, both stored in kobo in the database settings table and editable by admin.
   - Distance is road distance (Google Routes), one call per quote, billed per started 100 m. If the call fails, straight-line distance × 1.3 is used and the order is marked as priced with the fallback.
   - The price is rounded up to the nearest ₦50 and fixed at quote time.
   - Quotes are rate-limited per user.
3. Commission: 15% of the trip price (VAT-inclusive), stored in the database settings table and changeable by admin without a code change. Rounded half-up to the kobo and fixed at quote time.
4. Payment: the customer pays the rider directly at delivery, by bank transfer into the rider's verified bank account. The company never holds customer funds.
   - The rider's account is shown to the customer only after the rider accepts, and only while the order is awaiting payment.
   - Only the rider confirms payment, after seeing it in their own bank app.
   - The rider holds the goods until they confirm payment; there is no "hand over unpaid".
   - A rider can mark an order refused after 15 minutes awaiting payment.
5. Non-payment: an unpaid order stays flagged; the customer cannot place new orders until it is settled (confirmed by the rider or resolved by an admin). A customer is flagged for admin review after 2 abandoned unpaid orders and may be suspended as a customer.
6. Cancellation (final):
   - Before the rider accepts: the customer can cancel freely.
   - After acceptance and before pickup: the customer can cancel, but it counts as a late cancel. After 3 late cancels the customer is flagged for admin review.
   - After pickup: only an admin can cancel. This applies to both customers and riders.
7. Rider approval: an admin manually approves each rider. Required: ID photo, selfie, vehicle details, plate number. Plate numbers are unique (an admin can override for a genuine change of owner). Automated ID verification is a later phase.
8. Rider bank account: captured at registration (bank and account number of exactly 10 digits). An admin approves every account after a name check against the KYC name.
   - The name check is manual first. Paystack account-name lookup is available behind a setting, only once a Paystack secret key is provided in Supabase secrets.
   - Only the server or an admin can write bank accounts. A change creates a new account that must be approved again; the admin phones the rider before approving.
   - A rider cannot go online without a verified account.
9. Commission cycle: commission accrues per delivered trip.
   - A trip with a confirmed payment counts however it ends. Cancelled trips without a confirmed payment do not count.
   - After the 4th counted trip in a cycle (trip count stored in the settings table), the rider is taken offline immediately and cannot go online until the full amount owed is paid.
   - Partial payments are recorded but do not unblock. Overpayment carries forward as credit.
10. Commission payment (pilot): the rider transfers to the company account with the cycle's reference code. An admin records the payment in the SQL Editor, with a free-text "recorded by" and note. The rider sees an in-app receipt for each recorded payment. Automation later.
11. Disputes: recorded per order with a reason (text only in the pilot) and resolved by an admin. A dispute found false is counted against the user who raised it (rider or customer); a user is flagged for admin review after 3.
