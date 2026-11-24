/// <reference types="node" />
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  bankCardState,
  chosenBankName,
  cleanAccountNumber,
  friendlyBankError,
  maskAccountNumber,
  OTHER_BANK,
  validateBankForm,
  type BankAccountRow,
} from './bankAccount.ts';

const valid = { bank: 'OPay', otherBank: '', accountNumber: '0123 456 789', accountName: 'Adebayo Okafor' };

test('a complete form has no errors (spaces in the number are fine)', () => {
  assert.deepEqual(validateBankForm(valid), {});
  assert.equal(cleanAccountNumber(valid.accountNumber), '0123456789');
});

test('the account number must be exactly 10 digits', () => {
  assert.ok(validateBankForm({ ...valid, accountNumber: '123456789' }).accountNumber);
  assert.ok(validateBankForm({ ...valid, accountNumber: '12345678901' }).accountNumber);
  assert.ok(validateBankForm({ ...valid, accountNumber: '12345678AB' }).accountNumber);
});

test('bank and account name are required; "Other" needs a typed bank name', () => {
  const errors = validateBankForm({ bank: '', otherBank: '', accountNumber: '0123456789', accountName: ' ' });
  assert.deepEqual(Object.keys(errors).sort(), ['accountName', 'bank']);
  assert.ok(validateBankForm({ ...valid, bank: OTHER_BANK, otherBank: '  ' }).bank);
  assert.equal(chosenBankName({ bank: OTHER_BANK, otherBank: '  Lapo   MFB ' }), 'Lapo MFB');
  assert.equal(chosenBankName({ bank: 'Kuda', otherBank: 'ignored' }), 'Kuda');
});

test('maskAccountNumber shows only the last 4 digits', () => {
  assert.equal(maskAccountNumber('0123456789'), '******6789');
  assert.equal(maskAccountNumber('0123 456 789'), '******6789');
});

function row(status: BankAccountRow['status'], created_at: string, reason: string | null = null): BankAccountRow {
  return { id: created_at, bank_name: 'OPay', account_number: '0123456789', account_name: 'A B', status, reason, created_at };
}

test('bankCardState: nothing, pending, rejected, revoked', () => {
  assert.equal(bankCardState([]).kind, 'none');
  assert.equal(bankCardState([row('pending', '2026-11-24T10:00'), row('withdrawn', '2026-11-24T09:00')]).kind, 'pending');
  assert.equal(bankCardState([row('rejected', '2026-11-24T10:00', 'Name does not match')]).kind, 'rejected');
  assert.equal(bankCardState([row('revoked', '2026-11-24T10:00', 'Closed')]).kind, 'revoked');
  assert.equal(bankCardState([row('withdrawn', '2026-11-24T10:00')]).kind, 'none');
});

test('bankCardState: a verified account wins, with any pending or rejected change', () => {
  const verified = row('verified', '2026-11-20T10:00');
  const withPending = bankCardState([row('pending', '2026-11-24T10:00'), verified]);
  assert.equal(withPending.kind, 'verified');
  assert.ok(withPending.kind === 'verified' && withPending.pending);

  const withRejected = bankCardState([row('rejected', '2026-11-24T10:00', 'Not yours'), verified]);
  assert.ok(withRejected.kind === 'verified' && withRejected.rejectedChange?.reason === 'Not yours');

  const oldRejection = bankCardState([verified, row('rejected', '2026-11-19T10:00', 'Old')]);
  assert.ok(oldRejection.kind === 'verified' && oldRejection.rejectedChange === null);
});

test('friendlyBankError: known messages pass, unknown text is never echoed', () => {
  assert.match(friendlyBankError('The account number must be exactly 10 digits'), /10 digits/);
  assert.match(friendlyBankError('This bank account is already registered to another rider'), /own name/);
  const leaked = friendlyBankError('duplicate key ... (0123456789) already exists');
  assert.doesNotMatch(leaked, /0123456789/);
  assert.match(leaked, /could not save/);
  assert.match(friendlyBankError(undefined), /could not save/);
});
