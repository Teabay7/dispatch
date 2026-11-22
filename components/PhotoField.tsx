import { useEffect, useState } from 'react';
import { ActivityIndicator, Image, StyleSheet, Text, View } from 'react-native';

import { Button } from '@/components/Button';
import { ProgressBar } from '@/components/ProgressBar';
import { colors, spacing } from '@/constants/theme';
import { KYC_BUCKET } from '@/lib/kyc';
import { supabase } from '@/lib/supabase';
import type { PhotoSource, PhotoState } from '@/lib/useKycPhoto';

// Signed URLs for previews of already-submitted photos expire quickly.
const PREVIEW_URL_SECONDS = 60;

type PhotoFieldProps = {
  label: string;
  hint: string;
  state: PhotoState;
  /** Selfie: camera only. ID: camera or gallery. */
  sources: PhotoSource[];
  onChoose: (source: PhotoSource) => void;
  onRetry: () => void;
  disabled?: boolean;
};

export function PhotoField({ label, hint, state, sources, onChoose, onRetry, disabled = false }: PhotoFieldProps) {
  const previewUri = usePreviewUri(state);
  const busy = state.kind === 'working';
  const hasPhoto = state.kind === 'uploaded' || state.kind === 'existing';

  return (
    <View style={styles.container}>
      <Text style={styles.label}>{label}</Text>
      <Text style={styles.hint}>{hint}</Text>

      {previewUri ? (
        <Image source={{ uri: previewUri }} style={styles.preview} resizeMode="cover" accessibilityLabel={`${label} preview`} />
      ) : null}

      {state.kind === 'working' ? (
        <View style={styles.status}>
          {state.step === 'compressing' ? (
            <View style={styles.row}>
              <ActivityIndicator color={colors.primary} />
              <Text style={styles.muted}>Preparing photo…</Text>
            </View>
          ) : (
            <>
              <Text style={styles.muted}>Uploading… {Math.round(state.progress * 100)}%</Text>
              <ProgressBar progress={state.progress} />
            </>
          )}
        </View>
      ) : null}

      {hasPhoto ? <Text style={styles.success}>✓ Photo added</Text> : null}

      {state.kind === 'failed' ? (
        <View style={styles.status}>
          <Text style={styles.error}>{state.message}</Text>
          {state.canRetryUpload ? <Button title="Retry upload" onPress={onRetry} disabled={disabled} /> : null}
        </View>
      ) : null}

      <View style={styles.row}>
        {sources.includes('camera') ? (
          <View style={styles.flex}>
            <Button
              title={hasPhoto ? 'Retake photo' : 'Take photo'}
              variant={hasPhoto ? 'secondary' : 'primary'}
              onPress={() => onChoose('camera')}
              disabled={busy || disabled}
            />
          </View>
        ) : null}
        {sources.includes('library') ? (
          <View style={styles.flex}>
            <Button
              title="Choose from gallery"
              variant="secondary"
              onPress={() => onChoose('library')}
              disabled={busy || disabled}
            />
          </View>
        ) : null}
      </View>
    </View>
  );
}

/** Local preview for new photos; a short-lived signed URL for already-submitted ones. */
function usePreviewUri(state: PhotoState): string | null {
  const existingPath = state.kind === 'existing' ? state.path : null;
  const [signedUrl, setSignedUrl] = useState<string | null>(null);

  useEffect(() => {
    setSignedUrl(null);
    if (!existingPath) return;
    let active = true;
    supabase.storage
      .from(KYC_BUCKET)
      .createSignedUrl(existingPath, PREVIEW_URL_SECONDS)
      .then(({ data }) => {
        if (active && data) setSignedUrl(data.signedUrl);
      });
    return () => {
      active = false;
    };
  }, [existingPath]);

  if (state.kind === 'existing') return signedUrl;
  if (state.kind === 'empty') return null;
  return state.previewUri;
}

const styles = StyleSheet.create({
  container: {
    gap: spacing.sm,
    padding: spacing.md,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: 12,
  },
  label: { fontSize: 16, fontWeight: '600', color: colors.text },
  hint: { fontSize: 14, color: colors.muted },
  preview: { width: '100%', aspectRatio: 4 / 3, borderRadius: 8, backgroundColor: colors.surface },
  status: { gap: spacing.sm },
  row: { flexDirection: 'row', gap: spacing.sm, alignItems: 'center' },
  flex: { flex: 1 },
  muted: { fontSize: 14, color: colors.muted },
  success: { fontSize: 14, color: colors.success, fontWeight: '600' },
  error: { fontSize: 14, color: colors.danger },
});
