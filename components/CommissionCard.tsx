import { StyleSheet, Text, View } from 'react-native';

import { colors, spacing } from '@/constants/theme';
import {
  formatNaira,
  hasCompanyAccount,
  owedLine,
  tripsLine,
  type CommissionCardState,
  type CompanyAccount,
  type EntryRow,
} from '@/lib/commission';

type CommissionCardProps = {
  state: CommissionCardState;
  company: CompanyAccount | null;
  /** Recorded payments, newest first: the rider's receipts. */
  recentPayments: EntryRow[];
};

export function CommissionCard({ state, company, recentPayments }: CommissionCardProps) {
  return (
    <View style={[styles.card, state.kind === 'due' ? styles.alert : null]}>
      <Text style={styles.eyebrow}>Dispatch commission</Text>

      {state.kind === 'open' ? (
        <>
          <Text style={styles.title}>
            {tripsLine(state.tripCount, state.tripsRequired)} · {owedLine(state.balanceKobo)}
          </Text>
          <Text style={styles.body}>
            After {state.tripsRequired} trips, pay what you owe before you can go online again.
          </Text>
        </>
      ) : (
        <>
          <Text style={styles.title}>Commission due: {formatNaira(state.owedKobo)}</Text>
          {state.receivedSinceDueKobo > 0 ? (
            <Text style={styles.body}>
              {formatNaira(state.receivedSinceDueKobo)} received so far. {formatNaira(state.owedKobo)} left to pay.
            </Text>
          ) : null}
          <Text style={styles.body}>You have finished {state.tripsRequired} trips. Pay by bank transfer to:</Text>
          {hasCompanyAccount(company) ? (
            <View style={styles.payBox}>
              <Text style={styles.payLine}>{company.bank_name}</Text>
              <Text style={styles.payNumber} selectable>
                {company.account_number}
              </Text>
              <Text style={styles.payLine}>{company.account_name}</Text>
            </View>
          ) : (
            <Text style={styles.body}>Contact Dispatch support for the account details.</Text>
          )}
          <Text style={styles.label}>Write this reference in the transfer narration</Text>
          <Text style={styles.reference} selectable>
            {state.referenceCode}
          </Text>
          <Text style={styles.body}>
            You can go online again after Dispatch records your payment. Pay the full amount: part payments are
            recorded but you stay offline until it is all paid.
          </Text>
        </>
      )}

      {recentPayments.length > 0 ? (
        <View style={styles.receipts}>
          <Text style={styles.label}>Payments recorded</Text>
          {recentPayments.map((p) => (
            <Text key={p.id} style={styles.receipt}>
              {formatNaira(-p.amount_kobo)} · {formatDate(p.paid_at ?? p.created_at)}
            </Text>
          ))}
        </View>
      ) : null}
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
  label: { fontSize: 13, fontWeight: '700', color: colors.muted, textTransform: 'uppercase' },
  payBox: { backgroundColor: colors.background, borderRadius: 8, padding: spacing.sm, gap: 2 },
  payLine: { fontSize: 15, color: colors.text },
  payNumber: { fontSize: 22, fontWeight: '700', color: colors.text, letterSpacing: 1 },
  reference: { fontSize: 22, fontWeight: '700', color: colors.primary, letterSpacing: 1 },
  receipts: { gap: 2, marginTop: spacing.xs },
  receipt: { fontSize: 14, color: colors.text },
});
