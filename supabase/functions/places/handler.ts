// Place search for the order screen: Google Places Autocomplete, restricted to the
// active service area. The Google key never leaves the server. Every request is
// counted (per-user hourly limit and the daily Google cap) BEFORE calling Google.
import type { Db } from '../_shared/db-types.ts';
import { GoogleError, type GoogleClient } from '../_shared/google.ts';
import { corsHeaders, DbError, dbErrorResponse, errorJson, json } from '../_shared/http.ts';

export type PlacesDeps = {
  getUserId: (req: Request) => Promise<string | null>;
  db: Db;
  google: GoogleClient;
  log?: (message: string) => void;
};

const SESSION_TOKEN = /^[A-Za-z0-9_-]{8,100}$/;

export function createPlacesHandler(deps: PlacesDeps): (req: Request) => Promise<Response> {
  const log = deps.log ?? ((m: string) => console.error(m));

  return async (req) => {
    if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
    if (req.method !== 'POST') return errorJson(405, 'Method not allowed');

    const userId = await deps.getUserId(req);
    if (!userId) return errorJson(401, 'Sign in to search places');

    let body: { input?: unknown; sessionToken?: unknown };
    try {
      body = await req.json();
    } catch {
      return errorJson(400, 'Invalid request');
    }
    const input = typeof body.input === 'string' ? body.input.trim() : '';
    const sessionToken = typeof body.sessionToken === 'string' ? body.sessionToken : '';
    if (input.length < 3 || input.length > 100) return errorJson(400, 'Type at least 3 characters');
    if (!SESSION_TOKEN.test(sessionToken)) return errorJson(400, 'Invalid request');

    try {
      await deps.db.useQuota(userId, 'place_search', 1);
    } catch (err) {
      if (err instanceof DbError) return dbErrorResponse(err.message);
      log('places: quota_check_failed');
      return errorJson(500, 'Something went wrong. Please try again.');
    }

    try {
      const area = await deps.db.serviceArea();
      if (!area) return errorJson(503, 'Dispatch is not available in any area yet');
      const suggestions = await deps.google.autocomplete(input, sessionToken, area);
      return json(200, { suggestions });
    } catch (err) {
      // Only the API name and status: never the search text.
      log(err instanceof GoogleError ? `places: ${err.api} ${err.status}` : 'places: unexpected_error');
      return errorJson(502, 'Place search is not available right now. Try again.');
    }
  };
}
