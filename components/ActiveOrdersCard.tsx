import { Pressable, StyleSheet, Text, View } from 'react-native';

import { Button } from '@/components/Button';
import { colors, spacing } from '@/constants/theme';
import { formatNaira } from '@/lib/commission';
import { orderStatusView } from '@/lib/orders';
import type { OrderSummary } from '@/lib/useOrders';

type ActiveOrdersCardProps = {
  orders: OrderSummary[];
  error: string | null;
  onNewOrder: () => void;
  onOpenOrder: (id: string) => void;
};

export function ActiveOrdersCard({ orders, error, onNewOrder, onOpenOrder }: ActiveOrdersCardProps) {
  return (
    <View style={styles.card}>
      <Text style={styles.eyebrow}>Deliveries</Text>
      {orders.map((o) => (
        <Pressable
          key={o.id}
          accessibilityRole="button"
          onPress={() => onOpenOrder(o.id)}
          style={styles.order}
        >
          <Text style={styles.status}>{orderStatusView(o.status).title}</Text>
          <Text style={styles.line} numberOfLines={1}>
            To {o.dropoff_address}
          </Text>
          <Text style={styles.line}>{formatNaira(o.price_kobo)}</Text>
        </Pressable>
      ))}
      {error ? <Text style={styles.error}>{error}</Text> : null}
      <Button title="Send a package" onPress={onNewOrder} />
    </View>
  );
}

const styles = StyleSheet.create({
  card: { backgroundColor: colors.surface, borderRadius: 12, padding: spacing.md, gap: spacing.sm },
  eyebrow: { fontSize: 13, fontWeight: '700', color: colors.muted, textTransform: 'uppercase' },
  order: { backgroundColor: colors.background, borderRadius: 8, padding: spacing.sm, gap: 2 },
  status: { fontSize: 16, fontWeight: '700', color: colors.text },
  line: { fontSize: 14, color: colors.text },
  error: { color: colors.danger, fontSize: 14 },
});
