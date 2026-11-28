/// <reference types="node" />
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  customerCancelMode,
  customerCancelWarning,
  distanceFromYou,
  formatCountdown,
  friendlyDispatchError,
  jobStep,
  mapsUrl,
  nextJobAction,
  offerSecondsLeft,
  RIDER_CANCEL_REASONS,
  riderCanCancel,
  riderLocationLine,
  updatedAgo,
} from './dispatch.ts';

const T0 = Date.parse('2026-11-26T10:00:00Z');

test('offer countdown runs down locally from the server figure and stops at 0', () => {
  assert.equal(offerSecondsLeft(30, T0, T0), 30);
  assert.equal(offerSecondsLeft(30, T0, T0 + 12_400), 18);
  assert.equal(offerSecondsLeft(30, T0, T0 + 45_000), 0);
  assert.equal(formatCountdown(25), '0:25');
  assert.equal(formatCountdown(65), '1:05');
  assert.equal(formatCountdown(-3), '0:00');
});

test('offer distance line', () => {
  assert.equal(distanceFromYou(1200, 'south'), '1.2 km south of you');
  assert.equal(distanceFromYou(300, null), '300 m from you');
});

test('job steps: accepted, arrived, picked up, ended; one next action each', () => {
  assert.equal(jobStep('accepted', null), 'accepted');
  assert.equal(jobStep('accepted', '2026-11-26T10:05:00Z'), 'arrived');
  assert.equal(jobStep('picked_up', '2026-11-26T10:05:00Z'), 'picked_up');
  assert.equal(jobStep('delivered', null), 'ended');
  assert.equal(jobStep('rider_requested', null), 'ended');
  assert.equal(nextJobAction('accepted')?.kind, 'arrive');
  assert.equal(nextJobAction('arrived')?.kind, 'pickup');
  assert.equal(nextJobAction('picked_up'), null);
});

test('riders can cancel only before pickup', () => {
  assert.equal(riderCanCancel('accepted'), true);
  assert.equal(riderCanCancel('arrived'), true);
  assert.equal(riderCanCancel('picked_up'), false);
  assert.deepEqual(
    RIDER_CANCEL_REASONS.map((r) => r.code),
    ['customer_unreachable', 'pickup_problem', 'vehicle_problem', 'safety', 'other'],
  );
});

test('customer cancel rules: free, late (counted), support only, none', () => {
  assert.equal(customerCancelMode('created'), 'free');
  assert.equal(customerCancelMode('rider_requested'), 'free');
  assert.equal(customerCancelMode('no_rider_found'), 'free');
  assert.equal(customerCancelMode('accepted'), 'late');
  assert.equal(customerCancelMode('picked_up'), 'support_only');
  assert.equal(customerCancelMode('delivered'), 'none');
  assert.match(customerCancelWarning('late'), /late cancellation.*After 3/);
  assert.match(customerCancelWarning('support_only'), /Only Dispatch support/);
});

test('rider location line: to pickup before, to drop-off after pickup, with freshness', () => {
  const loc = { distance_to_pickup_m: 1200, distance_to_dropoff_m: 60, updated_at: '2026-11-26T09:58:00Z' };
  assert.equal(riderLocationLine(loc, 'accepted', T0), 'About 1.2 km from pickup · updated 2 min ago');
  assert.equal(riderLocationLine(loc, 'picked_up', T0), 'At the drop-off · updated 2 min ago');
  assert.equal(updatedAgo('2026-11-26T09:59:40Z', T0), 'updated just now');
  assert.equal(updatedAgo('2026-11-26T08:00:00Z', T0), 'location is old');
});

test('maps link and friendly errors', () => {
  assert.equal(mapsUrl(7.7377, 4.436), 'https://www.google.com/maps/search/?api=1&query=7.737700,4.436000');
  assert.equal(friendlyDispatchError('This offer has expired'), 'This offer has expired.');
  assert.match(friendlyDispatchError('duplicate key ... 2348031234567'), /Something went wrong/);
});
