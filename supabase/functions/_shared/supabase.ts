// Database and auth access for the Edge Functions, using the service role key that
// Supabase injects (SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY). Not imported by tests.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.118.0';
import { DbError } from './http.ts';
import type { Db, QuoteRow } from './db-types.ts';

export function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`missing secret ${name}`);
  return value;
}

export function adminClient(): SupabaseClient {
  return createClient(requireEnv('SUPABASE_URL'), requireEnv('SUPABASE_SERVICE_ROLE_KEY'), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/** The signed-in user's id from the request's JWT, or null. */
export function createGetUserId(client: SupabaseClient) {
  return async (req: Request): Promise<string | null> => {
    const token = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '');
    if (!token) return null;
    const { data, error } = await client.auth.getUser(token);
    return error || !data.user ? null : data.user.id;
  };
}

export function createDb(client: SupabaseClient): Db {
  return {
    async useQuota(userId, kind, googleCalls) {
      const { error } = await client.rpc('use_api_quota', {
        p_user_id: userId,
        p_kind: kind,
        p_google_calls: googleCalls,
      });
      if (error) throw new DbError(error.message);
    },

    async serviceArea() {
      const { data, error } = await client
        .from('service_areas')
        .select('center_lat, center_lng, radius_m')
        .eq('active', true)
        .order('created_at')
        .limit(1)
        .maybeSingle();
      if (error) throw new DbError(error.message);
      return data ? { centerLat: data.center_lat, centerLng: data.center_lng, radiusM: data.radius_m } : null;
    },

    async createQuote(input) {
      const { data, error } = await client
        .rpc('create_order_quote', {
          p_customer_id: input.customerId,
          p_pickup_address: input.pickup.address,
          p_pickup_lat: input.pickup.lat,
          p_pickup_lng: input.pickup.lng,
          p_pickup_place_id: input.pickup.placeId,
          p_dropoff_address: input.dropoff.address,
          p_dropoff_lat: input.dropoff.lat,
          p_dropoff_lng: input.dropoff.lng,
          p_dropoff_place_id: input.dropoff.placeId,
          p_distance_m: input.distanceM,
          p_distance_source: input.distanceSource,
        })
        .single();
      if (error) throw new DbError(error.message);
      return data as QuoteRow;
    },
  };
}
