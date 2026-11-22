import { ImageManipulator, SaveFormat } from 'expo-image-manipulator';

import { COMPRESSION_STEPS, fitsBucket, isSmallEnough, resizeFor } from '@/lib/imageCompression';

export type CompressedPhoto = {
  /** Local file URI of the compressed JPEG (for preview). */
  uri: string;
  /** The JPEG bytes, ready to upload. */
  blob: Blob;
  bytes: number;
};

/**
 * Resize and re-encode a photo as JPEG on the device, stepping down until it
 * is under the target size. Throws if it still won't fit the bucket limit.
 */
export async function compressPhoto(source: { uri: string; width: number; height: number }): Promise<CompressedPhoto> {
  let last: CompressedPhoto | null = null;

  for (const step of COMPRESSION_STEPS) {
    const context = ImageManipulator.manipulate(source.uri);
    const resize = resizeFor(source.width, source.height, step.maxEdge);
    if (resize) context.resize(resize);
    const image = await context.renderAsync();
    const saved = await image.saveAsync({ compress: step.quality, format: SaveFormat.JPEG });

    const blob = await (await fetch(saved.uri)).blob();
    last = { uri: saved.uri, blob, bytes: blob.size };
    if (isSmallEnough(blob.size)) return last;
  }

  if (last && fitsBucket(last.bytes)) return last;
  throw new Error('Photo is too large even after compression');
}
