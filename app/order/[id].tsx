import { router, useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, Alert, StyleSheet, Text, View } from 'react-native';

import { Button } from '@/components/Button';
import { PaymentNotice } from '@/components/PaymentNotice';
import { Screen } from '@/components/Screen';
import { colors, spacing } from '@/constants/theme';
import { formatNaira } from '@/lib/commission';
import { canCustomerCancel, formatDistance, isActiveStatus, orderStatusView } from '@/lib/orders';
import { cancelOrder } from '@/lib/ordersApi';
import { formatNigerianPhone } from '@/lib/phone';
import { useOrder } from '@/lib/useOrders';

export default function OrderStatusScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { order, contact, loaded, error, reload } = useOrder(id);
  const [cancelling, setCancelling] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);

  useFocusEffect(
    useCallback(() => {
      reload();
    }, [reload]),
  );

  if (!loaded) {
    return (
      <Screen>
        <ActivityIndicator color={colors.primary} />
      </Screen>
    );
  }

  if (!order) {
    return (
      <Screen>
        <Text style={styles.error}>{error ?? 'We could not find this order.'}</Text>
        <Button title="Back to home" variant="secondary" onPress={() => router.replace('/')} />
      </Screen>
    );
  }

  const view = orderStatusView(order.status);

  async function doCancel() {
    if (!order) return;
    setCancelling(true);
    setActionError(null);
    const result = await cancelOrder(order.id);
    setCancelling(false);
    if (result.error) setActionError(result.error);
    await reload();
  }

  function askCancel() {
    Alert.alert('Cancel this order?', 'You can cancel for free until a rider accepts.', [
      { text: 'Keep order', style: 'cancel' },
      { text: 'Cancel order', style: 'destructive', onPress: doCancel },
    ]);
  }

  return (
    <Screen>
      <View style={[styles.card, view.tone === 'stopped' ? styles.stopped : null]}>
        <Text style={styles.eyebrow}>Order status</Text>
        <View style={styles.titleRow}>
          {view.tone === 'waiting' ? <ActivityIndicator color={colors.primary} /> : null}
          <Text style={styles.title}>{view.title}</Text>
        </View>
        <Text style={styles.body}>{view.body}</Text>
      </View>

      <View style={styles.card}>
        <Text style={styles.price}>{formatNaira(order.price_kobo)}</Text>
        {order.distance_m ? (
          <Text style={styles.body}>
            {formatDistance(order.distance_m)}
            {order.priced_with_fallback ? ' (estimated distance)' : ' by road'}
          </Text>
        ) : null}
        <Text style={styles.label}>From</Text>
        <Text style={styles.body}>{order.pickup_address}</Text>
        <Text style={styles.label}>To</Text>
        <Text style={styles.body}>{order.dropoff_address}</Text>
        {order.package_description ? (
          <>
            <Text style={styles.label}>Package</Text>
            <Text style={styles.body}>{order.package_description}</Text>
          </>
        ) : null}
        {contact ? (
          <>
            <Text style={styles.label}>Receiver</Text>
            <Text style={styles.body}>
              {contact.receiver_name} · {formatNigerianPhone(contact.receiver_phone)}
            </Text>
          </>
        ) : null}
      </View>

      {isActiveStatus(order.status) ? <PaymentNotice /> : null}

      {canCustomerCancel(order.status) ? (
        <Button title="Cancel order" variant="secondary" onPress={askCancel} loading={cancelling} />
      ) : null}
      {actionError ? <Text style={styles.error}>{actionError}</Text> : null}
      {error ? <Text style={styles.error}>{error}</Text> : null}
      <Button title="Back to home" variant="secondary" onPress={() => router.replace('/')} />
    </Screen>
  );
}

const styles = StyleSheet.create({
  card: { backgroundColor: colors.surface, borderRadius: 12, padding: spacing.md, gap: spacing.xs },
  stopped: { backgroundColor: '#fef2f2' },
  eyebrow: { fontSize: 13, fontWeight: '700', color: colors.muted, textTransform: 'uppercase' },
  titleRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
  title: { fontSize: 22, fontWeight: '700', color: colors.text },
  price: { fontSize: 26, fontWeight: '700', color: colors.text },
  label: { fontSize: 12, fontWeight: '700', color: colors.muted, textTransform: 'uppercase', marginTop: spacing.sm },
  body: { fontSize: 15, color: colors.text },
  error: { color: colors.danger, fontSize: 14 },
});
