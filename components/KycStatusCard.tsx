import { StyleSheet, Text, View } from 'react-native';

import { Button } from '@/components/Button';
import { colors, spacing } from '@/constants/theme';
import type { KycCardState } from '@/lib/kyc';

type KycStatusCardProps = {
  state: KycCardState;
  rejectionReason: string | null;
  submittedAt: string | null;
  /** Has an active customer role (suspension is per role, so they can still order). */
  canOrder: boolean;
  onOpenForm: () => void;
};

const TITLES: Record<KycCardState, string> = {
  not_started: 'Verify to start riding',
  pending: 'Verification under review',
  approved: 'Verified rider',
  rejected: 'Verification not approved',
  suspended: 'Rider account suspended',
};

export function KycStatusCard({ state, rejectionReason, submittedAt, canOrder, onOpenForm }: KycStatusCardProps) {
  return (
    <View style={[styles.card, state === 'rejected' || state === 'suspended' ? styles.alert : null]}>
      <Text style={styles.eyebrow}>Rider verification</Text>
      <Text style={styles.title}>{TITLES[state]}</Text>

      {state === 'not_started' ? (
        <Text style={styles.body}>
          Add your ID photo, a selfie and your bike details. An admin reviews every rider before they can go online.
        </Text>
      ) : null}

      {state === 'pending' ? (
        <Text style={styles.body}>
          Submitted {submittedAt ? formatDate(submittedAt) : ''}. An admin will review it; check back here for the
          result. Your details cannot be changed while they are under review.
        </Text>
      ) : null}

      {state === 'approved' ? <Text style={styles.body}>You are approved. Go online from the home screen.</Text> : null}

      {state === 'rejected' ? (
        <>
          <Text style={styles.reasonLabel}>Reason</Text>
          <Text style={styles.reason}>{rejectionReason}</Text>
        </>
      ) : null}

      {state === 'suspended' ? (
        <Text style={styles.body}>
          Your rider account is suspended, so you cannot go online or submit verification.
          {canOrder ? ' You can still order deliveries.' : ''}
        </Text>
      ) : null}

      {state === 'not_started' ? <Button title="Start verification" onPress={onOpenForm} /> : null}
      {state === 'rejected' ? <Button title="Fix and resubmit" onPress={onOpenForm} /> : null}
    </View>
  );
}

function formatDate(iso: string): string {
  return new Date(iso).toLocaleDateString('en-NG', { day: 'numeric', month: 'short', year: 'numeric' });
}

const styles = StyleSheet.create({
  card: { backgroundColor: colors.surface, borderRadius: 12, padding: spacing.md, gap: spacing.sm },
  alert: { backgroundColor: '#fef2f2', borderWidth: 1, borderColor: '#fecaca' },
  eyebrow: { fontSize: 13, fontWeight: '700', color: colors.muted, textTransform: 'uppercase' },
  title: { fontSize: 20, fontWeight: '700', color: colors.text },
  body: { fontSize: 15, color: colors.text },
  reasonLabel: { fontSize: 13, fontWeight: '700', color: colors.danger, textTransform: 'uppercase' },
  reason: { fontSize: 16, color: colors.danger },
});
