/// <reference types="node" />
// Run: npm test
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { formatNigerianPhone, normalizeNigerianPhone } from './phone.ts';

test('accepts the common ways Nigerians type a mobile number', () => {
  for (const input of [
    '08031234567',
    '0803 123 4567',
    '0803-123-4567',
    '8031234567',
    '2348031234567',
    '+2348031234567',
    '+234 803 123 4567',
    '+234 0803 123 4567',
    '(0803) 123 4567',
  ]) {
    assert.equal(normalizeNigerianPhone(input), '+2348031234567', input);
  }
});

test('accepts every Nigerian mobile prefix family', () => {
  for (const prefix of ['70', '71', '80', '81', '90', '91']) {
    assert.equal(normalizeNigerianPhone(`0${prefix}12345678`), `+234${prefix}12345678`);
  }
});

test('rejects numbers that are not Nigerian mobiles', () => {
  for (const input of [
    '',
    '0803123456', // too short
    '080312345678', // too long
    '01234567890', // landline prefix
    '06031234567', // not a mobile prefix
    '+14155550100', // US
    '+447911123456', // UK
    '0803abc4567',
    '+234+8031234567',
  ]) {
    assert.equal(normalizeNigerianPhone(input), null, input);
  }
});

test('formats a stored number for display', () => {
  assert.equal(formatNigerianPhone('+2348031234567'), '+234 803 123 4567');
  assert.equal(formatNigerianPhone('2348031234567'), '+234 803 123 4567');
  assert.equal(formatNigerianPhone('12345'), '12345');
});
