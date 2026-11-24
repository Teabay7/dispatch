import type { LatLng } from './google.ts';

const EARTH_RADIUS_M = 6_371_000;

/** Great-circle distance in metres (haversine), same formula as the database. */
export function haversineMeters(a: LatLng, b: LatLng): number {
  const toRad = (deg: number) => (deg * Math.PI) / 180;
  const dLat = toRad(b.lat - a.lat);
  const dLng = toRad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_RADIUS_M * Math.asin(Math.min(1, Math.sqrt(h)));
}

/** D2 fallback when the Routes call fails: straight-line distance x 1.3, whole metres up. */
export function fallbackDistanceMeters(a: LatLng, b: LatLng): number {
  return Math.ceil(haversineMeters(a, b) * 1.3);
}

export function isLatLng(value: unknown): value is LatLng {
  const v = value as LatLng;
  return (
    !!v &&
    typeof v.lat === 'number' &&
    typeof v.lng === 'number' &&
    Number.isFinite(v.lat) &&
    Number.isFinite(v.lng) &&
    Math.abs(v.lat) <= 90 &&
    Math.abs(v.lng) <= 180
  );
}
