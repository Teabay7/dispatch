import { KYC_BUCKET } from '@/lib/kyc';
import { supabase } from '@/lib/supabase';

export class UploadError extends Error {
  constructor(
    message: string,
    /** True when trying again might work (network, timeout, server error). */
    readonly retryable: boolean,
  ) {
    super(message);
    this.name = 'UploadError';
  }
}

const UPLOAD_TIMEOUT_MS = 60_000;

/**
 * Uploads one KYC photo to the private rider-kyc bucket with progress.
 * supabase-js's upload has no progress events, so this posts to the Storage
 * API with XMLHttpRequest using the signed-in user's token. Storage policies
 * still decide whether the upload is allowed. Never logs the path or contents.
 */
export async function uploadKycPhoto(
  path: string,
  photo: Blob,
  onProgress: (fraction: number) => void,
): Promise<void> {
  const { data } = await supabase.auth.getSession();
  const accessToken = data.session?.access_token;
  if (!accessToken) throw new UploadError('You are signed out. Please sign in again.', false);

  const baseUrl = process.env.EXPO_PUBLIC_SUPABASE_URL;
  const apiKey = process.env.EXPO_PUBLIC_SUPABASE_ANON_KEY;
  const encodedPath = path.split('/').map(encodeURIComponent).join('/');
  const url = `${baseUrl}/storage/v1/object/${KYC_BUCKET}/${encodedPath}`;

  await new Promise<void>((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open('POST', url);
    xhr.timeout = UPLOAD_TIMEOUT_MS;
    xhr.setRequestHeader('Authorization', `Bearer ${accessToken}`);
    xhr.setRequestHeader('apikey', apiKey ?? '');
    xhr.setRequestHeader('Content-Type', 'image/jpeg');
    xhr.setRequestHeader('x-upsert', 'false');

    xhr.upload.onprogress = (event) => {
      if (event.lengthComputable && event.total > 0) onProgress(event.loaded / event.total);
    };
    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        onProgress(1);
        resolve();
      } else if (xhr.status === 413) {
        reject(new UploadError('This photo is too large. Please take it again.', false));
      } else if (xhr.status === 401 || xhr.status === 403) {
        reject(new UploadError('You are not allowed to upload this photo. Is your rider account active?', false));
      } else {
        reject(new UploadError('Upload failed. Please try again.', xhr.status >= 500 || xhr.status === 0));
      }
    };
    xhr.onerror = () => reject(new UploadError('No connection. Check your internet and try again.', true));
    xhr.ontimeout = () => reject(new UploadError('The upload took too long. Please try again.', true));

    xhr.send(photo);
  });
}
