// Run: deno test (in supabase/functions/quote-order)
import { assertEquals, assertFalse } from 'jsr:@std/assert@1';
import type { Db, QuoteInput } from '../_shared/db-types.ts';
import { fallbackDistanceMeters } from '../_shared/geo.ts';
import { GoogleError, type GoogleClient, type LatLng } from '../_shared/google.ts';
import { DbError } from '../_shared/http.ts';
import { createQuoteHandler, GOOGLE_CALLS_PER_QUOTE } from './handler.ts';

const PICKUP = { address: 'Ede Central Mosque, Ede', lat: 7.735, lng: 4.436 };
const DROPOFF = { address: 'Federal Polytechnic Ede, Ede', lat: 7.745, lng: 4.445 };
const DEVICE = { lat: 7.7361, lng: 4.4372 };
const SENSITIVE = ['Mosque', 'Polytechnic', 'Okafor Street', '7.73', '4.43', '7.74', '4.44'];

type Options = {
  user?: string | null;
  quotaError?: string;
  detailsError?: GoogleError;
  routeError?: GoogleError;
  dbError?: string;
};

function setup(o: Options = {}) {
  const calls: string[] = [];
  const logs: string[] = [];
  const quotes: QuoteInput[] = [];
  const db: Db = {
    useQuota: (_u, kind, n) => {
      calls.push(`quota:${kind}:${n}`);
      return o.quotaError ? Promise.reject(new DbError(o.quotaError)) : Promise.resolve();
    },
    serviceArea: () => Promise.resolve(null),
    createQuote: (input) => {
      calls.push('createQuote');
      quotes.push(input);
      if (o.dbError) return Promise.reject(new DbError(o.dbError));
      return Promise.resolve({
        id: 'quote-1',
        pickup_address: input.pickup.address,
        dropoff_address: input.dropoff.address,
        distance_m: input.distanceM,
        distance_source: input.distanceSource,
        price_kobo: 205000,
        expires_at: '2026-11-25T10:15:00Z',
      });
    },
  };
  const google: GoogleClient = {
    autocomplete: () => Promise.reject(new Error('not used')),
    placeDetails: (placeId) => {
      calls.push(`details:${placeId}`);
      if (o.detailsError) return Promise.reject(o.detailsError);
      return Promise.resolve(placeId === 'pickup-place' ? { ...PICKUP, placeId } : { ...DROPOFF, placeId });
    },
    reverseGeocode: (_p: LatLng) => {
      calls.push('reverse');
      return Promise.resolve('12 Okafor Street, Ede');
    },
    routeDistanceMeters: () => {
      calls.push('route');
      return o.routeError ? Promise.reject(o.routeError) : Promise.resolve(2349.6);
    },
  };
  const handler = createQuoteHandler({
    getUserId: () => Promise.resolve(o.user === undefined ? 'user-1' : o.user),
    db,
    google,
    log: (m) => logs.push(m),
  });
  return { handler, calls, logs, quotes };
}

function post(body: unknown): Request {
  return new Request('http://localhost/quote-order', { method: 'POST', body: JSON.stringify(body) });
}

const VALID = {
  pickup: { placeId: 'pickup-place', sessionToken: 'session-token-1' },
  dropoff: { placeId: 'dropoff-place', sessionToken: 'session-token-2' },
};

function assertNothingSensitive(logs: string[]) {
  for (const l of logs) for (const s of SENSITIVE) assertFalse(l.includes(s), `log leaked "${s}": ${l}`);
}

Deno.test('quotes with the road distance: counted first, then places, then one route', async () => {
  const { handler, calls, quotes, logs } = setup();
  const res = await handler(post(VALID));
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.quote, {
    id: 'quote-1',
    pickupAddress: PICKUP.address,
    dropoffAddress: DROPOFF.address,
    distanceM: 2350,
    priceKobo: 205000,
    pricedWithFallback: false,
    expiresAt: '2026-11-25T10:15:00Z',
  });
  assertEquals(calls[0], `quota:quote:${GOOGLE_CALLS_PER_QUOTE}`);
  assertEquals(calls.filter((c) => c === 'route').length, 1);
  assertEquals(calls.at(-1), 'createQuote');
  assertEquals(quotes[0].distanceSource, 'routes');
  assertEquals(quotes[0].pickup.placeId, 'pickup-place');
  assertEquals(logs, []);
});

