// Entry point for the Supabase Auth Send SMS hook.
// Secrets (set with `supabase secrets set`, never committed):
//   SEND_SMS_HOOK_SECRET  from Dashboard > Authentication > Hooks (v1,whsec_...)
//   TERMII_API_KEY, TERMII_SENDER_ID, TERMII_BASE_URL
//   TERMII_CHANNEL        optional, "dnd" (default) or "generic"
import { createSendSmsHandler } from './handler.ts';
import { createTermiiSender } from './termii.ts';

function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`send-sms: missing secret ${name}`);
  return value;
}

const channel = Deno.env.get('TERMII_CHANNEL') === 'generic' ? 'generic' : 'dnd';

Deno.serve(
  createSendSmsHandler({
    hookSecret: requireEnv('SEND_SMS_HOOK_SECRET'),
    sendSms: createTermiiSender({
      apiKey: requireEnv('TERMII_API_KEY'),
      senderId: requireEnv('TERMII_SENDER_ID'),
      baseUrl: requireEnv('TERMII_BASE_URL'),
      channel,
    }),
  }),
);
