# Dispatch — Project Rules

Read SPEC.md before starting any task. It is the single source of truth for product behaviour.

Precedence when sources disagree:
1. SPEC.md §10 "Pilot decisions (confirmed)" overrides everything else, including earlier sections of SPEC.md.
2. The rest of SPEC.md.
3. This file (operational rules for how to work, not product requirements).
The original PRD (`Delivery App - PRD.docx`, outside this repo) is background only: where it conflicts with SPEC.md (e.g. Lagos, iOS, vehicle types, automated KYC), SPEC.md wins. If SPEC.md is silent on something, ask; do not fill the gap from the PRD.

## What we're building
Dispatch: one mobile app (Android first) where a single account can act as a **customer** (orders deliveries) and/or a **rider** (accepts and delivers orders). Launch market: Nigeria. Pilot: Ede, Osun State only, bikes only (SPEC.md §10.1).

## Stack
- App: React Native + Expo (TypeScript), Expo Router
- Backend: Supabase (Postgres, Auth with phone OTP, Realtime, Edge Functions, Row Level Security)
- Maps/location: Google Maps + Places API (expo-location for rider tracking)
- Payments: Paystack (dedicated virtual accounts for customer payments, Transfers API for rider withdrawals)
- SMS OTP: Termii
- Admin panel: simple Next.js web app (later phase)

## Non-negotiable product rules
1. One phone number = one account. That account can hold both roles (customer and rider).
2. Suspension is **per role**. A suspended rider can still order as a customer. A fraudulent customer is suspended as a customer.
3. Customers NEVER pay riders. All payment goes through the app to the company account.
4. Riders earn into an in-app wallet. Company commission is deducted per completed order; the remainder is credited to the wallet. Riders can withdraw to their bank account anytime.

## Money rules (strict)
- All money logic runs server-side (Edge Functions / database functions). Never trust the client with amounts, balances or payment status.
- Store money as integers in kobo. Never use floats.
- The wallet is an append-only **ledger** (entries with amount, type, order_id, balance_after). Never store or edit a bare balance field.
- Payment webhooks: verify the signature, and make handling idempotent (the same event twice must not credit twice).
- Every money-related change needs tests.

## Working style
- Do ONE feature per task. Before coding, give a short plan and list the files you'll touch.
- Show me any database migration before applying it.
- Enable Row Level Security on every table; write policies explicitly.
- Keep secrets in environment variables; never commit keys.
- Prefer simple, readable code over clever code. Small components, typed props.
- After each task: say what to test manually, and suggest a commit message.
- If a requirement is unclear or missing from SPEC.md, ask me instead of guessing.

## Local environment (Mac, low RAM)
- Container runtime: Colima (not Docker Desktop). Start: colima start --cpu 2 --memory 3. Stop: colima stop.
- Supabase CLI is installed via Homebrew. Prefer `supabase db start` for DB tests; use `supabase start -x studio,imgproxy,logflare,vector` only for auth/Edge Function work.
- Stop everything when finished: supabase stop && colima stop.
- Day-to-day dev uses the hosted Supabase project; CI is the final test gate.
- Do not suggest Docker Desktop or running the full local stack by default.