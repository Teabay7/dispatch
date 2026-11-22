// On-device compression settings for KYC photos. Riders use low-end Android
// phones on weak networks, so every photo is resized and re-encoded as JPEG
// before upload, aiming well under 1 MB.

/** Stop compressing once a photo is at or below this size. */
export const TARGET_MAX_BYTES = 900_000;

/** Server-side limit on the rider-kyc bucket (see the KYC migration). */
export const BUCKET_MAX_BYTES = 2 * 1024 * 1024;

export type CompressionStep = { maxEdge: number; quality: number };

/** Tried in order until the photo is small enough. 1280 px keeps an ID card readable. */
export const COMPRESSION_STEPS: readonly CompressionStep[] = [
  { maxEdge: 1280, quality: 0.6 },
  { maxEdge: 1024, quality: 0.45 },
  { maxEdge: 800, quality: 0.35 },
];

/**
 * The resize to apply so the longer edge is at most `maxEdge`, keeping the
 * aspect ratio. Returns null when the image is already small enough (or its
 * size is unknown, which some Android galleries report as 0).
 */
export function resizeFor(
  width: number,
  height: number,
  maxEdge: number,
): { width: number } | { height: number } | null {
  if (width <= 0 || height <= 0) return null;
  if (Math.max(width, height) <= maxEdge) return null;
  return width >= height ? { width: maxEdge } : { height: maxEdge };
}

export function isSmallEnough(bytes: number): boolean {
  return bytes <= TARGET_MAX_BYTES;
}

/** After the last step, a photo still larger than the bucket allows cannot be uploaded. */
export function fitsBucket(bytes: number): boolean {
  return bytes <= BUCKET_MAX_BYTES;
}
