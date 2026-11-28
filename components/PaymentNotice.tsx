import { StyleSheet, Text, View } from 'react-native';

import { spacing } from '@/constants/theme';

/** SPEC 10.4: the customer pays the rider directly; Dispatch takes no payment in the app. */
export function PaymentNotice() {
  return (
    <View style={styles.box} accessibilityRole="text">
      <Text style={styles.title}>You pay the rider directly</Text>
      <Text style={styles.body}>
        When the rider arrives at the drop-off, pay them by bank transfer into the account shown in the app. They hand
        over the package once they see your payment. Dispatch does not take any payment in the app. Never pay before the
        rider arrives.
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  box: { backgroundColor: '#fef9c3', borderRadius: 8, padding: spacing.sm, gap: spacing.xs },
  title: { fontSize: 15, fontWeight: '700', color: '#713f12' },
  body: { fontSize: 14, color: '#713f12' },
});
