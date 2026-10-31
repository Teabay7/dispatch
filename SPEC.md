# Dispatch — Product Spec (MVP)

## 1. Overview
Dispatch connects customers who need something delivered with nearby riders. It is a single app: users register as a customer, a rider, or both, on one account tied to one phone number. All transactions start and end inside the app.

## 2. Roles
| Role | Can do |
|---|---|
| Customer | Create delivery orders, see nearby riders, track live, pay via generated account number, view history |
| Rider | Go online/offline, receive and accept orders, deliver, earn into wallet, withdraw |
| Admin | View orders and users, suspend/reinstate per role, manage commission, monitor payouts |

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
6. App generates a payment account number (Paystack dedicated virtual account) for the customer to pay into the company account. The customer never pays the rider.
7. Order completes; customer sees receipt and history.

### 3.2 Rider
1. Register as a rider (profile, vehicle type, ID details for KYC).
2. Toggle online/offline; location is shared while online.
3. Receive an order notification; accept if close, or decline/let it time out.
4. Pick up, deliver, mark delivered.
5. Payment status is confirmed by the system (provider webhook), and the rider sees it.
6. Earnings (price minus company commission) are credited to the rider wallet.

### 3.3 Rider wallet
- Balance is derived from an append-only ledger.
- Credit on each completed, paid order (net of commission).
- Withdrawal to the rider's saved bank account at any time (Paystack Transfers), subject to available balance.
- Wallet shows transaction history.

## 4. Functional requirements (MVP)
- Phone OTP authentication; multi-role accounts with role switcher
- Rider KYC fields captured and reviewable by admin
- Live location for riders; live tracking for customers
- Nearby rider search and order dispatch with accept/decline/timeout and re-dispatch
- Pricing (see open questions)
- Payment via generated account number; webhook confirmation
- Rider wallet and bank withdrawals
- Push notifications for order events
- Ratings after delivery (simple 1–5)
- Admin dashboard: users, orders, suspensions, payouts
- Nigerian postcode as an optional address field with a lookup dataset (no reliable public API)

## 5. Order status flow
`created → rider_requested → accepted → picked_up → delivered → completed`
Side exits: `cancelled_by_customer`, `cancelled_by_rider`, `no_rider_found`, `payment_failed`.
Every status change is logged with a timestamp and actor.

## 6. Data model (draft)
- `profiles` (id, phone, full_name, created_at)
- `user_roles` (user_id, role, status [active|suspended], suspended_reason)
- `rider_details` (user_id, vehicle_type, kyc_status, bank_account_ref, is_online)
- `rider_locations` (rider_id, lat, lng, updated_at)
- `orders` (id, customer_id, rider_id, pickup, dropoff, price_kobo, commission_kobo, status, payment_status)
- `order_events` (order_id, status, actor_id, created_at)
- `payments` (order_id, provider_ref, virtual_account, amount_kobo, status, raw_webhook_id)
- `wallet_entries` (id, rider_id, type [credit|withdrawal|adjustment], amount_kobo, order_id, balance_after_kobo, created_at)
- `withdrawals` (id, rider_id, amount_kobo, status, provider_ref)
- `ratings` (order_id, from_id, to_id, score, comment)

## 7. Non-functional
- Security: Row Level Security on all tables; money logic server-side only; verified, idempotent webhooks.
- Performance: rider location updates every few seconds while on a job, less often while idle.
- Reliability: works on low-end Android devices and patchy networks (retry, offline-tolerant states).
- Compliance: confirm payment-provider and CBN requirements for holding funds and paying out before public launch.

## 8. Out of scope for MVP
Scheduled deliveries, multi-stop orders, promo codes, in-app chat, iOS release, multiple cities.

## 9. Open questions (decide before building the relevant phase)
1. Pricing model: flat rate, per-km, or per-km plus base fee?
2. Commission percentage taken from each order?
3. When does the customer pay: before pickup or after delivery? Paying before pickup greatly reduces non-payment fraud.
4. What happens if the customer never pays? (Suspension rules, retry, debt flag.)
5. Cancellation and refund policy, including fees after a rider has accepted.
6. Rider KYC requirements and who approves riders.
7. Minimum withdrawal amount, if any, and who bears transfer fees.
8. Pilot area and first vehicle types (bike only?).
