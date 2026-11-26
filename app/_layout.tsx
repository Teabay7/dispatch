import { useFonts } from 'expo-font';
import { Stack } from 'expo-router';
import * as SplashScreen from 'expo-splash-screen';
import { useEffect } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import 'react-native-reanimated';

import { Button } from '@/components/Button';
import { colors, spacing } from '@/constants/theme';
import { SessionProvider, useSession } from '@/lib/session';
import { supabase } from '@/lib/supabase';

export {
  // Catch any errors thrown by the Layout component.
  ErrorBoundary,
} from 'expo-router';

// Prevent the splash screen from auto-hiding before asset loading is complete.
SplashScreen.preventAutoHideAsync();

export default function RootLayout() {
  const [loaded, error] = useFonts({
    SpaceMono: require('../assets/fonts/SpaceMono-Regular.ttf'),
  });

  useEffect(() => {
    if (error) throw error;
  }, [error]);

  if (!loaded) {
    return null;
  }

  return (
    <SessionProvider>
      <RootNavigator />
    </SessionProvider>
  );
}

function RootNavigator() {
  const { loading, session, isOnboarded, error, refresh } = useSession();
  const signedIn = !!session;

  useEffect(() => {
    if (!loading) SplashScreen.hideAsync();
  }, [loading]);

  if (loading) {
    return null; // Splash screen stays visible.
  }

  if (signedIn && error) {
    return <AccountLoadError message={error} onRetry={refresh} />;
  }

  // Routes are only reachable when their guard is true; otherwise the user is
  // sent to the right starting screen for where they are in sign-up.
  const start = !signedIn ? '/sign-in' : !isOnboarded ? '/onboarding' : '/';

  return (
    <Stack>
      <Stack.Protected guard={!signedIn} redirectTo={start}>
        <Stack.Screen name="sign-in" options={{ title: 'Sign in' }} />
        <Stack.Screen name="verify" options={{ title: 'Enter code' }} />
      </Stack.Protected>

      <Stack.Protected guard={signedIn && !isOnboarded} redirectTo={start}>
        <Stack.Screen name="onboarding" options={{ title: 'About you' }} />
      </Stack.Protected>

      <Stack.Protected guard={signedIn && isOnboarded} redirectTo={start}>
        <Stack.Screen name="index" options={{ title: 'Dispatch' }} />
      </Stack.Protected>

      <Stack.Protected guard={signedIn} redirectTo={start}>
        <Stack.Screen name="rider-kyc" options={{ title: 'Rider verification' }} />
        <Stack.Screen name="rider-bank" options={{ title: 'Bank account' }} />
        <Stack.Screen name="order/new" options={{ title: 'New delivery' }} />
        <Stack.Screen name="order/[id]" options={{ title: 'Your delivery' }} />
        <Stack.Screen name="job/[id]" options={{ title: 'Your job' }} />
      </Stack.Protected>
    </Stack>
  );
}

function AccountLoadError({ message, onRetry }: { message: string; onRetry: () => void }) {
  return (
    <View style={styles.errorContainer}>
      <Text style={styles.errorText}>{message}</Text>
      <Button title="Try again" onPress={onRetry} />
      <Button title="Sign out" variant="secondary" onPress={() => supabase.auth.signOut()} />
    </View>
  );
}

const styles = StyleSheet.create({
  errorContainer: {
    flex: 1,
    justifyContent: 'center',
    padding: spacing.lg,
    gap: spacing.md,
    backgroundColor: colors.background,
  },
  errorText: { fontSize: 16, color: colors.text, textAlign: 'center' },
});
