# Phone OTP login: setup

How sign-in works: the app calls Supabase Auth with a `+234…` number. Supabase Auth
generates the 6-digit code and calls the **Send SMS hook**, the `send-sms` Edge Function.
The function checks the request really came from Supabase Auth (signed webhook), refuses
non-Nigerian numbers, and sends the code through Termii. Test numbers never reach the hook.

## 1. Termii (termii.com)
1. Create an account and fund it (SMS is prepaid).
2. **Register a Sender ID** (e.g. `Dispatch`, max 11 characters) and wait for approval.
   Say it is for OTP/transactional messages.
3. **Ask Termii to activate the DND route** on your account. Without it, codes will not
   reach numbers on Nigeria's Do-Not-Disturb list, which is many of them.
4. Copy your **API key** and your account's **base URL** (both on the dashboard).

## 2. Supabase dashboard (hosted project)
1. **Authentication → Sign In / Providers → Phone**: turn on.
   - If it insists on a provider, pick any; the Send SMS hook replaces it, so no
     credentials for that provider are used.
   - SMS OTP expiry: 300 seconds (5 minutes) is a sensible pilot value.
   - **Test phone numbers and OTPs**: add
     `2348000000101=123456, 2348000000102=123456, 2348000000103=123456`
     and set an expiry date for them. **Remove them before launch.**
2. **Authentication → Rate Limits**: set the minimum time between SMS sends to **60
   seconds** (matches the app's resend timer) and an hourly SMS cap you are comfortable
   paying for.
3. **Deploy the function** (from the repo root):
   ```
   supabase link --project-ref <your-project-ref>
   supabase functions deploy send-sms --no-verify-jwt
   ```
4. **Authentication → Hooks → Send SMS hook**: add a hook, type **HTTPS**, URL
   `https://<your-project-ref>.supabase.co/functions/v1/send-sms`.
   Click **Generate secret** and copy it (it looks like `v1,whsec_…`).
5. **Set the function's secrets** (never put these in the repo):
   ```
   supabase secrets set SEND_SMS_HOOK_SECRET='v1,whsec_…' TERMII_API_KEY='…' TERMII_SENDER_ID='Dispatch' TERMII_BASE_URL='https://…'
   ```
6. Try a real number in the app. If no SMS arrives, check **Edge Functions → send-sms →
   Logs** (the function logs Termii's error, never the phone number or code).

## 3. Local development
- Day to day, the app talks to the hosted project (`.env`) and you sign in with the test
  numbers above, code `123456`. No SMS is sent.
- For the local stack, create `supabase/.env` (git-ignored) once:
  ```
  echo "SEND_SMS_HOOK_SECRET=v1,whsec_$(openssl rand -base64 32)" > supabase/.env
  ```
  The CLI refuses to start without it, because `config.toml` turns on the hook.
- The local test numbers are in `supabase/config.toml` under `[auth.sms.test_otp]`.
- Hook unit tests: `cd supabase/functions/send-sms && deno test`.
