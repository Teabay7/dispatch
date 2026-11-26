// Price quote for a delivery. The client sends only place ids (or, for "use my
// current location", the device's coordinates); the server looks the places up,
// measures the road distance with ONE Routes call (falling back to straight line
// x 1.3 if it fails), and the database prices and stores the quote. The client
// never sends an address, a distance or a price.
import type { Db } from '../_shared/db-types.ts';
import { fallbackDistanceMeters, isLatLng } from '../_shared/geo.ts';
import { GoogleError, type GoogleClient, type LatLng, type ResolvedPlace } from '../_shared/google.ts';
import { corsHeaders, DbError, dbErrorResponse, errorJson, json } from '../_shared/http.ts';

export type QuoteDeps = {
  getUserId: (req: Request) => Promise<string | null>;
  db: Db;
  google: GoogleClient;
  log?: (message: string) => void;
};

type PlaceInput = { placeId: string; sessionToken: string | null } | { location: LatLng };

const PLACE_ID = /^[A-Za-z0-9_-]{5,300}$/;
const SESSION_TOKEN = /^[A-Za-z0-9_-]{8,100}$/;

/** Most Google calls one quote can make: two place lookups and one route. */
export const GOOGLE_CALLS_PER_QUOTE = 3;

function parsePlace(value: unknown, allowLocation: boolean): PlaceInput | null {
  const v = value as { placeId?: unknown; sessionToken?: unknown; location?: unknown } | null;
  if (!v || typeof v !== 'object') return null;
  if (typeof v.placeId === 'string' && PLACE_ID.test(v.placeId)) {
    const token = typeof v.sessionToken === 'string' && SESSION_TOKEN.test(v.sessionToken) ? v.sessionToken : null;
    return { placeId: v.placeId, sessionToken: token };
  }
  if (allowLocation && isLatLng(v.location)) {
    return { location: { lat: v.location.lat, lng: v.location.lng } };
  }
  return null;
}

export function createQuoteHandler(deps: QuoteDeps): (req: Request) => Promise<Response> {
  const log = deps.log ?? ((m: string) => console.error(m));

  async function resolve(place: PlaceInput): Promise<ResolvedPlace> {
    if ('placeId' in place) return await deps.google.placeDetails(place.placeId, place.sessionToken);
    const address = await deps.google.reverseGeocode(place.location);
    return { ...place.location, address, placeId: null };
  }

  return async (req) => {
    if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
    if (req.method !== 'POST') return errorJson(405, 'Method not allowed');

    const userId = await deps.getUserId(req);
    if (!userId) return errorJson(401, 'Sign in to get a price');

    let body: { pickup?: unknown; dropoff?: unknown };
    try {
      body = await req.json();
    } catch {
      return errorJson(400, 'Invalid request');
    }
    const pickupInput = parsePlace(body.pickup, true);
    const dropoffInput = parsePlace(body.dropoff, false);
    if (!pickupInput || !dropoffInput) return errorJson(400, 'Choose a pickup and a drop-off');

    // Count the request (and refuse it if over a limit) before any paid call.
    try {
      await deps.db.useQuota(userId, 'quote', GOOGLE_CALLS_PER_QUOTE);
    } catch (err) {
      if (err instanceof DbError) return dbErrorResponse(err.message);
      log('quote-order: quota_check_failed');
      return errorJson(500, 'Something went wrong. Please try again.');
    }

    let pickup: ResolvedPlace;
    let dropoff: ResolvedPlace;
    try {
      [pickup, dropoff] = await Promise.all([resolve(pickupInput), resolve(dropoffInput)]);
    } catch (err) {
      log(err instanceof GoogleError ? `quote-order: ${err.api} ${err.status}` : 'quote-order: lookup_error');
      return errorJson(502, 'We could not find one of those places. Choose it again.');
    }

    let distanceM: number;
    let distanceSource: 'routes' | 'straight_line_fallback';
    try {
      distanceM = Math.round(await deps.google.routeDistanceMeters(pickup, dropoff));
      distanceSource = 'routes';
    } catch (err) {
      log(err instanceof GoogleError ? `quote-order: ${err.api} ${err.status} (fallback)` : 'quote-order: routes_error (fallback)');
      distanceM = fallbackDistanceMeters(pickup, dropoff);
      distanceSource = 'straight_line_fallback';
    }

    try {
      const quote = await deps.db.createQuote({ customerId: userId, pickup, dropoff, distanceM, distanceSource });
      return json(200, {
        quote: {
          id: quote.id,
          pickupAddress: quote.pickup_address,
          dropoffAddress: quote.dropoff_address,
          distanceM: quote.distance_m,
          priceKobo: quote.price_kobo,
          pricedWithFallback: quote.distance_source === 'straight_line_fallback',
          expiresAt: quote.expires_at,
        },
      });
    } catch (err) {
      if (err instanceof DbError) return dbErrorResponse(err.message);
      log('quote-order: create_quote_failed');
      return errorJson(500, 'Something went wrong. Please try again.');
    }
  };
}
