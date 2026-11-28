import { useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { Button } from '@/components/Button';
import { TextField } from '@/components/TextField';
import { colors, spacing } from '@/constants/theme';
import { disputeDetailsError, disputeReasons, type DisputeReason, type DisputeRole } from '@/lib/delivery';
import { raisePaymentDispute } from '@/lib/deliveryApi';

type DisputeFormProps = {
  orderId: string;
  role: DisputeRole;
  onDone: () => void;
};

/** "Report a payment problem": a reason and optional details. Text only in the pilot. */
export function DisputeForm({ orderId, role, onDone }: DisputeFormProps) {
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState<DisputeReason | null>(null);
  const [details, setDetails] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (!open) {
    return <Button title="Report a payment problem" variant="secondary" onPress={() => setOpen(true)} />;
  }

  async function submit() {
    if (!reason) {
      setError('Choose a reason');
      return;
    }
    const detailsError = disputeDetailsError(details);
    if (detailsError) {
      setError(detailsError);
      return;
    }
    setBusy(true);
    setError(null);
    const result = await raisePaymentDispute(orderId, reason, details);
    setBusy(false);
    if (result.error !== null) {
      setError(result.error);
      return;
    }
    setOpen(false);
    onDone();
  }

  return (
    <View style={styles.card}>
      <Text style={styles.label}>What went wrong?</Text>
      {disputeReasons(role).map((r) => (
        <Button
          key={r.code}
          title={(reason === r.code ? '● ' : '○ ') + r.label}
          variant="secondary"
          onPress={() => setReason(r.code)}
          disabled={busy}
        />
      ))}
      <TextField
        label="Details (optional)"
        value={details}
        onChangeText={setDetails}
        placeholder="For example: when you paid and from which bank"
        multiline
        maxLength={500}
      />
      <Text style={styles.muted}>Don't include phone or account numbers. Dispatch will contact you.</Text>
      {error ? <Text style={styles.error}>{error}</Text> : null}
      <Button title="Send to Dispatch" onPress={submit} loading={busy} />
      <Button title="Back" variant="secondary" onPress={() => setOpen(false)} disabled={busy} />
    </View>
  );
}

const styles = StyleSheet.create({
  card: { backgroundColor: colors.surface, borderRadius: 12, padding: spacing.md, gap: spacing.sm },
  label: { fontSize: 12, fontWeight: '700', color: colors.muted, textTransform: 'uppercase' },
  muted: { fontSize: 13, color: colors.muted },
  error: { fontSize: 14, color: colors.danger },
});
