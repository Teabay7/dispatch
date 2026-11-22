/// <reference types="node" />
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  buildKycPhotoPath,
  canEditKyc,
  cleanPlate,
  cleanText,
  friendlyKycError,
  hasErrors,
  kycCardState,
  validateKycForm,
} from './kyc.ts';

const valid = {
  fullName: 'Adebayo Okafor',
  bikeMakeModel: 'Bajaj Boxer 150',
  bikeColour: 'Red',
  plateNumber: 'EDE 123 AA',
};

test('a complete form has no errors', () => {
  assert.equal(hasErrors(validateKycForm(valid)), false);
});

test('every required field is reported when blank', () => {
  const errors = validateKycForm({ fullName: ' ', bikeMakeModel: '', bikeColour: '  ', plateNumber: '' });
  assert.deepEqual(Object.keys(errors).sort(), ['bikeColour', 'bikeMakeModel', 'fullName', 'plateNumber']);
});

test('a one-letter name is rejected', () => {
  assert.ok(validateKycForm({ ...valid, fullName: 'A' }).fullName);
});

test('plate format is not over-validated', () => {
  for (const plate of ['ABC-123-DE', 'abc123de', 'EDE 1', 'OS 4521 KJA', '12']) {
    assert.equal(validateKycForm({ ...valid, plateNumber: plate }).plateNumber, undefined, plate);
  }
});

test('text and plates are tidied', () => {
  assert.equal(cleanText('  Bajaj   Boxer  '), 'Bajaj Boxer');
  assert.equal(cleanPlate('  ede  123   aa '), 'EDE 123 AA');
});

test('photo paths start with the user id and are unique per upload', () => {
  const userId = '00000000-0000-0000-0000-0000000000a1';
  const now = new Date('2026-11-22T10:00:00Z');
  const path = buildKycPhotoPath(userId, 'id-front', now, 'abc123');
  assert.equal(path, `${userId}/id-front-${now.getTime()}-abc123.jpg`);
  assert.notEqual(path, buildKycPhotoPath(userId, 'id-front', now, 'xyz789'));
  assert.ok(buildKycPhotoPath(userId, 'selfie', now, 'a').startsWith(`${userId}/selfie-`));
});

test('photo paths cannot escape the user folder through the random part', () => {
  const path = buildKycPhotoPath('u1', 'selfie', new Date(0), '../../other/x');
  assert.equal(path.split('/').length, 2);
  assert.ok(path.startsWith('u1/selfie-0-'));
});

test('home card state', () => {
  assert.equal(kycCardState('active', null), 'not_started');
  assert.equal(kycCardState('active', 'pending'), 'pending');
  assert.equal(kycCardState('active', 'approved'), 'approved');
  assert.equal(kycCardState('active', 'rejected'), 'rejected');
  assert.equal(kycCardState('suspended', 'approved'), 'suspended');
  assert.equal(kycCardState('suspended', null), 'suspended');
});

test('the form is only open before submitting or after a rejection', () => {
  assert.equal(canEditKyc('not_started'), true);
  assert.equal(canEditKyc('rejected'), true);
  assert.equal(canEditKyc('pending'), false);
  assert.equal(canEditKyc('approved'), false);
  assert.equal(canEditKyc('suspended'), false);
});

test('database errors become actionable messages', () => {
  assert.match(friendlyKycError('An active rider role is required to resubmit KYC'), /suspended/);
  assert.match(friendlyKycError('KYC photos must be your own uploaded files'), /photos/);
  assert.match(friendlyKycError(undefined), /connection/);
});
