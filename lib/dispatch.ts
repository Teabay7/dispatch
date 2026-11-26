// Dispatch helpers that don't touch React Native (unit tested with node:test).
// The server decides who gets an offer, when it expires and what each side may
// see; these helpers only format and pick what to show.
import { formatDistance, type OrderStatus } from './orders.ts';

/** Seconds left on an offer, counted down locally from the server's figure. */
export function offerSecondsLeft(secondsLeftAtFetch: number, fetchedAt: number, now: number): number {
  return Math.max(0, secondsLeftAtFetch - Math.floor((now - fetchedAt) / 1000));
}

/** "0:25" */
export function formatCountdown(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

/** "1.2 km south of you" (or just the distance when the direction is unknown). */
export function distanceFromYou(meters: number, direction: string | null): string {
  return direction ? `${formatDistance(meters)} ${direction} of you` : `${formatDistance(meters)} from you`;
}

export type JobStep = 'accepted' | 'arrived' | 'picked_up' | 'ended';

export function jobStep(status: OrderStatus, arrivedPickupAt: string | null): JobStep {
  if (status === 'accepted') return arrivedPickupAt ? 'arrived' : 'accepted';
  if (status === 'picked_up') return 'picked_up';
  return 'ended';
}

export type JobAction = { kind: 'arrive' | 'pickup'; label: string } | null;

/** The one button the rider presses next. */
export function nextJobAction(step: JobStep): JobAction {
  if (step === 'accepted') return { kind: 'arrive', label: "I've arrived at pickup" };
  if (step === 'arrived') return { kind: 'pickup', label: 'Package picked up' };
  return null;
}

/** Riders can cancel a job only after accepting and before pickup (counted). */
export function riderCanCancel(step: JobStep): boolean {
  return step === 'accepted' || step === 'arrived';
}

export const RIDER_CANCEL_REASONS = [
  { code: 'customer_unreachable', label: "Can't reach the customer" },
  { code: 'pickup_problem', label: 'Problem at pickup' },
  { code: 'vehicle_problem', label: 'Problem with my bike' },
  { code: 'safety', label: 'I feel unsafe' },
  { code: 'other', label: 'Other reason' },
] as const;

export type RiderCancelReason = (typeof RIDER_CANCEL_REASONS)[number]['code'];

/** What the customer's cancel button does in each state (SPEC 10.6). */
export type CustomerCancelMode = 'free' | 'late' | 'support_only' | 'none';

export function customerCancelMode(status: OrderStatus): CustomerCancelMode {
  if (status === 'created' || status === 'rider_requested' || status === 'no_rider_found') return 'free';
  if (status === 'accepted') return 'late';
  if (status === 'picked_up') return 'support_only';
  return 'none';
}

export function customerCancelWarning(mode: CustomerCancelMode, flagAfter = 3): string {
  switch (mode) {
    case 'free':
      return 'No rider has accepted yet, so cancelling is free.';
    case 'late':
      return `A rider has already accepted. This counts as a late cancellation. After ${flagAfter}, Dispatch reviews your account.`;
    case 'support_only':
      return 'The rider has your package. Only Dispatch support can cancel now.';
    case 'none':
      return '';
  }
}

export type RiderLocation = {
  distance_to_pickup_m: number;
  distance_to_dropoff_m: number;
  updated_at: string;
};

/** "About 1.2 km from pickup · updated 2 min ago" (from drop-off after pickup). */
export function riderLocationLine(location: RiderLocation, status: OrderStatus, now: number): string {
  const toDropoff = status === 'picked_up';
  const meters = toDropoff ? location.distance_to_dropoff_m : location.distance_to_pickup_m;
  const where = toDropoff ? 'drop-off' : 'pickup';
  const distance = meters < 100 ? `At the ${where}` : `About ${formatDistance(meters)} from ${where}`;
  return `${distance} · ${updatedAgo(location.updated_at, now)}`;
}

export function updatedAgo(iso: string, now: number): string {
  const minutes = Math.floor((now - Date.parse(iso)) / 60_000);
  if (minutes < 1) return 'updated just now';
  if (minutes === 1) return 'updated 1 min ago';
  if (minutes < 60) return `updated ${minutes} min ago`;
  return 'location is old';
}

/** Opens the phone's maps app at a point (no map SDK in the app). */
export function mapsUrl(lat: number, lng: number): string {
  return `https://www.google.com/maps/search/?api=1&query=${lat.toFixed(6)},${lng.toFixed(6)}`;
}

// Server messages that are safe to show as they are.
const SAFE_MESSAGES = [
  'This offer has expired',
  'This offer is no longer available',
  'You cannot take a job right now',
  'Offer not found',
  'Job not found',
  'You can mark arrival only once, after accepting',
  'Mark that you have arrived at pickup first',
  'After pickup, only Dispatch support can cancel',
  'Choose a reason',
  'This order is not waiting for a retry',
  'This order can no longer be cancelled in the app',
  'Rider details are not available for this order',
  "The rider's location is not available for this order",
  'Contact details are not available for this order',
];

export function friendlyDispatchError(message: string | null | undefined): string {
  if (message) {
    const known = SAFE_MESSAGES.find((m) => message.includes(m));
    if (known) return `${known}.`;
  }
  return 'Something went wrong. Check your connection and try again.';
}
