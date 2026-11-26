// Run: deno test (in supabase/functions/quote-order). Tests the shared Google client
// against a fake fetch: request shape, parsing, and errors.
import { assertEquals, assertRejects } from 'jsr:@std/assert@1';
import { createGoogleClient, GoogleError } from '../_shared/google.ts';
import { fallbackDistanceMeters, haversineMeters } from '../_shared/geo.ts';

type Captured = { url: string; init: RequestInit };

function fakeFetch(responses: (Response | Error)[]) {
  const captured: Captured[] = [];
  const fetchFn = ((input: string | URL | Request, init?: RequestInit) => {
    captured.push({ url: String(input), init: init ?? {} });
    const next = responses.shift()!;
    return next instanceof Error ? Promise.reject(next) : Promise.resolve(next);
  }) as typeof fetch;
  return { fetchFn, captured };
}

const ok = (body: unknown) => new Response(JSON.stringify(body), { status: 200 });
const AREA = { centerLat: 7.7333, centerLng: 4.4333, radiusM: 10000 };

Deno.test('autocomplete: restricted to the service area in Nigeria, key in a header', async () => {
  const { fetchFn, captured } = fakeFetch([
    ok({
      suggestions: [
        { placePrediction: { placeId: 'p1', structuredFormat: { mainText: { text: 'Ede Poly' }, secondaryText: { text: 'Ede' } } } },
        { queryPrediction: { text: { text: 'ignored' } } },
      ],
    }),
  ]);
  const google = createGoogleClient({ apiKey: 'test-key', fetchFn });
  const result = await google.autocomplete('Ede Poly', 'tok-12345678', AREA);
  assertEquals(result, [{ placeId: 'p1', mainText: 'Ede Poly', secondaryText: 'Ede' }]);
  const body = JSON.parse(String(captured[0].init.body));
  assertEquals(body.includedRegionCodes, ['ng']);
  assertEquals(body.locationRestriction.circle, { center: { latitude: 7.7333, longitude: 4.4333 }, radius: 10000 });
  assertEquals(body.sessionToken, 'tok-12345678');
  assertEquals((captured[0].init.headers as Record<string, string>)['X-Goog-Api-Key'], 'test-key');
  assertEquals(captured[0].url.includes('test-key'), false);
});

Deno.test('place details: field mask, session token, name + address', async () => {
  const { fetchFn, captured } = fakeFetch([
    ok({ displayName: { text: 'Federal Polytechnic Ede' }, formattedAddress: 'Ede-Osogbo Rd, Ede', location: { latitude: 7.745, longitude: 4.445 } }),
  ]);
  const place = await createGoogleClient({ apiKey: 'k', fetchFn }).placeDetails('p1', 'tok-12345678');
  assertEquals(place, { address: 'Federal Polytechnic Ede, Ede-Osogbo Rd, Ede', lat: 7.745, lng: 4.445, placeId: 'p1' });
  assertEquals(captured[0].url, 'https://places.googleapis.com/v1/places/p1?sessionToken=tok-12345678');
  assertEquals((captured[0].init.headers as Record<string, string>)['X-Goog-FieldMask'], 'formattedAddress,location,displayName');
});

Deno.test('place details without a location is an error', async () => {
  const { fetchFn } = fakeFetch([ok({ formattedAddress: 'Somewhere' })]);
  await assertRejects(() => createGoogleClient({ apiKey: 'k', fetchFn }).placeDetails('p1', null), GoogleError);
});

Deno.test('reverse geocode: first formatted address; non-OK status is an error', async () => {
  const { fetchFn, captured } = fakeFetch([
    ok({ status: 'OK', results: [{ formatted_address: '12 Okafor Street, Ede' }] }),
    ok({ status: 'ZERO_RESULTS', results: [] }),
  ]);
  const google = createGoogleClient({ apiKey: 'k', fetchFn });
  assertEquals(await google.reverseGeocode({ lat: 7.7361, lng: 4.4372 }), '12 Okafor Street, Ede');
  assertEquals(new URL(captured[0].url).searchParams.get('latlng'), '7.7361,4.4372');
  const err = await assertRejects(() => google.reverseGeocode({ lat: 0, lng: 0 }), GoogleError);
  assertEquals(err.status, 'ZERO_RESULTS');
});

Deno.test('routes: one DRIVE request asking only for the distance', async () => {
  const { fetchFn, captured } = fakeFetch([ok({ routes: [{ distanceMeters: 2350 }] }), ok({ routes: [] })]);
  const google = createGoogleClient({ apiKey: 'k', fetchFn });
  assertEquals(await google.routeDistanceMeters({ lat: 7.735, lng: 4.436 }, { lat: 7.745, lng: 4.445 }), 2350);
  const body = JSON.parse(String(captured[0].init.body));
  assertEquals(body.travelMode, 'DRIVE');
  assertEquals((captured[0].init.headers as Record<string, string>)['X-Goog-FieldMask'], 'routes.distanceMeters');
  const err = await assertRejects(() => google.routeDistanceMeters({ lat: 0, lng: 0 }, { lat: 0, lng: 0 }), GoogleError);
  assertEquals(err.status, 'no_route');
});

Deno.test('HTTP errors, network errors and timeouts become GoogleError with a short status', async () => {
  const timeout = new DOMException('timed out', 'TimeoutError');
  const { fetchFn } = fakeFetch([new Response('denied', { status: 403 }), new TypeError('network down'), timeout]);
  const google = createGoogleClient({ apiKey: 'k', fetchFn });
  const a = await assertRejects(() => google.routeDistanceMeters({ lat: 0, lng: 0 }, { lat: 1, lng: 1 }), GoogleError);
  assertEquals(a.status, '403');
  const b = await assertRejects(() => google.routeDistanceMeters({ lat: 0, lng: 0 }, { lat: 1, lng: 1 }), GoogleError);
  assertEquals(b.status, 'network');
  const c = await assertRejects(() => google.routeDistanceMeters({ lat: 0, lng: 0 }, { lat: 1, lng: 1 }), GoogleError);
  assertEquals(c.status, 'timeout');
});

Deno.test('fallback distance is straight line x 1.3, rounded up', () => {
  const a = { lat: 7.735, lng: 4.436 };
  const b = { lat: 7.745, lng: 4.445 };
  assertEquals(fallbackDistanceMeters(a, b), Math.ceil(haversineMeters(a, b) * 1.3));
  assertEquals(fallbackDistanceMeters(a, a), 0);
});
