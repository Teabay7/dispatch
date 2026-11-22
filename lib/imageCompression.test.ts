/// <reference types="node" />
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  BUCKET_MAX_BYTES,
  COMPRESSION_STEPS,
  TARGET_MAX_BYTES,
  fitsBucket,
  isSmallEnough,
  resizeFor,
} from './imageCompression.ts';

test('target is well under 1 MB and below the bucket limit', () => {
  assert.ok(TARGET_MAX_BYTES < 1_000_000);
  assert.ok(TARGET_MAX_BYTES < BUCKET_MAX_BYTES);
});

test('each step is smaller and lower quality than the one before', () => {
  for (let i = 1; i < COMPRESSION_STEPS.length; i++) {
    assert.ok(COMPRESSION_STEPS[i].maxEdge < COMPRESSION_STEPS[i - 1].maxEdge);
    assert.ok(COMPRESSION_STEPS[i].quality < COMPRESSION_STEPS[i - 1].quality);
  }
  for (const step of COMPRESSION_STEPS) {
    assert.ok(step.quality > 0 && step.quality < 1);
  }
});

test('landscape photos are limited by width', () => {
  assert.deepEqual(resizeFor(4000, 3000, 1280), { width: 1280 });
});

test('portrait photos are limited by height', () => {
  assert.deepEqual(resizeFor(3000, 4000, 1280), { height: 1280 });
});

test('square photos are limited by width', () => {
  assert.deepEqual(resizeFor(2000, 2000, 1280), { width: 1280 });
});

test('photos already within the limit are not resized', () => {
  assert.equal(resizeFor(1280, 960, 1280), null);
  assert.equal(resizeFor(640, 480, 1280), null);
});

test('unknown dimensions are not resized', () => {
  assert.equal(resizeFor(0, 0, 1280), null);
  assert.equal(resizeFor(4000, 0, 1280), null);
});

test('size checks', () => {
  assert.equal(isSmallEnough(TARGET_MAX_BYTES), true);
  assert.equal(isSmallEnough(TARGET_MAX_BYTES + 1), false);
  assert.equal(fitsBucket(BUCKET_MAX_BYTES), true);
  assert.equal(fitsBucket(BUCKET_MAX_BYTES + 1), false);
});
