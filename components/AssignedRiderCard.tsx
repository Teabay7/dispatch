import { Linking, Pressable, StyleSheet, Text, View } from 'react-native';

import { colors, spacing } from '@/constants/theme';
import { mapsUrl, riderLocationLine } from '@/lib/dispatch';
import type { AssignedRiderLocation, OrderRider } from '@/lib/dispatchApi';
import type { OrderStatus } from '@/lib/orders';

type AssignedRiderCardProps = {
  rider: OrderRider;
  location: AssignedRiderLocation | null;
  status: OrderStatus;
};

/** The customer's view of the assigned rider. Bank details appear only while payment is due. */
export function AssignedRiderCard({ rider, location, status }: AssignedRiderCardProps) {
  const now = Date.now();
  return (
    <View style={styles.card}>
      <Text style={styles.eyebrow}>Your rider</Text>
      <Text style={styles.name}>{rider.rider_name}</Text>
      <Text style={styles.body}>
        {rider.bike_colour} {rider.bike_make_model} · Plate {rider.plate_number}
      </Text>
      <Text style={styles.muted}>Check the plate number before you hand over the package.</Text>

      {location ? (
        <View style={styles.location}>
          <Text style={styles.body}>{riderLocationLine(location, status, now)}</Text>
          <Pressable accessibilityRole="link" onPress={() => Linking.openURL(mapsUrl(location.lat, location.lng))}>
            <Text style={styles.link}>Open the rider's location in Maps</Text>
          </Pressable>
        </View>
      ) : (
        <Text style={styles.muted}>The rider's location will show here when their app sends it.</Text>
      )}

      {rider.account_number ? (
        <View style={styles.bank}>
          <Text style={styles.bankTitle}>Pay the rider by bank transfer</Text>
          <Text style={styles.body}>{rider.bank_name}</Text>
          <Text style={styles.accountNumber} selectable>
            {rider.account_number}
          </Text>
          <Text style={styles.body}>{rider.account_name}</Text>
          <Text style={styles.muted}>Pay only into this account, and only when the rider is with you.</Text>
        </View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  card: { backgroundColor: colors.surface, borderRadius: 12, padding: spacing.md, gap: spacing.xs },
  eyebrow: { fontSize: 13, fontWeight: '700', color: colors.muted, textTransform: 'uppercase' },
  name: { fontSize: 20, fontWeight: '700', color: colors.text },
  body: { fontSize: 15, color: colors.text },
  muted: { fontSize: 13, color: colors.muted },
  location: { gap: 2, marginTop: spacing.xs },
  link: { fontSize: 15, fontWeight: '600', color: colors.primary },
  bank: { backgroundColor: '#fef9c3', borderRadius: 8, padding: spacing.sm, gap: 2, marginTop: spacing.sm },
  bankTitle: { fontSize: 15, fontWeight: '700', color: '#713f12' },
  accountNumber: { fontSize: 22, fontWeight: '700', color: colors.text, letterSpacing: 1 },
});
