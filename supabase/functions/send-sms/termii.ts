// Minimal Termii SMS client. Docs: https://developers.termii.com/messaging-api
import type { SendSms } from './handler.ts';

export type TermiiConfig = {
  apiKey: string;
  senderId: string;
  /** Account-specific base URL shown in the Termii dashboard, e.g. https://v3.api.termii.com */
  baseUrl: string;
  /** "dnd" reaches numbers on Nigeria's Do-Not-Disturb list; needed for OTPs. */
  channel: 'dnd' | 'generic';
};

export function createTermiiSender(config: TermiiConfig, fetchFn: typeof fetch = fetch): SendSms {
  const url = `${config.baseUrl.replace(/\/+$/, '')}/api/sms/send`;

  return async (to, message) => {
    const res = await fetchFn(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        api_key: config.apiKey,
        to,
        from: config.senderId,
        sms: message,
        type: 'plain',
        channel: config.channel,
      }),
    });

    if (!res.ok) {
      const detail = (await res.text()).slice(0, 200);
      throw new Error(`Termii responded ${res.status}: ${detail}`);
    }
  };
}
