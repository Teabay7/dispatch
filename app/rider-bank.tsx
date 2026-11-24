import { Redirect, router } from 'expo-router';
import { useState } from 'react';
import { ActivityIndicator, StyleSheet, Text, View } from 'react-native';

import { BankPicker } from '@/components/BankPicker';
import { Button } from '@/components/Button';
import { Screen } from '@/components/Screen';
import { TextField } from '@/components/TextField';
import { colors, spacing } from '@/constants/theme';
import {
  chosenBankName,
  cleanAccountNumber,
  cleanName,
  friendlyBankError,
  maskAccountNumber,
  OTHER_BANK,
  validateBankForm,
  type BankFormErrors,
  type BankFormValues,
} from '@/lib/bankAccount';
import { useSession } from '@/lib/session';
import { supabase } from '@/lib/supabase';
import { useRiderBankAccount } from '@/lib/useRiderBankAccount';

function goHome() {
  if (router.canGoBack()) router.back();
  else router.replace('/');
}

export default function RiderBankScreen() {
  const { roles } = useSession();
  const riderRole = roles.find((r) => r.role === 'rider');
  const bank = useRiderBankAccount(!!riderRole);
  const [values, setValues] = useState<BankFormValues>({ bank: '', otherBank: '', accountNumber: '', accountName: '' });
  const [errors, setErrors] = useState<BankFormErrors>({});
  const [formError, setFormError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  if (!riderRole) return <Redirect href="/" />;

  if (!bank.loaded) {
    return (
      <Screen>
        {bank.error ? (
          <>
            <Text style={styles.error}>{bank.error}</Text>
            <Button title="Try again" onPress={bank.reload} />
          </>
        ) : (
          <ActivityIndicator color={colors.primary} />
        )}
      </Screen>
    );
  }

  const current = bank.state.kind === 'verified' ? bank.state.verified : null;

  function update(field: keyof BankFormValues, text: string) {
    setValues((v) => ({ ...v, [field]: text }));
    const errorKey = field === 'otherBank' ? 'bank' : field;
    if (errors[errorKey]) setErrors((e) => ({ ...e, [errorKey]: undefined }));
    setFormError(null);
  }

  async function submit() {
    const fieldErrors = validateBankForm(values);
    setErrors(fieldErrors);
    if (Object.keys(fieldErrors).length > 0) return;

    setSubmitting(true);
    setFormError(null);
    const { error } = await supabase.rpc('submit_rider_bank_account', {
      p_bank_name: chosenBankName(values),
      p_account_number: cleanAccountNumber(values.accountNumber),
      p_account_name: cleanName(values.accountName),
    });
    setSubmitting(false);

    if (error) {
      setFormError(friendlyBankError(error.message));
      return;
    }
    goHome();
  }

  return (
    <Screen>
      <Text style={styles.title}>{current ? 'Change bank account' : 'Your bank account'}</Text>
      <Text style={styles.body}>
        Customers pay you directly into this account when you deliver. It must be in your own name, as on your ID. An
        admin checks it before you can go online.
      </Text>
      {current ? (
        <View style={styles.notice}>
          <Text style={styles.noticeText}>
            Customers keep paying into {current.bank_name} {maskAccountNumber(current.account_number)} until the new
            account is approved. Dispatch may phone you to confirm the change.
          </Text>
        </View>
      ) : null}

      <BankPicker value={values.bank} onChange={(b) => update('bank', b)} error={errors.bank} disabled={submitting} />
      {values.bank === OTHER_BANK ? (
        <TextField
          label="Bank name"
          value={values.otherBank}
          onChangeText={(t) => update('otherBank', t)}
          autoCapitalize="words"
          error={errors.bank}
        />
      ) : null}

      <TextField
        label="Account number (10 digits)"
        value={values.accountNumber}
        onChangeText={(t) => update('accountNumber', t)}
        keyboardType="number-pad"
        maxLength={13}
        autoComplete="off"
        autoCorrect={false}
        error={errors.accountNumber}
      />
      <TextField
        label="Account name (as your bank shows it)"
        value={values.accountName}
        onChangeText={(t) => update('accountName', t)}
        autoCapitalize="characters"
        autoCorrect={false}
        error={errors.accountName}
      />

      {formError ? <Text style={styles.error}>{formError}</Text> : null}
      <Button title="Submit for review" onPress={submit} loading={submitting} />
      <Button title="Not now" variant="secondary" onPress={goHome} disabled={submitting} />
    </Screen>
  );
}

const styles = StyleSheet.create({
  title: { fontSize: 28, fontWeight: '700', color: colors.text },
  body: { fontSize: 15, color: colors.muted },
  notice: { backgroundColor: '#fef9c3', borderRadius: 8, padding: spacing.sm },
  noticeText: { fontSize: 14, color: '#713f12' },
  error: { color: colors.danger, fontSize: 14 },
});
