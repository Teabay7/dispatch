/// <reference types="node" />
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  customerPaymentView,
  disputeDetailsError,
  disputeLine,
  disputeReasons,
  formatClock,
  formatWait,
  friendlyDeliveryError,
  normalizePin,
  orderBlockMessage,
  pinError,
  pinResultMessage,
  riderDeliveryStep,
  secondsUntil,
} from './delivery.ts';

test('rider step: to the drop-off, payment due, handover, ended', () => {
  assert.equal(riderDeliveryStep('picked_up', 'unpaid'), 'to_dropoff');
  assert.equal(riderDeliveryStep('picked_up', 'awaiting_payment'), 'awaiting_payment');
  assert.equal(riderDeliveryStep('picked_up', 'paid'), 'handover');
  assert.equal(riderDeliveryStep('picked_up', 'failed'), 'ended');
  assert.equal(riderDeliveryStep('delivered', 'paid'), 'ended');
  assert.equal(riderDeliveryStep('payment_failed', 'failed'), 'ended');
  assert.equal(riderDeliveryStep('accepted', 'unpaid'), 'ended');
});

test('customer payment card: pay, reported, PIN, receipt, refused', () => {
  assert.equal(customerPaymentView('accepted', 'unpaid', null), 'none');
  assert.equal(customerPaymentView('picked_up', 'unpaid', null), 'none');
  assert.equal(customerPaymentView('picked_up', 'awaiting_payment', null), 'pay_now');
  assert.equal(customerPaymentView('picked_up', 'awaiting_payment', '2026-11-28T10:00:00Z'), 'reported');
  assert.equal(customerPaymentView('picked_up', 'paid', '2026-11-28T10:00:00Z'), 'paid_handover');
  assert.equal(customerPaymentView('delivered', 'paid', null), 'delivered');
  assert.equal(customerPaymentView('delivered', 'failed', null), 'none');
  assert.equal(customerPaymentView('payment_failed', 'failed', null), 'refused');
  assert.equal(customerPaymentView('payment_failed', 'paid', null), 'refused');
});

test('refusal countdown', () => {
  const now = Date.parse('2026-11-28T10:00:00Z');
  assert.equal(secondsUntil(null, now), null);
  assert.equal(secondsUntil('2026-11-28T10:05:00Z', now), 300);
  assert.equal(secondsUntil('2026-11-28T09:59:00Z', now), 0);
  assert.equal(secondsUntil('2026-11-28T10:00:00.400Z', now), 1);
  assert.equal(formatWait(300), '5:00');
  assert.equal(formatWait(65), '1:05');
  assert.equal(formatWait(-3), '0:00');
});

test('clock time is two-digit hours and minutes', () => {
  const local = new Date(2026, 10, 28, 9, 5).toISOString();
  assert.equal(formatClock(local), '09:05');
});

test('PIN input keeps 4 digits and explains a short PIN', () => {
  assert.equal(normalizePin(' 4 8-2 1 9'), '4821');
  assert.equal(normalizePin('ab12'), '12');
  assert.equal(pinError('4821'), null);
  assert.equal(pinError('482'), 'Enter the 4-digit PIN from the receiver');
});

test('PIN results', () => {
  assert.equal(pinResultMessage('delivered', null), null);
  assert.equal(pinResultMessage('wrong_pin', 3), 'Wrong PIN. 3 tries left.');
  assert.equal(pinResultMessage('wrong_pin', 1), 'Wrong PIN. 1 try left.');
  assert.match(pinResultMessage('locked', 0) ?? '', /locked/);
});

test('dispute reasons depend on who reports, and match the server codes', () => {
  assert.deepEqual(disputeReasons('customer').map((r) => r.code), ['paid_not_confirmed', 'wrong_amount', 'other']);
  assert.deepEqual(disputeReasons('rider').map((r) => r.code), ['payment_not_received', 'wrong_amount', 'other']);
});

test('dispute details: no long numbers, not too long', () => {
  assert.equal(disputeDetailsError('Sent at noon from GTBank'), null);
  assert.equal(disputeDetailsError('Paid ₦2,050'), null);
  assert.equal(disputeDetailsError('Call me on 0803 123 4567'), "Don't include phone or account numbers");
  assert.equal(disputeDetailsError('Account 0123456789'), "Don't include phone or account numbers");
  assert.equal(disputeDetailsError('x'.repeat(501)), 'Keep the details shorter');
});

test('dispute line from each side', () => {
  const open = { can_raise: false, dispute_status: 'open' as const, raised_as: 'rider' as const, outcome: null };
  assert.match(disputeLine(open, 'rider') ?? '', /^You reported/);
  assert.match(disputeLine(open, 'customer') ?? '', /^The rider reported/);
  assert.match(disputeLine({ ...open, dispute_status: 'resolved', outcome: 'paid' }, 'customer') ?? '', /confirmed/);
  assert.match(disputeLine({ ...open, dispute_status: 'resolved', outcome: 'not_paid' }, 'customer') ?? '', /not paid/);
  assert.match(disputeLine({ ...open, dispute_status: 'withdrawn' }, 'customer') ?? '', /closed/);
  assert.equal(disputeLine({ can_raise: true, dispute_status: null, raised_as: null, outcome: null }, 'customer'), null);
  assert.equal(disputeLine(null, 'customer'), null);
});

test('order block messages', () => {
  assert.match(orderBlockMessage('rider_dispute'), /payment problem/);
  assert.match(orderBlockMessage('unpaid_delivery'), /not paid/);
});

test('server errors: known ones shown, anything else hidden', () => {
  assert.equal(
    friendlyDeliveryError('You are not at the drop-off yet. Move closer and try again'),
    'You are not at the drop-off yet. Move closer and try again.',
  );
  assert.equal(friendlyDeliveryError('duplicate key value violates unique constraint'),
    'Something went wrong. Check your connection and try again.');
  assert.equal(friendlyDeliveryError(undefined), 'Something went wrong. Check your connection and try again.');
});
