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
- Payments: no payment provider in the pilot. Customers pay riders directly by bank transfer; riders pay commission by bank transfer to the company account, recorded by an admin. Paystack is used only for optional bank account-name lookup, behind a setting, with the secret key in Supabase secrets.
- SMS OTP: Termii
- Admin panel: simple Next.js web app (later phase)

## Non-negotiable product rules
1. One phone number = one account. That account can hold both roles (customer and rider).
2. Suspension is **per role**. A suspended rider can still order as a customer. A fraudulent customer is suspended as a customer.
3. Customers pay the rider directly, by bank transfer into the rider's verified bank account, shown in the app only after the rider accepts. The company never holds customer money.
4. Riders keep the fare. Company commission accrues per counted trip in an append-only commission ledger. After N counted trips (a cycle) the rider must pay the amount owed before going online again; the database enforces this.

## Money rules (strict)
- All money logic runs server-side (Edge Functions / database functions). Never trust the client with amounts, balances or payment status.
- Store money as integers in kobo. Never use floats.
- The commission ledger is append-only (entries with amount, type, order_id, balance_after). Never store or edit a bare balance field; correct mistakes with reversing entries.
- Only the rider (or an admin resolving a dispute) can mark an order paid, and only through server-side functions. Clients never set payment status directly.
- Recording the same order or the same bank transfer twice must not count twice (unique keys, idempotent functions).
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