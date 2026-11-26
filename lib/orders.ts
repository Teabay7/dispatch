// Customer order helpers that don't touch React Native (unit tested with node:test).
// Prices come from the server's quote; the app never calculates or sends a price.
import { normalizeNigerianPhone } from './phone.ts';

export type OrderStatus =
  | 'created'
  | 'rider_requested'
  | 'accepted'
  | 'picked_up'
  | 'delivered'
  | 'completed'
  | 'cancelled_by_customer'
  | 'cancelled_by_rider'
  | 'no_rider_found'
  | 'payment_failed';

export const ACTIVE_STATUSES: OrderStatus[] = ['created', 'rider_requested', 'accepted', 'picked_up'];

export function isActiveStatus(status: OrderStatus): boolean {
  return ACTIVE_STATUSES.includes(status);
}

/** The customer can cancel in the app only until a rider accepts (SPEC 10.6). */
export function canCustomerCancel(status: OrderStatus): boolean {
  return status === 'created' || status === 'rider_requested';
}

export type StatusView = { title: string; body: string; tone: 'waiting' | 'active' | 'done' | 'stopped' };

export function orderStatusView(status: OrderStatus): StatusView {
  switch (status) {
    case 'created':
    case 'rider_requested':
      return { title: 'Searching for a rider', body: 'We will show you the rider as soon as one accepts.', tone: 'waiting' };
    case 'accepted':
      return { title: 'A rider is on the way', body: 'The rider is heading to the pickup point.', tone: 'active' };
    case 'picked_up':
      return { title: 'Package picked up', body: 'The rider is taking your package to the drop-off point.', tone: 'active' };
    case 'delivered':
    case 'completed':
      return { title: 'Delivered', body: 'Your package has been delivered.', tone: 'done' };
    case 'cancelled_by_customer':
      return { title: 'Cancelled', body: 'You cancelled this order.', tone: 'stopped' };
    case 'cancelled_by_rider':
      return { title: 'Cancelled', body: 'This order was cancelled.', tone: 'stopped' };
    case 'no_rider_found':
      return { title: 'No rider found', body: 'No rider was available. Please try again later.', tone: 'stopped' };
    case 'payment_failed':
      return { title: 'Not delivered', body: 'The delivery was not completed because payment was not made.', tone: 'stopped' };
  }
}

/** "850 m" or "2.4 km". */
export function formatDistance(meters: number): string {
  if (meters < 1000) return `${Math.round(meters)} m`;
  return `${(meters / 1000).toFixed(1)} km`;
}

/** A chosen place: a Google place (by id) or the device's current location. */
export type PlaceChoice =
  | { kind: 'place'; placeId: string; label: string }
  | { kind: 'current'; lat: number; lng: number; label: string };

/** Request body for the quote-order function: place ids or device location only. */
export function quoteRequestBody(pickup: PlaceChoice, dropoff: PlaceChoice & { kind: 'place' }, sessionToken: string) {
  return {
    pickup:
      pickup.kind === 'place'
        ? { placeId: pickup.placeId, sessionToken }
        : { location: { lat: pickup.lat, lng: pickup.lng } },
    dropoff: { placeId: dropoff.placeId, sessionToken },
  };
}

export type OrderFormValues = {
  pickup: PlaceChoice | null;
  dropoff: PlaceChoice | null;
  packageDescription: string;
  receiverName: string;
  receiverPhone: string;
};

export type OrderFormErrors = Partial<Record<keyof OrderFormValues, string>>;

/** Places only: what is needed to ask for a price. */
export function validatePlaces(values: Pick<OrderFormValues, 'pickup' | 'dropoff'>): OrderFormErrors {
  const errors: OrderFormErrors = {};
  if (!values.pickup) errors.pickup = 'Choose where the rider picks up the package.';
  if (!values.dropoff) errors.dropoff = 'Choose where the package goes.';
  else if (values.dropoff.kind !== 'place') errors.dropoff = 'Search for the drop-off place.';
  return errors;
}

/** Everything needed to confirm the order. */
export function validateOrderForm(values: OrderFormValues): OrderFormErrors {
  const errors = validatePlaces(values);
  const pkg = values.packageDescription.trim();
  if (pkg.length < 2) errors.packageDescription = 'Say what the package is, e.g. "Small box of documents".';
  else if (pkg.length > 200) errors.packageDescription = 'Keep the description under 200 characters.';
  const name = values.receiverName.trim();
  if (name.length < 2) errors.receiverName = 'Enter the name of the person receiving the package.';
  else if (name.length > 100) errors.receiverName = 'The name is too long.';
  if (!normalizeNigerianPhone(values.receiverPhone)) {
    errors.receiverPhone = 'Enter the receiver\'s Nigerian mobile number, e.g. 0803 123 4567.';
  }
  return errors;
}

export function hasErrors(errors: OrderFormErrors): boolean {
  return Object.keys(errors).length > 0;
}

export function isQuoteExpired(expiresAt: string, now: number): boolean {
  return Date.parse(expiresAt) <= now;
}

/** Whole minutes left on a quote (0 when expired). */
export function quoteMinutesLeft(expiresAt: string, now: number): number {
  return Math.max(0, Math.ceil((Date.parse(expiresAt) - now) / 60_000));
}

/** Random token for a Google place-search session (not a secret). */
export function newSessionToken(random: () => number = Math.random): string {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  let token = '';
  for (let i = 0; i < 32; i++) token += chars[Math.floor(random() * chars.length)];
  return token;
}

// Server messages that are safe to show as they are.
const SAFE_MESSAGES = [
  'Too many requests. Try again later.',
  'Dispatch is busy right now. Try again later.',
  'An active customer account is required to order',
  'The pickup point is outside the Dispatch service area',
  'The drop-off point is outside the Dispatch service area',
  'This delivery is longer than the maximum distance',
  'Pickup and drop-off must be different places',
  'This price has already been used for an order',
  'This price has expired. Get a new price.',
  'You have reached the limit of active orders. Wait for one to finish or cancel it.',
  'This order can no longer be cancelled in the app',
  'We could not find one of those places. Choose it again.',
  'Place search is not available right now. Try again.',
  'Type at least 3 characters',
];

/** Server errors as text a customer can act on. Unknown text is never shown. */
export function friendlyOrderError(message: string | null | undefined): string {
  if (message) {
    const known = SAFE_MESSAGES.find((m) => message.includes(m));
    if (known) return /[.!?]$/.test(known) ? known : `${known}.`;
  }
  return 'Something went wrong. Check your connection and try again.';
}
