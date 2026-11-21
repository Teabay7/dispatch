import { Redirect, router, useLocalSearchParams } from 'expo-router';
import { useEffect, useState } from 'react';
import { StyleSheet, Text } from 'react-native';

import { Button } from '@/components/Button';
import { Screen } from '@/components/Screen';
import { TextField } from '@/components/TextField';
import { colors } from '@/constants/theme';
import { friendlyAuthError } from '@/lib/authErrors';
import { formatNigerianPhone, normalizeNigerianPhone } from '@/lib/phone';
import { supabase } from '@/lib/supabase';

// Matches auth.sms.max_frequency in supabase/config.toml and the hosted setting.
const RESEND_SECONDS = 60;

export default function VerifyScreen() {
  const params = useLocalSearchParams<{ phone?: string }>();
  const phone = normalizeNigerianPhone(params.phone ?? '');

  const [code, setCode] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);
  const [verifying, setVerifying] = useState(false);
  const [resending, setResending] = useState(false);
  const [secondsLeft, setSecondsLeft] = useState(RESEND_SECONDS);

  useEffect(() => {
    if (secondsLeft <= 0) return;
    const timer = setTimeout(() => setSecondsLeft((s) => s - 1), 1000);
    return () => clearTimeout(timer);
  }, [secondsLeft]);

  if (!phone) {
    return <Redirect href="/sign-in" />;
  }

  async function verify(token: string) {
    if (token.length !== 6 || verifying || !phone) return;
    setError(null);
    setInfo(null);
    setVerifying(true);
    const { error: verifyError } = await supabase.auth.verifyOtp({ phone, token, type: 'sms' });
    setVerifying(false);
    if (verifyError) {
      setError(friendlyAuthError(verifyError));
      setCode('');
    }
    // On success the session changes and the root layout moves the user on.
  }

  async function resend() {
    if (!phone) return;
    setError(null);
    setInfo(null);
    setResending(true);
    const { error: otpError } = await supabase.auth.signInWithOtp({ phone });
    setResending(false);
    if (otpError) {
      setError(friendlyAuthError(otpError));
      return;
    }
    setInfo('We sent you a new code.');
    setSecondsLeft(RESEND_SECONDS);
  }

  return (
    <Screen>
      <Text style={styles.title}>Enter your code</Text>
      <Text style={styles.subtitle}>We sent a 6-digit code to {formatNigerianPhone(phone)}.</Text>
      <TextField
        label="Code"
        value={code}
        onChangeText={(text) => {
          const digits = text.replace(/\D/g, '').slice(0, 6);
          setCode(digits);
          if (digits.length === 6) verify(digits);
        }}
        placeholder="123456"
        keyboardType="number-pad"
        autoComplete="sms-otp"
        textContentType="oneTimeCode"
        maxLength={6}
        autoFocus
        error={error}
      />
      {info ? <Text style={styles.info}>{info}</Text> : null}
      <Button title="Verify" onPress={() => verify(code)} loading={verifying} disabled={code.length !== 6} />
      <Button
        title={secondsLeft > 0 ? `Resend code in ${secondsLeft}s` : 'Resend code'}
        variant="secondary"
        onPress={resend}
        loading={resending}
        disabled={secondsLeft > 0}
      />
      <Button title="Change number" variant="secondary" onPress={() => router.back()} />
    </Screen>
  );
}

const styles = StyleSheet.create({
  title: { fontSize: 28, fontWeight: '700', color: colors.text },
  subtitle: { fontSize: 16, color: colors.muted },
  info: { fontSize: 14, color: colors.success },
});
