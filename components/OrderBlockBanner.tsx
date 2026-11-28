import { Pressable, StyleSheet, Text } from 'react-native';

import { colors, spacing } from '@/constants/theme';
import { orderBlockMessage, type OrderBlockReason } from '@/lib/delivery';

type OrderBlockBannerProps = {
  reason: OrderBlockReason;
  onOpen: () => void;
};

/** Shown while the customer can't place new orders (the database enforces it). */
export function OrderBlockBanner({ reason, onOpen }: OrderBlockBannerProps) {
  return (
    <Pressable accessibilityRole="button" onPress={onOpen} style={styles.banner}>
      <Text style={styles.title}>You can't place new orders yet</Text>
      <Text style={styles.body}>{orderBlockMessage(reason)}</Text>
      <Text style={styles.link}>Open that order</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  banner: { backgroundColor: '#fef2f2', borderRadius: 12, padding: spacing.md, gap: spacing.xs },
  title: { fontSize: 16, fontWeight: '700', color: colors.danger },
  body: { fontSize: 15, color: colors.text },
  link: { fontSize: 15, fontWeight: '600', color: colors.primary },
});
