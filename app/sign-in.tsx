import { router } from 'expo-router';
import { useState } from 'react';
import { StyleSheet, Text } from 'react-native';

import { Button } from '@/components/Button';
import { Screen } from '@/components/Screen';
import { TextField } from '@/components/TextField';
import { colors } from '@/constants/theme';
import { friendlyAuthError } from '@/lib/authErrors';
import { normalizeNigerianPhone } from '@/lib/phone';
import { supabase } from '@/lib/supabase';

export default function SignInScreen() {
  const [input, setInput] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [sending, setSending] = useState(false);

  async function sendCode() {
    const phone = normalizeNigerianPhone(input);
    if (!phone) {
      setError('Enter a valid Nigerian mobile number, e.g. 0803 123 4567.');
      return;
    }

    setError(null);
    setSending(true);
    const { error: otpError } = await supabase.auth.signInWithOtp({ phone });
    setSending(false);

    if (otpError) {
      setError(friendlyAuthError(otpError));
      return;
    }
    router.push({ pathname: '/verify', params: { phone } });
  }

  return (
    <Screen>
      <Text style={styles.title}>Welcome to Dispatch</Text>
      <Text style={styles.subtitle}>Enter your phone number. We will text you a 6-digit code.</Text>
      <TextField
        label="Phone number"
        value={input}
        onChangeText={(text) => {
          setInput(text);
          if (error) setError(null);
        }}
        placeholder="0803 123 4567"
        keyboardType="phone-pad"
        autoComplete="tel"
        textContentType="telephoneNumber"
        returnKeyType="done"
        onSubmitEditing={sendCode}
        error={error}
      />
      <Button title="Send code" onPress={sendCode} loading={sending} disabled={!input.trim()} />
    </Screen>
  );
}

const styles = StyleSheet.create({
  title: { fontSize: 28, fontWeight: '700', color: colors.text },
  subtitle: { fontSize: 16, color: colors.muted },
});
