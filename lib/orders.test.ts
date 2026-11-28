/// <reference types="node" />
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  canCustomerCancel,
  formatDistance,
  friendlyOrderError,
  hasErrors,
  HOME_ORDER_STATUSES,
  isActiveStatus,
  isQuoteExpired,
  newSessionToken,
  orderStatusView,
  quoteMinutesLeft,
  quoteRequestBody,
  validateOrderForm,
  validatePlaces,
  type OrderStatus,
  type PlaceChoice,
} from './orders.ts';

const PICKUP: PlaceChoice = { kind: 'place', placeId: 'ChIJpickup', label: 'Ede Central Mosque' };
const DROPOFF = { kind: 'place' as const, placeId: 'ChIJdropoff', label: 'Federal Polytechnic Ede' };
const CURRENT: PlaceChoice = { kind: 'current', lat: 7.7361, lng: 4.4372, label: 'Your current location' };

const valid = {
  pickup: PICKUP,
  dropoff: DROPOFF,
  packageDescription: 'Small box of documents',
  receiverName: 'Ada Okafor',
  receiverPhone: '0803 123 4567',
};

test('formatDistance: metres under 1 km, km with one decimal above', () => {
  assert.equal(formatDistance(850), '850 m');
  assert.equal(formatDistance(2350), '2.4 km');
  assert.equal(formatDistance(1000), '1.0 km');
});

test('status screens: waiting, on the way, done, stopped', () => {
  assert.equal(orderStatusView('created').title, 'Searching for a rider');
  assert.equal(orderStatusView('rider_requested').title, 'Searching for a rider');
  assert.equal(orderStatusView('accepted').tone, 'active');
  assert.equal(orderStatusView('delivered').tone, 'done');
  assert.equal(orderStatusView('cancelled_by_customer').tone, 'stopped');
  const all: OrderStatus[] = ['created', 'rider_requested', 'accepted', 'picked_up', 'delivered', 'completed',
    'cancelled_by_customer', 'cancelled_by_rider', 'no_rider_found', 'payment_failed'];
  for (const s of all) assert.ok(orderStatusView(s).title, s);
});

test('the customer can cancel in the app until pickup', () => {
  assert.equal(canCustomerCancel('created'), true);
  assert.equal(canCustomerCancel('rider_requested'), true);
  assert.equal(canCustomerCancel('no_rider_found'), true);
  assert.equal(canCustomerCancel('accepted'), true);
  assert.equal(canCustomerCancel('picked_up'), false);
  assert.equal(canCustomerCancel('cancelled_by_customer'), false);
  assert.equal(isActiveStatus('picked_up'), true);
  assert.equal(isActiveStatus('delivered'), false);
});

test('home lists active orders and no-rider-found orders, so Search again stays reachable', () => {
  for (const s of ['created', 'rider_requested', 'accepted', 'picked_up', 'no_rider_found'] as OrderStatus[]) {
    assert.ok(HOME_ORDER_STATUSES.includes(s), s);
  }
  for (const s of ['delivered', 'completed', 'cancelled_by_customer', 'cancelled_by_rider', 'payment_failed'] as OrderStatus[]) {
    assert.ok(!HOME_ORDER_STATUSES.includes(s), s);
  }
  // Still not "active": the order screen stops polling once the search has ended.
  assert.equal(isActiveStatus('no_rider_found'), false);
});

test('the quote request sends place ids or the device location, never an address or price', () => {
  assert.deepEqual(quoteRequestBody(PICKUP, DROPOFF, 'tok'), {
    pickup: { placeId: 'ChIJpickup', sessionToken: 'tok' },
    dropoff: { placeId: 'ChIJdropoff', sessionToken: 'tok' },
  });
  assert.deepEqual(quoteRequestBody(CURRENT, DROPOFF, 'tok').pickup, { location: { lat: 7.7361, lng: 4.4372 } });
});

test('validation: places, package, receiver name and Nigerian phone', () => {
  assert.equal(hasErrors(validateOrderForm(valid)), false);
  const errors = validateOrderForm({ pickup: null, dropoff: null, packageDescription: ' ', receiverName: 'A', receiverPhone: '123' });
  assert.deepEqual(Object.keys(errors).sort(), ['dropoff', 'packageDescription', 'pickup', 'receiverName', 'receiverPhone']);
  assert.ok(validatePlaces({ pickup: PICKUP, dropoff: CURRENT }).dropoff, 'the drop-off must be a searched place');
  assert.equal(hasErrors(validatePlaces({ pickup: CURRENT, dropoff: DROPOFF })), false);
});

test('quote expiry', () => {
  const now = Date.parse('2026-11-25T10:00:00Z');
  assert.equal(isQuoteExpired('2026-11-25T10:15:00Z', now), false);
  assert.equal(isQuoteExpired('2026-11-25T10:00:00Z', now), true);
  assert.equal(quoteMinutesLeft('2026-11-25T10:14:30Z', now), 15);
  assert.equal(quoteMinutesLeft('2026-11-25T09:00:00Z', now), 0);
});

test('session tokens are 32 safe characters', () => {
  const token = newSessionToken();
  assert.match(token, /^[A-Za-z0-9]{32}$/);
  assert.notEqual(newSessionToken(), token);
});

test('friendlyOrderError: known messages pass through, unknown text is never shown', () => {
  assert.equal(
    friendlyOrderError('The pickup point is outside the Dispatch service area'),
    'The pickup point is outside the Dispatch service area.',
  );
  assert.equal(friendlyOrderError('This price has expired. Get a new price.'), 'This price has expired. Get a new price.');
  assert.equal(
    friendlyOrderError('Settle your unpaid order before placing a new one'),
    'Settle your unpaid order before placing a new one.',
  );
  assert.match(friendlyOrderError('relation "x" does not exist at Okafor Street'), /Something went wrong/);
  assert.match(friendlyOrderError(undefined), /Something went wrong/);
});
