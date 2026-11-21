// Run: deno test supabase/functions/send-sms/
import { assertEquals, assertRejects, assertStringIncludes } from 'jsr:@std/assert@1';
import { Webhook } from 'npm:standardwebhooks@1.0.0';
import { createSendSmsHandler } from './handler.ts';
import { createTermiiSender } from './termii.ts';

// Random test-only secret, in the same "v1,whsec_<base64>" form Supabase shows.
const secretBase64 = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))));
const hookSecret = `v1,whsec_${secretBase64}`;

function signedRequest(payload: unknown, secret = secretBase64): Request {
  const body = JSON.stringify(payload);
  const id = `msg_${crypto.randomUUID()}`;
  const now = new Date();
  const signature = new Webhook(secret).sign(id, now, body);
  return new Request('http://localhost/send-sms', {
    method: 'POST',
    headers: {
      'webhook-id': id,
      'webhook-timestamp': Math.floor(now.getTime() / 1000).toString(),
      'webhook-signature': signature,
      'Content-Type': 'application/json',
    },
    body,
  });
}

function setup(sendSms?: (to: string, message: string) => Promise<void>) {
  const sent: { to: string; message: string }[] = [];
  const handler = createSendSmsHandler({
    hookSecret,
    sendSms: sendSms ?? (async (to, message) => {
      sent.push({ to, message });
    }),
  });
  return { handler, sent };
}

const validPayload = { user: { phone: '2348031234567' }, sms: { otp: '482913' } };

Deno.test('sends the code for a correctly signed request', async () => {
  const { handler, sent } = setup();
  const res = await handler(signedRequest(validPayload));
  assertEquals(res.status, 200);
  assertEquals(sent.length, 1);
  assertEquals(sent[0].to, '2348031234567');
  assertStringIncludes(sent[0].message, '482913');
});

Deno.test('accepts a phone number with a leading +', async () => {
  const { handler, sent } = setup();
  const res = await handler(
    signedRequest({ ...validPayload, user: { phone: '+2348031234567' } }),
  );
  assertEquals(res.status, 200);
  assertEquals(sent[0].to, '2348031234567');
});

Deno.test('rejects a request signed with the wrong secret', async () => {
  const { handler, sent } = setup();
  const wrong = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))));
  const res = await handler(signedRequest(validPayload, wrong));
  assertEquals(res.status, 401);
  assertEquals(sent.length, 0);
});

Deno.test('rejects an unsigned request', async () => {
  const { handler, sent } = setup();
  const res = await handler(
    new Request('http://localhost/send-sms', { method: 'POST', body: JSON.stringify(validPayload) }),
  );
  assertEquals(res.status, 401);
  assertEquals(sent.length, 0);
});

Deno.test('rejects non-Nigerian numbers without sending', async () => {
  const { handler, sent } = setup();
  const res = await handler(signedRequest({ ...validPayload, user: { phone: '14155550100' } }));
  assertEquals(res.status, 400);
  assertEquals(sent.length, 0);
});

Deno.test('rejects a payload with no code', async () => {
  const { handler, sent } = setup();
  const res = await handler(signedRequest({ user: validPayload.user, sms: {} }));
  assertEquals(res.status, 400);
  assertEquals(sent.length, 0);
});

Deno.test('rejects non-POST requests', async () => {
  const { handler } = setup();
  const res = await handler(new Request('http://localhost/send-sms'));
  assertEquals(res.status, 405);
});

Deno.test('returns a hook error when the SMS provider fails', async () => {
  const { handler } = setup(async () => {
    throw new Error('provider down');
  });
  const res = await handler(signedRequest(validPayload));
  assertEquals(res.status, 502);
  const body = await res.json();
  assertEquals(body.error.http_code, 502);
});

Deno.test('Termii sender posts the expected request', async () => {
  let captured: { url: string; body: Record<string, unknown> } | undefined;
  const fakeFetch = (async (url: string | URL | Request, init?: RequestInit) => {
    captured = { url: String(url), body: JSON.parse(String(init?.body)) };
    return new Response('{"code":"ok"}', { status: 200 });
  }) as typeof fetch;

  const send = createTermiiSender(
    { apiKey: 'test-key', senderId: 'Dispatch', baseUrl: 'https://termii.example/', channel: 'dnd' },
    fakeFetch,
  );
  await send('2348031234567', 'hello');

  assertEquals(captured?.url, 'https://termii.example/api/sms/send');
  assertEquals(captured?.body, {
    api_key: 'test-key',
    to: '2348031234567',
    from: 'Dispatch',
    sms: 'hello',
    type: 'plain',
    channel: 'dnd',
  });
});

Deno.test('Termii sender throws on a non-2xx response', async () => {
  const fakeFetch = (async () => new Response('bad sender id', { status: 400 })) as typeof fetch;
  const send = createTermiiSender(
    { apiKey: 'k', senderId: 'Dispatch', baseUrl: 'https://termii.example', channel: 'dnd' },
    fakeFetch,
  );
  await assertRejects(() => send('2348031234567', 'hi'), Error, 'Termii responded 400');
});