Deno.test('the client cannot send a price, distance or address: they are ignored', async () => {
  const { handler, quotes } = setup();
  await handler(post({ ...VALID, priceKobo: 1, distanceM: 1, pickup: { ...VALID.pickup, address: 'Fake' } }));
  assertEquals(quotes[0].distanceM, 2350);
  assertEquals(quotes[0].pickup.address, PICKUP.address);
});

Deno.test('if Routes fails, uses straight line x 1.3 and marks the fallback', async () => {
  const { handler, quotes, logs } = setup({ routeError: new GoogleError('routes', 'timeout') });
  const res = await handler(post(VALID));
  assertEquals(res.status, 200);
  assertEquals((await res.json()).quote.pricedWithFallback, true);
  assertEquals(quotes[0].distanceSource, 'straight_line_fallback');
  assertEquals(quotes[0].distanceM, fallbackDistanceMeters(PICKUP, DROPOFF));
  assertEquals(logs, ['quote-order: routes timeout (fallback)']);
});

Deno.test('pickup from the device location is reverse-geocoded on the server', async () => {
  const { handler, calls, quotes } = setup();
  const res = await handler(post({ pickup: { location: DEVICE }, dropoff: VALID.dropoff }));
  assertEquals(res.status, 200);
  assertEquals(calls.includes('reverse'), true);
  assertEquals(quotes[0].pickup, { ...DEVICE, address: '12 Okafor Street, Ede', placeId: null });
});

Deno.test('the drop-off must be a place, not raw coordinates', async () => {
  const { handler, calls } = setup();
  const res = await handler(post({ pickup: VALID.pickup, dropoff: { location: DEVICE } }));
  assertEquals(res.status, 400);
  assertEquals(calls, []);
});

Deno.test('requires a signed-in user and both places', async () => {
  assertEquals((await setup({ user: null }).handler(post(VALID))).status, 401);
  const { handler, calls } = setup();
  assertEquals((await handler(post({ pickup: VALID.pickup }))).status, 400);
  assertEquals((await handler(post({ pickup: { placeId: 'x' }, dropoff: VALID.dropoff }))).status, 400);
  assertEquals((await handler(post({ pickup: { location: { lat: 95, lng: 4 } }, dropoff: VALID.dropoff }))).status, 400);
  assertEquals(calls, []);
});

Deno.test('over the limit: 429 and no Google call', async () => {
  const { handler, calls } = setup({ quotaError: 'Too many requests. Try again later.' });
  assertEquals((await handler(post(VALID))).status, 429);
  assertEquals(calls, [`quota:quote:${GOOGLE_CALLS_PER_QUOTE}`]);
});

Deno.test('a place lookup failure is a 502 and no quote is made', async () => {
  const { handler, calls, logs } = setup({ detailsError: new GoogleError('place_details', '404') });
  assertEquals((await handler(post(VALID))).status, 502);
  assertFalse(calls.includes('createQuote'));
  assertEquals(logs.every((l) => l === 'quote-order: place_details 404'), true);
});

Deno.test('database refusals pass through with a status; unknown errors stay generic', async () => {
  const outside = await setup({ dbError: 'The drop-off point is outside the Dispatch service area' }).handler(post(VALID));
  assertEquals(outside.status, 422);
  assertEquals((await outside.json()).error, 'The drop-off point is outside the Dispatch service area');

  const tooFar = await setup({ dbError: 'This delivery is longer than the maximum distance' }).handler(post(VALID));
  assertEquals(tooFar.status, 422);
  await tooFar.body?.cancel();

  const internal = await setup({ dbError: 'duplicate key value violates unique constraint "x" (Ede Central Mosque)' })
    .handler(post(VALID));
  assertEquals(internal.status, 500);
  assertEquals((await internal.json()).error, 'Something went wrong. Please try again.');
});

Deno.test('no log line ever contains an address or coordinates', async () => {
  const all: string[] = [];
  for (const o of [
    { routeError: new GoogleError('routes', '500') },
    { detailsError: new GoogleError('place_details', 'no_location') },
    { dbError: 'something internal' },
  ] as Options[]) {
    const { handler, logs } = setup(o);
    const res = await handler(post(VALID));
    await res.body?.cancel();
    all.push(...logs);
  }
  const { handler, logs } = setup({ routeError: new GoogleError('routes', '500') });
  await (await handler(post({ pickup: { location: DEVICE }, dropoff: VALID.dropoff }))).body?.cancel();
  all.push(...logs);
  assertNothingSensitive(all);
});
