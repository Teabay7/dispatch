// Supabase Auth "Send SMS" hook: verifies the request came from Supabase Auth,
// then sends the OTP through the injected SMS sender (Termii in production).
import { Webhook } from 'npm:standardwebhooks@1.0.0';

export type SendSms = (to: string, message: string) => Promise<void>;

type HookPayload = {
  user?: { phone?: string };
  sms?: { otp?: string };
};

// Pilot is Nigeria only. Refusing other numbers also blocks SMS-pumping abuse.
const NIGERIAN_MOBILE = /^234[789][01]\d{8}$/;

export function buildOtpMessage(otp: string): string {
  return `Your Dispatch code is ${otp}. Do not share this code with anyone.`;
}

function hookError(status: number, message: string): Response {
  return new Response(JSON.stringify({ error: { http_code: status, message } }), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

export function createSendSmsHandler(options: {
  hookSecret: string;
  sendSms: SendSms;
}): (req: Request) => Promise<Response> {
  // Supabase shows the secret as "v1,whsec_<base64>"; the library wants the base64 part.
  const webhook = new Webhook(options.hookSecret.replace(/^v1,whsec_/, ''));

  return async (req) => {
    if (req.method !== 'POST') {
      return hookError(405, 'Method not allowed');
    }

    const body = await req.text();
    let payload: HookPayload;
    try {
      payload = webhook.verify(body, Object.fromEntries(req.headers)) as HookPayload;
    } catch {
      return hookError(401, 'Invalid hook signature');
    }

    const phone = payload.user?.phone?.replace(/^\+/, '');
    const otp = payload.sms?.otp;
    if (!phone || !otp) {
      return hookError(400, 'Missing phone number or code');
    }
    if (!NIGERIAN_MOBILE.test(phone)) {
      return hookError(400, 'Only Nigerian mobile numbers are supported');
    }

    try {
      await options.sendSms(phone, buildOtpMessage(otp));
    } catch (error) {
      // Never log the phone number or the code.
      console.error('send-sms: SMS provider failed:', error instanceof Error ? error.message : error);
      return hookError(502, 'Could not send the SMS. Please try again.');
    }

    return new Response('{}', { status: 200, headers: { 'Content-Type': 'application/json' } });
  };
}
