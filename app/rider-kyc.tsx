import { router } from 'expo-router';
import { StyleSheet, Text, View } from 'react-native';

import { Button } from '@/components/Button';
import { Screen } from '@/components/Screen';
import { colors, spacing } from '@/constants/theme';

// Placeholder until the rider KYC feature is built (SPEC.md §10.7).
export default function RiderKycScreen() {
  return (
    <Screen>
      <Text style={styles.title}>Rider verification</Text>
      <Text style={styles.body}>Thanks for signing up to ride with Dispatch.</Text>
      <View style={styles.card}>
        <Text style={styles.cardTitle}>Coming next</Text>
        <Text style={styles.body}>You will be asked for:</Text>
        <Text style={styles.item}>• A photo of your ID</Text>
        <Text style={styles.item}>• A selfie</Text>
        <Text style={styles.item}>• Your bike details and plate number</Text>
        <Text style={styles.body}>
          An admin reviews every rider. You can go online once you are approved.
        </Text>
      </View>
      <Button title="Continue" onPress={() => router.replace('/')} />
    </Screen>
  );
}

const styles = StyleSheet.create({
  title: { fontSize: 28, fontWeight: '700', color: colors.text },
  body: { fontSize: 16, color: colors.text },
  card: { backgroundColor: colors.surface, borderRadius: 12, padding: spacing.md, gap: spacing.sm },
  cardTitle: { fontSize: 14, fontWeight: '700', color: colors.primary, textTransform: 'uppercase' },
  item: { fontSize: 16, color: colors.text },
});
