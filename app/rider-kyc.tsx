import { Redirect, router } from 'expo-router';
import { useState } from 'react';
import { ActivityIndicator, StyleSheet, Text, View } from 'react-native';

import { Button } from '@/components/Button';
import { KycStatusCard } from '@/components/KycStatusCard';
import { PhotoField } from '@/components/PhotoField';
import { Screen } from '@/components/Screen';
import { TextField } from '@/components/TextField';
import { colors, spacing } from '@/constants/theme';
import {
  canEditKyc,
  cleanPlate,
  cleanText,
  friendlyKycError,
  hasErrors,
  kycCardState,
  validateKycForm,
  type KycFormErrors,
  type KycFormValues,
} from '@/lib/kyc';
import { useSession } from '@/lib/session';
import { supabase } from '@/lib/supabase';
import { useKycPhoto } from '@/lib/useKycPhoto';
import { useRiderKyc, type RiderDetails } from '@/lib/useRiderKyc';

/** Back to the home screen it came from (which reloads the status), or to home after onboarding. */
function goHome() {
  if (router.canGoBack()) router.back();
  else router.replace('/');
}

export default function RiderKycScreen() {
  const { roles } = useSession();
  const riderRole = roles.find((r) => r.role === 'rider');
  const { details, loading, error, reload } = useRiderKyc(!!riderRole);

  if (!riderRole) return <Redirect href="/" />;

  if (loading) {
    return (
      <Screen>
        <ActivityIndicator color={colors.primary} />
      </Screen>
    );
  }

  if (error) {
    return (
      <Screen>
        <Text style={styles.error}>{error}</Text>
        <Button title="Try again" onPress={reload} />
      </Screen>
    );
  }

  const state = kycCardState(riderRole.status, details?.kyc_status ?? null);
  if (!canEditKyc(state)) {
    // Pending, approved or suspended: nothing to fill in here.
    return (
      <Screen>
        <KycStatusCard
          state={state}
          rejectionReason={details?.rejection_reason ?? null}
          submittedAt={details?.submitted_at ?? null}
          canOrder={roles.some((r) => r.role === 'customer' && r.status === 'active')}
          onOpenForm={() => undefined}
        />
        <Button title="Back to home" variant="secondary" onPress={goHome} />
      </Screen>
    );
  }

  return <KycForm details={details} />;
}

function KycForm({ details }: { details: RiderDetails | null }) {
  const { session, profile } = useSession();
  const userId = session?.user.id ?? null;
  const resubmitting = details?.kyc_status === 'rejected';

  const [values, setValues] = useState<KycFormValues>({
    fullName: details?.full_name ?? profile?.full_name ?? '',
    bikeMakeModel: details?.bike_make_model ?? '',
    bikeColour: details?.bike_colour ?? '',
    plateNumber: details?.plate_number ?? '',
  });
  const [errors, setErrors] = useState<KycFormErrors>({});
  const [formError, setFormError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const idPhoto = useKycPhoto(userId, 'id-front', details?.id_photo_path ?? null);
  const selfie = useKycPhoto(userId, 'selfie', details?.selfie_path ?? null);
  const uploading = idPhoto.busy || selfie.busy;

  function update(field: keyof KycFormValues, text: string) {
    setValues((v) => ({ ...v, [field]: text }));
    if (errors[field]) setErrors((e) => ({ ...e, [field]: undefined }));
    setFormError(null);
  }

  async function submit() {
    const fieldErrors = validateKycForm(values);
    setErrors(fieldErrors);
    if (hasErrors(fieldErrors)) return;
    if (!idPhoto.path || !selfie.path) {
      setFormError('Add both your ID photo and a selfie before submitting.');
      return;
    }
    if (!userId) return;

    const row = {
      full_name: cleanText(values.fullName),
      bike_make_model: cleanText(values.bikeMakeModel),
      bike_colour: cleanText(values.bikeColour),
      plate_number: cleanPlate(values.plateNumber),
      id_photo_path: idPhoto.path,
      selfie_path: selfie.path,
    };

    setSubmitting(true);
    setFormError(null);
    const { error } = resubmitting
      ? await supabase.from('rider_details').update({ ...row, kyc_status: 'pending' }).eq('user_id', userId)
      : await supabase.from('rider_details').insert({ ...row, user_id: userId });
    setSubmitting(false);

    if (error) {
      setFormError(friendlyKycError(error.message));
      return;
    }
    goHome();
  }

  return (
    <Screen>
      <Text style={styles.title}>{resubmitting ? 'Fix and resubmit' : 'Rider verification'}</Text>
      <Text style={styles.body}>
        An admin checks these details by hand before you can go online. Use clear, well-lit photos.
      </Text>
      {resubmitting && details?.rejection_reason ? (
        <View style={styles.reasonBox}>
          <Text style={styles.reasonLabel}>Why it was not approved</Text>
          <Text style={styles.reason}>{details.rejection_reason}</Text>
        </View>
      ) : null}

      <TextField
        label="Full name (as on your ID)"
        value={values.fullName}
        onChangeText={(t) => update('fullName', t)}
        autoCapitalize="words"
        autoComplete="name"
        error={errors.fullName}
      />

      <PhotoField
        label="ID photo (front)"
        hint="Your NIN slip, voter's card, driver's licence or international passport. All four corners visible."
        state={idPhoto.state}
        sources={['camera', 'library']}
        onChoose={idPhoto.choose}
        onRetry={idPhoto.retry}
        disabled={submitting}
      />

      <PhotoField
        label="Selfie"
        hint="Take a clear photo of your face with the front camera. No hat or sunglasses."
        state={selfie.state}
        sources={['camera']}
        onChoose={selfie.choose}
        onRetry={selfie.retry}
        disabled={submitting}
      />

      <Text style={styles.section}>Your bike</Text>
      <TextField
        label="Make and model"
        value={values.bikeMakeModel}
        onChangeText={(t) => update('bikeMakeModel', t)}
        placeholder="e.g. Bajaj Boxer 150"
        autoCapitalize="words"
        error={errors.bikeMakeModel}
      />
      <TextField
        label="Colour"
        value={values.bikeColour}
        onChangeText={(t) => update('bikeColour', t)}
        placeholder="e.g. Red"
        autoCapitalize="words"
        error={errors.bikeColour}
      />
      <TextField
        label="Plate number"
        value={values.plateNumber}
        onChangeText={(t) => update('plateNumber', t)}
        placeholder="e.g. EDE 123 AA"
        autoCapitalize="characters"
        autoCorrect={false}
        error={errors.plateNumber}
      />

      {formError ? <Text style={styles.error}>{formError}</Text> : null}
      <Button
        title={uploading ? 'Waiting for photos to upload…' : resubmitting ? 'Resubmit for review' : 'Submit for review'}
        onPress={submit}
        loading={submitting}
        disabled={uploading}
      />
    </Screen>
  );
}

const styles = StyleSheet.create({
  title: { fontSize: 28, fontWeight: '700', color: colors.text },
  body: { fontSize: 15, color: colors.muted },
  section: { fontSize: 18, fontWeight: '700', color: colors.text, marginTop: spacing.sm },
  reasonBox: { backgroundColor: '#fef2f2', borderRadius: 12, padding: spacing.md, gap: spacing.xs },
  reasonLabel: { fontSize: 13, fontWeight: '700', color: colors.danger, textTransform: 'uppercase' },
  reason: { fontSize: 16, color: colors.danger },
  error: { color: colors.danger, fontSize: 14 },
});
