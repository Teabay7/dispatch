// Entry point for the places Edge Function (verify_jwt = true).
// Secrets (set with `supabase secrets set`, never committed):
//   GOOGLE_MAPS_API_KEY   server key with Places API (New), Routes API and Geocoding API
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase.
import { createGoogleClient } from '../_shared/google.ts';
import { adminClient, createDb, createGetUserId, requireEnv } from '../_shared/supabase.ts';
import { createPlacesHandler } from './handler.ts';

const client = adminClient();

Deno.serve(
  createPlacesHandler({
    getUserId: createGetUserId(client),
    db: createDb(client),
    google: createGoogleClient({ apiKey: requireEnv('GOOGLE_MAPS_API_KEY') }),
  }),
);
