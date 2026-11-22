import * as ImagePicker from 'expo-image-picker';
import { useCallback, useRef, useState } from 'react';

import { compressPhoto, type CompressedPhoto } from '@/lib/compressPhoto';
import { buildKycPhotoPath, type PhotoKind } from '@/lib/kyc';
import { UploadError, uploadKycPhoto } from '@/lib/uploadKycPhoto';

export type PhotoSource = 'camera' | 'library';

export type PhotoState =
  | { kind: 'empty' }
  /** A file from an earlier submission (shown through a short-lived signed URL). */
  | { kind: 'existing'; path: string }
  | { kind: 'working'; step: 'compressing' | 'uploading'; progress: number; previewUri: string | null }
  | { kind: 'uploaded'; path: string; previewUri: string }
  | { kind: 'failed'; message: string; previewUri: string | null; canRetryUpload: boolean };

function randomId(): string {
  return Math.random().toString(36).slice(2, 10);
}

/** Pick or capture one KYC photo, compress it on the device and upload it, with retry. */
export function useKycPhoto(userId: string | null, kind: PhotoKind, initialPath: string | null) {
  const [state, setState] = useState<PhotoState>(
    initialPath ? { kind: 'existing', path: initialPath } : { kind: 'empty' },
  );
  // Kept so "Retry" re-sends the same compressed photo without asking again.
  const lastPhoto = useRef<CompressedPhoto | null>(null);

  const upload = useCallback(
    async (photo: CompressedPhoto) => {
      if (!userId) return;
      const path = buildKycPhotoPath(userId, kind, new Date(), randomId());
      setState({ kind: 'working', step: 'uploading', progress: 0, previewUri: photo.uri });
      try {
        await uploadKycPhoto(path, photo.blob, (progress) =>
          setState({ kind: 'working', step: 'uploading', progress, previewUri: photo.uri }),
        );
        setState({ kind: 'uploaded', path, previewUri: photo.uri });
      } catch (error) {
        const message = error instanceof UploadError ? error.message : 'Upload failed. Please try again.';
        setState({ kind: 'failed', message, previewUri: photo.uri, canRetryUpload: true });
      }
    },
    [userId, kind],
  );

  const choose = useCallback(
    async (source: PhotoSource) => {
      // The selfie must be taken with the front camera (no gallery).
      if (kind === 'selfie' && source !== 'camera') return;

      let result: ImagePicker.ImagePickerResult;
      if (source === 'camera') {
        const permission = await ImagePicker.requestCameraPermissionsAsync();
        if (!permission.granted) {
          setState({
            kind: 'failed',
            message: 'Dispatch needs camera access to take this photo. Allow it in your phone settings.',
            previewUri: null,
            canRetryUpload: false,
          });
          return;
        }
        result = await ImagePicker.launchCameraAsync({
          mediaTypes: ['images'],
          cameraType: kind === 'selfie' ? ImagePicker.CameraType.front : ImagePicker.CameraType.back,
          exif: false,
        });
      } else {
        result = await ImagePicker.launchImageLibraryAsync({ mediaTypes: ['images'], exif: false });
      }
      if (result.canceled || !result.assets[0]) return;

      const asset = result.assets[0];
      setState({ kind: 'working', step: 'compressing', progress: 0, previewUri: asset.uri });
      try {
        lastPhoto.current = await compressPhoto(asset);
      } catch {
        lastPhoto.current = null;
        setState({
          kind: 'failed',
          message: 'We could not prepare this photo. Please take it again.',
          previewUri: asset.uri,
          canRetryUpload: false,
        });
        return;
      }
      await upload(lastPhoto.current);
    },
    [kind, upload],
  );

  const retry = useCallback(async () => {
    if (lastPhoto.current) await upload(lastPhoto.current);
  }, [upload]);

  const path = state.kind === 'uploaded' || state.kind === 'existing' ? state.path : null;
  const busy = state.kind === 'working';

  return { state, choose, retry, path, busy };
}
