/// <reference types="node" />
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  activePayments,
  commissionCardState,
  formatNaira,
  hasCompanyAccount,
  owedLine,
  tripsLine,
  type CycleRow,
  type EntryRow,
} from './commission.ts';

test('formatNaira: whole naira, kobo, thousands and negatives', () => {
  assert.equal(formatNaira(108000), '₦1,080');
  assert.equal(formatNaira(27750), '₦277.50');
  assert.equal(formatNaira(5), '₦0.05');
  assert.equal(formatNaira(123456789), '₦1,234,567.89');
  assert.equal(formatNaira(0), '₦0');
  assert.equal(formatNaira(-10000), '-₦100');
});

test('owedLine and tripsLine', () => {
  assert.equal(owedLine(54000), '₦540 owed');
  assert.equal(owedLine(-30000), '₦300 credit');
  assert.equal(owedLine(0), 'Nothing owed');
  assert.equal(tripsLine(2, 4), '2 of 4 trips');
  assert.equal(tripsLine(0, 1), '0 of 1 trip');
});

function cycle(over: Partial<CycleRow>): CycleRow {
  return {
    id: 'c1',
    cycle_no: 1,
    trips_required: 4,
    trip_count: 0,
    status: 'open',
    reference_code: 'DSP-7F3A2C91-C001',
    due_at: null,
    ...over,
  };
}

function entry(over: Partial<EntryRow>): EntryRow {
  return {
    id: 'e',
    type: 'commission',
    amount_kobo: 27000,
    balance_after_kobo: 27000,
    paid_at: null,
    created_at: '2026-11-24T10:00:00Z',
    reverses_entry_id: null,
    ...over,
  };
}

test('before the first trip: 0 of N trips, nothing owed', () => {
  assert.deepEqual(commissionCardState([], [], 4), { kind: 'open', tripCount: 0, tripsRequired: 4, balanceKobo: 0 });
});

test('open cycle: trips so far and the balance from the newest entry', () => {
  const state = commissionCardState(
    [cycle({ trip_count: 2 })],
    [entry({ id: 'e2', balance_after_kobo: 54000 }), entry({ id: 'e1' })],
    4,
  );
  assert.deepEqual(state, { kind: 'open', tripCount: 2, tripsRequired: 4, balanceKobo: 54000 });
});

test('open cycle with credit from an overpayment', () => {
  const state = commissionCardState([cycle({ trip_count: 1 })], [entry({ balance_after_kobo: -3000 })], 4);
  assert.equal(state.kind === 'open' && state.balanceKobo, -3000);
});

test('a due cycle wins over an open one, with the reference code and the whole balance', () => {
  const state = commissionCardState(
    [
      cycle({ id: 'c2', cycle_no: 2, trip_count: 1, status: 'open', reference_code: 'DSP-X-C002' }),
      cycle({ trip_count: 4, status: 'due', due_at: '2026-11-24T12:00:00Z' }),
    ],
    [entry({ balance_after_kobo: 135000 })],
    4,
  );
  assert.deepEqual(state, {
    kind: 'due',
    tripsRequired: 4,
    referenceCode: 'DSP-7F3A2C91-C001',
    owedKobo: 135000,
    receivedSinceDueKobo: 0,
  });
});

test('a partial payment since the cycle became due is shown; older and reversed payments are not', () => {
  const entries = [
    entry({ id: 'r1', type: 'reversal', amount_kobo: 20000, reverses_entry_id: 'p3', balance_after_kobo: 85000, created_at: '2026-11-24T15:00:00Z' }),
    entry({ id: 'p3', type: 'payment', amount_kobo: -20000, created_at: '2026-11-24T14:30:00Z' }),
    entry({ id: 'p2', type: 'payment', amount_kobo: -50000, created_at: '2026-11-24T14:00:00Z' }),
    entry({ id: 'p1', type: 'payment', amount_kobo: -10000, created_at: '2026-11-20T09:00:00Z' }),
  ];
  const state = commissionCardState([cycle({ trip_count: 4, status: 'due', due_at: '2026-11-24T12:00:00Z' })], entries, 4);
  assert.ok(state.kind === 'due');
  assert.equal(state.owedKobo, 85000);
  assert.equal(state.receivedSinceDueKobo, 50000);
  assert.deepEqual(
    activePayments(entries).map((p) => p.id),
    ['p2', 'p1'],
  );
});

test('the company account must be complete before it is shown', () => {
  assert.equal(hasCompanyAccount(null), false);
  assert.equal(hasCompanyAccount({ bank_name: 'GTBank', account_number: null, account_name: 'TESNEEM LOGISTICS LTD' }), false);
  assert.equal(
    hasCompanyAccount({ bank_name: 'GTBank', account_number: '0123456789', account_name: 'TESNEEM LOGISTICS LTD' }),
    true,
  );
});
