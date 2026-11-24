/// <reference types="node" />
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  distanceMeters,
  friendlyOnlineError,
  isAccessRefused,
  locationAccessMessage,
  mapLocationAccess,
  SEND_RULES,
  shouldRequestPermission,
  shouldSendHeartbeat,
  shouldSendLocation,
} from './riderOnline.ts';

// Ede town centre and points roughly 30 m and 100 m north of it.
const EDE = { lat: 7.7333, lng: 4.4333 };
const NORTH_30M = { lat: EDE.lat + 0.00027, lng: EDE.lng };
const NORTH_100M = { lat: EDE.lat + 0.0009, lng: EDE.lng };
const T0 = 1_800_000_000_000;

test('distanceMeters: zero, ~100 m, and symmetric', () => {
  assert.equal(distanceMeters(EDE, EDE), 0);
  const d = distanceMeters(EDE, NORTH_100M);
  assert.ok(d > 95 && d < 105, `expected ~100 m, got ${d}`);
  assert.equal(distanceMeters(EDE, NORTH_100M), distanceMeters(NORTH_100M, EDE));
});

test('shouldSendLocation: always sends the first position', () => {
  assert.equal(shouldSendLocation(null, { ...EDE, accuracyM: 10, at: T0 }), true);
});

test('shouldSendLocation: not more often than the minimum interval, even when moving', () => {
  const last = { ...EDE, at: T0 };
  assert.equal(shouldSendLocation(last, { ...NORTH_100M, accuracyM: 10, at: T0 + 10_000 }), false);
});

test('shouldSendLocation: sends after the interval only if moved far enough', () => {
  const last = { ...EDE, at: T0 };
  const later = T0 + SEND_RULES.minIntervalMs;
  assert.equal(shouldSendLocation(last, { ...NORTH_30M, accuracyM: 10, at: later }), false);
  assert.equal(shouldSendLocation(last, { ...NORTH_100M, accuracyM: 10, at: later }), true);
});

test('shouldSendLocation: heartbeat sends even when standing still', () => {
  const last = { ...EDE, at: T0 };
  assert.equal(shouldSendLocation(last, { ...EDE, accuracyM: 10, at: T0 + SEND_RULES.heartbeatMs - 1 }), false);
  assert.equal(shouldSendLocation(last, { ...EDE, accuracyM: 10, at: T0 + SEND_RULES.heartbeatMs }), true);
});

test('shouldSendHeartbeat: due after the heartbeat interval with a recent fix', () => {
  const fix = { ...EDE, accuracyM: 10, at: T0 };
  const last = { ...EDE, at: T0 };
  assert.equal(shouldSendHeartbeat(last, fix, T0 + 60_000), false);
  assert.equal(shouldSendHeartbeat(last, fix, T0 + SEND_RULES.heartbeatMs), true);
});

test('shouldSendHeartbeat: stops when there is no fresh fix, so the rider goes stale', () => {
  const fix = { ...EDE, accuracyM: 10, at: T0 };
  assert.equal(shouldSendHeartbeat(null, null, T0), false);
  assert.equal(shouldSendHeartbeat({ ...EDE, at: T0 }, fix, T0 + SEND_RULES.maxFixAgeMs + 1), false);
});

test('shouldSendHeartbeat: sends a recent fix when nothing was sent yet', () => {
  assert.equal(shouldSendHeartbeat(null, { ...EDE, accuracyM: 10, at: T0 }, T0 + 1_000), true);
});

test('mapLocationAccess: permission states', () => {
  assert.equal(mapLocationAccess({ status: 'undetermined', canAskAgain: true }, true), 'needs_permission');
  assert.equal(mapLocationAccess({ status: 'denied', canAskAgain: true }, true), 'denied');
  assert.equal(mapLocationAccess({ status: 'denied', canAskAgain: false }, true), 'blocked');
  assert.equal(
    mapLocationAccess({ status: 'granted', canAskAgain: true, androidAccuracy: 'coarse' }, true),
    'approximate_only',
  );
  assert.equal(mapLocationAccess({ status: 'granted', canAskAgain: true, androidAccuracy: 'fine' }, false), 'services_off');
  assert.equal(mapLocationAccess({ status: 'granted', canAskAgain: true, androidAccuracy: 'fine' }, true), 'ready');
  assert.equal(mapLocationAccess({ status: 'granted', canAskAgain: true }, true), 'ready');
});

test('mapLocationAccess: a permission problem is reported before services being off', () => {
  assert.equal(mapLocationAccess({ status: 'denied', canAskAgain: false }, false), 'blocked');
});

test('shouldRequestPermission: asks only when the system prompt can still appear', () => {
  assert.equal(shouldRequestPermission({ status: 'undetermined', canAskAgain: true }), true);
  assert.equal(shouldRequestPermission({ status: 'denied', canAskAgain: true }), true);
  assert.equal(shouldRequestPermission({ status: 'denied', canAskAgain: false }), false);
  assert.equal(shouldRequestPermission({ status: 'granted', canAskAgain: true, androidAccuracy: 'coarse' }), true);
  assert.equal(shouldRequestPermission({ status: 'granted', canAskAgain: true, androidAccuracy: 'fine' }), false);
});

test('locationAccessMessage: each state has an action', () => {
  assert.equal(locationAccessMessage('denied').action, 'retry');
  assert.equal(locationAccessMessage('blocked').action, 'open_settings');
  assert.equal(locationAccessMessage('approximate_only').action, 'open_settings');
  assert.equal(locationAccessMessage('services_off').action, 'enable_services');
  assert.match(locationAccessMessage('approximate_only').message, /precise/i);
});

test('isAccessRefused: RLS refusals', () => {
  assert.equal(isAccessRefused({ code: '42501', message: 'x' }), true);
  assert.equal(
    isAccessRefused({ code: null, message: 'new row violates row-level security policy for table "rider_locations"' }),
    true,
  );
  assert.equal(isAccessRefused({ code: '08006', message: 'connection failure' }), false);
});

test('friendlyOnlineError: toggle refused, sending refused, network', () => {
  assert.match(
    friendlyOnlineError({ code: 'P0001', message: 'Rider must be KYC approved with an active rider role to go online' }),
    /cannot go online/,
  );
  assert.match(
    friendlyOnlineError({ code: 'P0001', message: 'A verified bank account is required to go online' }),
    /bank account is approved/,
  );
  assert.match(
    friendlyOnlineError({ code: 'P0001', message: 'Commission is due: pay it to go online' }),
    /commission is paid/,
  );
  assert.match(friendlyOnlineError({ code: '42501', message: 'denied' }), /You are offline/);
  assert.match(friendlyOnlineError({ message: 'TypeError: Network request failed' }), /could not reach/);
});
