// Pure helpers for going online and sending the rider's location.
// No Expo imports here, so they can be unit-tested with node --test.

/** Options for the foreground location watch (battery-friendly, idle rider). */
export const LOCATION_WATCH = {
  /** Android: minimum time between position updates. */
  timeIntervalMs: 30_000,
  /** Only report a new position after moving this far. */
  distanceIntervalM: 50,
} as const;

/** When a new position is worth sending to the server. */
export const SEND_RULES = {
  /** Never send more often than this. */
  minIntervalMs: 30_000,
  /** Send after moving at least this far (and minIntervalMs has passed). */
  minDistanceM: 50,
  /** Send at least this often, even when not moving, so the rider does not look stale. */
  heartbeatMs: 120_000,
  /** Do not re-send a position older than this (no fresh fix = let the rider go stale). */
  maxFixAgeMs: 240_000,
} as const;

export type SendRules = typeof SEND_RULES;

export type Fix = { lat: number; lng: number; accuracyM: number | null; at: number };
export type Sent = { lat: number; lng: number; at: number };

const EARTH_RADIUS_M = 6_371_000;

/** Great-circle distance in metres (haversine). */
export function distanceMeters(a: { lat: number; lng: number }, b: { lat: number; lng: number }): number {
  const toRad = (deg: number) => (deg * Math.PI) / 180;
  const dLat = toRad(b.lat - a.lat);
  const dLng = toRad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_RADIUS_M * Math.asin(Math.min(1, Math.sqrt(h)));
}

/** Should this new position be sent, given the last one the server accepted? */
export function shouldSendLocation(last: Sent | null, next: Fix, rules: SendRules = SEND_RULES): boolean {
  if (!last) return true;
  const elapsed = next.at - last.at;
  if (elapsed >= rules.heartbeatMs) return true;
  if (elapsed < rules.minIntervalMs) return false;
  return distanceMeters(last, next) >= rules.minDistanceM;
}

/**
 * Should the heartbeat re-send the latest position now? Only when a heartbeat is due
 * and the position is recent: without a fresh fix (GPS lost, location turned off)
 * we stop sending, so the server sets the rider offline after the stale window.
 */
export function shouldSendHeartbeat(
  last: Sent | null,
  latestFix: Fix | null,
  now: number,
  rules: SendRules = SEND_RULES,
): boolean {
  if (!latestFix) return false;
  if (now - latestFix.at > rules.maxFixAgeMs) return false;
  if (!last) return true;
  return now - last.at >= rules.heartbeatMs;
}

// ---------------------------------------------------------------------------
// Permission and location-services state
// ---------------------------------------------------------------------------

export type PermissionInput = {
  status: 'granted' | 'denied' | 'undetermined';
  canAskAgain: boolean;
  /** Android 12+: 'coarse' when the user picked "Approximate". */
  androidAccuracy?: 'fine' | 'coarse' | 'none' | null;
};

export type LocationAccess =
  | 'ready'
  | 'needs_permission' // never asked
  | 'denied' // refused, can ask again
  | 'blocked' // refused with "Don't ask again": only Settings can fix it
  | 'approximate_only' // granted, but only approximate location
  | 'services_off'; // device location is turned off

export function mapLocationAccess(permission: PermissionInput, servicesEnabled: boolean): LocationAccess {
  if (permission.status === 'undetermined') return 'needs_permission';
  if (permission.status === 'denied') return permission.canAskAgain ? 'denied' : 'blocked';
  if (permission.androidAccuracy === 'coarse') return 'approximate_only';
  if (!servicesEnabled) return 'services_off';
  return 'ready';
}

/** Should we show the system permission prompt (again)? */
export function shouldRequestPermission(permission: PermissionInput): boolean {
  if (permission.status === 'undetermined') return true;
  if (permission.status === 'denied') return permission.canAskAgain;
  // "Approximate" can be upgraded to precise from the prompt on Android 12+.
  return permission.androidAccuracy === 'coarse' && permission.canAskAgain;
}

export type AccessAction = 'retry' | 'open_settings' | 'enable_services';

export function locationAccessMessage(
  access: Exclude<LocationAccess, 'ready'>,
): { message: string; action: AccessAction; actionLabel: string } {
  switch (access) {
    case 'needs_permission':
    case 'denied':
      return {
        message: 'Dispatch needs your location to put you online. Choose "While using the app" and "Precise".',
        action: 'retry',
        actionLabel: 'Allow location',
      };
    case 'blocked':
      return {
        message:
          'Location permission is turned off for Dispatch. Open Settings, tap Permissions → Location, and choose "Allow only while using the app" with "Use precise location" on.',
        action: 'open_settings',
        actionLabel: 'Open settings',
      };
    case 'approximate_only':
      return {
        message:
          'Dispatch needs your precise location to send you nearby deliveries. Approximate location can be kilometres off. Turn on "Use precise location" in Settings.',
        action: 'open_settings',
        actionLabel: 'Open settings',
      };
    case 'services_off':
      return {
        message: 'Your phone\'s location is turned off. Turn it on to go online.',
        action: 'enable_services',
        actionLabel: 'Turn on location',
      };
  }
}

// ---------------------------------------------------------------------------
// Server errors
// ---------------------------------------------------------------------------

/** The server refused: offline, suspended, not approved, or not this rider. Stop sending. */
export function isAccessRefused(error: { code?: string | null; message?: string | null }): boolean {
  return error.code === '42501' || /row-level security/i.test(error.message ?? '');
}

export function friendlyOnlineError(error: { code?: string | null; message?: string | null }): string {
  const message = error.message ?? '';
  if (/KYC approved with an active rider role to go online/i.test(message)) {
    return 'You cannot go online: your rider verification is not approved or your rider account is suspended.';
  }
  if (isAccessRefused(error)) {
    return 'You are offline. Your phone stopped sharing its location, or your rider account changed. Go online again if you can.';
  }
  return 'We could not reach Dispatch. Check your connection and try again.';
}
