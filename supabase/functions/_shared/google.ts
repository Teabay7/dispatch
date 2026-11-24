// Google Maps Platform calls used by the places and quote-order functions.
// The key comes from the GOOGLE_MAPS_API_KEY secret and is only ever sent to Google.
// Never log request bodies or responses: they contain addresses and coordinates.

export type LatLng = { lat: number; lng: number };
export type ServiceArea = { centerLat: number; centerLng: number; radiusM: number };
export type Suggestion = { placeId: string; mainText: string; secondaryText: string };
export type ResolvedPlace = LatLng & { address: string; placeId: string | null };

export interface GoogleClient {
  /** Places API (New) Autocomplete, limited to the service area circle in Nigeria. */
  autocomplete(input: string, sessionToken: string, area: ServiceArea): Promise<Suggestion[]>;
  /** Places API (New) Place Details: address and coordinates. */
  placeDetails(placeId: string, sessionToken: string | null): Promise<ResolvedPlace>;
  /** Geocoding API reverse lookup for "use my current location". */
  reverseGeocode(point: LatLng): Promise<string>;
  /** Routes API: driving distance in metres (one call). */
  routeDistanceMeters(origin: LatLng, destination: LatLng): Promise<number>;
}

/** A failed Google call. `status` is the HTTP status or a short code; safe to log. */
export class GoogleError extends Error {
  constructor(readonly api: string, readonly status: string) {
    super(`${api} failed (${status})`);
  }
}

type FetchFn = typeof fetch;

export function createGoogleClient(options: {
  apiKey: string;
  fetchFn?: FetchFn;
  timeoutMs?: number;
}): GoogleClient {
  const fetchFn = options.fetchFn ?? fetch;
  const timeoutMs = options.timeoutMs ?? 5000;

  async function call(api: string, url: string, init: RequestInit): Promise<unknown> {
    let res: Response;
    try {
      res = await fetchFn(url, { ...init, signal: AbortSignal.timeout(timeoutMs) });
    } catch (err) {
      throw new GoogleError(api, err instanceof DOMException && err.name === 'TimeoutError' ? 'timeout' : 'network');
    }
    if (!res.ok) {
      await res.body?.cancel();
      throw new GoogleError(api, String(res.status));
    }
    return await res.json();
  }

  const keyHeaders = (fieldMask?: string): HeadersInit => ({
    'Content-Type': 'application/json',
    'X-Goog-Api-Key': options.apiKey,
    ...(fieldMask ? { 'X-Goog-FieldMask': fieldMask } : {}),
  });

  return {
    async autocomplete(input, sessionToken, area) {
      const body = {
        input,
        sessionToken,
        includedRegionCodes: ['ng'],
        locationRestriction: {
          circle: {
            center: { latitude: area.centerLat, longitude: area.centerLng },
            radius: Math.min(area.radiusM, 50000),
          },
        },
      };
      const data = (await call('places_autocomplete', 'https://places.googleapis.com/v1/places:autocomplete', {
        method: 'POST',
        headers: keyHeaders(),
        body: JSON.stringify(body),
      })) as {
        suggestions?: {
          placePrediction?: {
            placeId?: string;
            text?: { text?: string };
            structuredFormat?: { mainText?: { text?: string }; secondaryText?: { text?: string } };
          };
        }[];
      };
      return (data.suggestions ?? [])
        .map((s) => s.placePrediction)
        .filter((p): p is NonNullable<typeof p> => !!p?.placeId)
        .slice(0, 5)
        .map((p) => ({
          placeId: p.placeId!,
          mainText: p.structuredFormat?.mainText?.text ?? p.text?.text ?? '',
          secondaryText: p.structuredFormat?.secondaryText?.text ?? '',
        }));
    },

    async placeDetails(placeId, sessionToken) {
      const url = new URL(`https://places.googleapis.com/v1/places/${encodeURIComponent(placeId)}`);
      if (sessionToken) url.searchParams.set('sessionToken', sessionToken);
      const data = (await call('place_details', url.toString(), {
        method: 'GET',
        headers: keyHeaders('formattedAddress,location,displayName'),
      })) as {
        formattedAddress?: string;
        displayName?: { text?: string };
        location?: { latitude?: number; longitude?: number };
      };
      const lat = data.location?.latitude;
      const lng = data.location?.longitude;
      if (typeof lat !== 'number' || typeof lng !== 'number') throw new GoogleError('place_details', 'no_location');
      const name = data.displayName?.text?.trim();
      const formatted = data.formattedAddress?.trim() ?? '';
      // "Federal Polytechnic Ede, Ede-Osogbo Rd, Ede" reads better than the address alone.
      const address = name && !formatted.startsWith(name) ? `${name}, ${formatted}` : formatted || name || '';
      if (!address) throw new GoogleError('place_details', 'no_address');
      return { address, lat, lng, placeId };
    },

    async reverseGeocode(point) {
      const url = new URL('https://maps.googleapis.com/maps/api/geocode/json');
      url.searchParams.set('latlng', `${point.lat},${point.lng}`);
      url.searchParams.set('key', options.apiKey);
      const data = (await call('geocode', url.toString(), { method: 'GET' })) as {
        status?: string;
        results?: { formatted_address?: string }[];
      };
      const address = data.results?.[0]?.formatted_address?.trim();
      if (data.status !== 'OK' || !address) throw new GoogleError('geocode', data.status ?? 'no_result');
      return address;
    },

    async routeDistanceMeters(origin, destination) {
      const body = {
        origin: { location: { latLng: { latitude: origin.lat, longitude: origin.lng } } },
        destination: { location: { latLng: { latitude: destination.lat, longitude: destination.lng } } },
        travelMode: 'DRIVE',
      };
      const data = (await call('routes', 'https://routes.googleapis.com/directions/v2:computeRoutes', {
        method: 'POST',
        headers: keyHeaders('routes.distanceMeters'),
        body: JSON.stringify(body),
      })) as { routes?: { distanceMeters?: number }[] };
      const meters = data.routes?.[0]?.distanceMeters;
      if (typeof meters !== 'number' || meters <= 0) throw new GoogleError('routes', 'no_route');
      return meters;
    },
  };
}
