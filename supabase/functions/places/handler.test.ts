// Run: deno test (in supabase/functions/places)
import { assert, assertEquals, assertFalse } from 'jsr:@std/assert@1';
import type { Db } from '../_shared/db-types.ts';
import { GoogleError, type GoogleClient } from '../_shared/google.ts';
import { DbError } from '../_shared/http.ts';
import { createPlacesHandler } from './handler.ts';

const AREA = { centerLat: 7.7333, centerLng: 4.4333, radiusM: 10000 };

function setup(over: { user?: string | null; quotaError?: string; googleError?: GoogleError; area?: typeof AREA | null } = {}) {
  const calls: string[] = [];
  const logs: string[] = [];
  const db: Db = {
    useQuota: (_u, kind, n) => {
      calls.push(`quota:${kind}:${n}`);
      return over.quotaError ? Promise.reject(new DbError(over.quotaError)) : Promise.resolve();
    },
    serviceArea: () => Promise.resolve(over.area === undefined ? AREA : over.area),
    createQuote: () => Promise.reject(new Error('not used')),
  };
  const google: GoogleClient = {
    autocomplete: (input, token, area) => {
      calls.push(`autocomplete:${input}:${token}:${area.radiusM}`);
      if (over.googleError) return Promise.reject(over.googleError);
      return Promise.resolve([{ placeId: 'ChIJabc123', mainText: 'Federal Polytechnic Ede', secondaryText: 'Ede, Osun' }]);
    },
    placeDetails: () => Promise.reject(new Error('not used')),
    reverseGeocode: () => Promise.reject(new Error('not used')),
    routeDistanceMeters: () => Promise.reject(new Error('not used')),
  };
  const handler = createPlacesHandler({
    getUserId: () => Promise.resolve(over.user === undefined ? 'user-1' : over.user),
    db,
    google,
    log: (m) => logs.push(m),
  });
  return { handler, calls, logs };
}

function post(body: unknown): Request {
  return new Request('http://localhost/places', { method: 'POST', body: JSON.stringify(body) });
}

const VALID = { input: 'Federal Poly', sessionToken: 'session-token-1' };

Deno.test('returns suggestions, counting the search before calling Google', async () => {
  const { handler, calls } = setup();
  const res = await handler(post(VALID));
  assertEquals(res.status, 200);
  assertEquals((await res.json()).suggestions[0].placeId, 'ChIJabc123');
  assertEquals(calls, ['quota:place_search:1', 'autocomplete:Federal Poly:session-token-1:10000']);
});

Deno.test('requires a signed-in user', async () => {
  const { handler, calls } = setup({ user: null });
  assertEquals((await handler(post(VALID))).status, 401);
  assertEquals(calls, []);
});

Deno.test('rejects short input and bad session tokens without any call', async () => {
  const { handler, calls } = setup();
  assertEquals((await handler(post({ ...VALID, input: 'Fe' }))).status, 400);
  assertEquals((await handler(post({ ...VALID, sessionToken: 'bad token!' }))).status, 400);
  assertEquals((await handler(new Request('http://localhost/places', { method: 'POST', body: '{' }))).status, 400);
  assertEquals(calls, []);
});

Deno.test('over the hourly limit: 429 and Google is not called', async () => {
  const { handler, calls } = setup({ quotaError: 'Too many requests. Try again later.' });
  const res = await handler(post(VALID));
  assertEquals(res.status, 429);
  assertEquals((await res.json()).error, 'Too many requests. Try again later.');
  assertEquals(calls, ['quota:place_search:1']);
});

Deno.test('over the daily Google cap: 503', async () => {
  const { handler } = setup({ quotaError: 'Dispatch is busy right now. Try again later.' });
  assertEquals((await handler(post(VALID))).status, 503);
});

Deno.test('a Google failure is a 502 and the log never contains the search text', async () => {
  const { handler, logs } = setup({ googleError: new GoogleError('places_autocomplete', '403') });
  const res = await handler(post(VALID));
  assertEquals(res.status, 502);
  assertEquals(logs, ['places: places_autocomplete 403']);
  assertFalse(logs.some((l) => l.includes('Federal')));
});

Deno.test('no active service area: 503', async () => {
  const { handler } = setup({ area: null });
  assertEquals((await handler(post(VALID))).status, 503);
});

Deno.test('CORS preflight and wrong method', async () => {
  const { handler } = setup();
  const pre = await handler(new Request('http://localhost/places', { method: 'OPTIONS' }));
  assertEquals(pre.status, 200);
  assert(pre.headers.get('Access-Control-Allow-Origin'));
  await pre.body?.cancel();
  assertEquals((await handler(new Request('http://localhost/places', { method: 'GET' }))).status, 405);
});
