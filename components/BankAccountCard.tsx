import { StyleSheet, Text, View } from 'react-native';

import { Button } from '@/components/Button';
import { colors, spacing } from '@/constants/theme';
import { maskAccountNumber, type BankAccountRow, type BankCardState } from '@/lib/bankAccount';

type BankAccountCardProps = {
  state: BankCardState;
  onOpenForm: () => void;
};

/** The rider's receiving account on home. Numbers are always shown masked here. */
export function BankAccountCard({ state, onOpenForm }: BankAccountCardProps) {
  const alert = state.kind === 'rejected' || state.kind === 'revoked';

  return (
    <View style={[styles.card, alert ? styles.alert : null]}>
      <Text style={styles.eyebrow}>Where customers pay you</Text>

      {state.kind === 'none' ? (
        <>
          <Text style={styles.title}>Add your bank account</Text>
          <Text style={styles.body}>
            Customers pay you straight into this account at delivery. An admin checks it before you can go online.
          </Text>
          <Button title="Add bank account" onPress={onOpenForm} />
        </>
      ) : null}

      {state.kind === 'pending' ? (
        <>
          <Text style={styles.title}>Bank account under review</Text>
          <AccountLine account={state.pending} />
          <Text style={styles.body}>
            An admin will check that the account is in your name. You can go online once it is approved.
          </Text>
          <Button title="Fix a mistake" variant="secondary" onPress={onOpenForm} />
        </>
      ) : null}

      {state.kind === 'rejected' ? (
        <>
          <Text style={styles.title}>Bank account not approved</Text>
          <AccountLine account={state.latest} />
          <Text style={styles.reasonLabel}>Reason</Text>
          <Text style={styles.reason}>{state.latest.reason}</Text>
          <Button title="Add another account" onPress={onOpenForm} />
        </>
      ) : null}

      {state.kind === 'revoked' ? (
        <>
          <Text style={styles.title}>Bank account removed</Text>
          <AccountLine account={state.latest} />
          <Text style={styles.reasonLabel}>Reason</Text>
          <Text style={styles.reason}>{state.latest.reason}</Text>
          <Text style={styles.body}>You cannot go online until a new account is approved.</Text>
          <Button title="Add a new account" onPress={onOpenForm} />
        </>
      ) : null}

      {state.kind === 'verified' ? (
        <>
          <AccountLine account={state.verified} />
          {state.pending ? (
            <Text style={styles.body}>
              Change under review: {state.pending.bank_name} {maskAccountNumber(state.pending.account_number)}. Customers
              keep paying into your current account until it is approved.
            </Text>
          ) : null}
          {state.rejectedChange ? (
            <Text style={styles.reason}>Your account change was not approved: {state.rejectedChange.reason}</Text>
          ) : null}
          <Button title="Change bank account" variant="secondary" onPress={onOpenForm} />
        </>
      ) : null}
    </View>
  );
}

function AccountLine({ account }: { account: BankAccountRow }) {
  return (
    <View style={styles.accountLine}>
      <Text style={styles.accountMain}>
        {account.bank_name} · {maskAccountNumber(account.account_number)}
      </Text>
      <Text style={styles.accountName}>{account.account_name}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  card: { backgroundColor: colors.surface, borderRadius: 12, padding: spacing.md, gap: spacing.sm },
  alert: { backgroundColor: '#fef2f2', borderWidth: 1, borderColor: '#fecaca' },
  eyebrow: { fontSize: 13, fontWeight: '700', color: colors.muted, textTransform: 'uppercase' },
  title: { fontSize: 20, fontWeight: '700', color: colors.text },
  body: { fontSize: 15, color: colors.text },
  accountLine: { gap: 2 },
  accountMain: { fontSize: 17, fontWeight: '600', color: colors.text },
  accountName: { fontSize: 15, color: colors.muted },
  reasonLabel: { fontSize: 13, fontWeight: '700', color: colors.danger, textTransform: 'uppercase' },
  reason: { fontSize: 15, color: colors.danger },
});
