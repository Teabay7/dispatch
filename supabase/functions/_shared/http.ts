// Small HTTP helpers shared by the Edge Functions.

export const corsHeaders: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

export function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

export function errorJson(status: number, message: string): Response {
  return json(status, { error: message });
}

// Messages raised by the database that are safe to pass to the app, with a status.
// Anything else becomes a generic 500, so internal details never reach the client.
const KNOWN_DB_ERRORS: [string, number][] = [
  ['Too many requests. Try again later.', 429],
  ['Dispatch is busy right now. Try again later.', 503],
  ['An active customer account is required to order', 403],
  ['The pickup point is outside the Dispatch service area', 422],
  ['The drop-off point is outside the Dispatch service area', 422],
  ['This delivery is longer than the maximum distance', 422],
  ['Pickup and drop-off must be different places', 422],
];

export function dbErrorResponse(message: string | undefined): Response {
  const known = KNOWN_DB_ERRORS.find(([m]) => message?.includes(m));
  return known ? errorJson(known[1], known[0]) : errorJson(500, 'Something went wrong. Please try again.');
}

/** Thrown by the database layer; carries the Postgres error message (never logged). */
export class DbError extends Error {}
