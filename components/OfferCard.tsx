import { useEffect, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { Button } from '@/components/Button';
import { colors, spacing } from '@/constants/theme';
import { formatNaira } from '@/lib/commission';
import { distanceFromYou, formatCountdown, offerSecondsLeft } from '@/lib/dispatch';
import type { Offer } from '@/lib/dispatchApi';
import { formatDistance } from '@/lib/orders';

type OfferCardProps = {
  offer: Offer;
  fetchedAt: number;
  busy: 'accept' | 'decline' | null;
  error: string | null;
  onAccept: () => void;
  onDecline: () => void;
};

/** An incoming offer: area and distance only (no address until accepted). */
export function OfferCard({ offer, fetchedAt, busy, error, onAccept, onDecline }: OfferCardProps) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, []);
  const secondsLeft = offerSecondsLeft(offer.seconds_left, fetchedAt, now);

  return (
    <View style={styles.card} accessibilityLiveRegion="polite">
      <View style={styles.header}>
        <Text style={styles.eyebrow}>New delivery request</Text>
        <Text style={[styles.countdown, secondsLeft <= 10 ? styles.urgent : null]}>{formatCountdown(secondsLeft)}</Text>
      </View>
      <Text style={styles.price}>{formatNaira(offer.price_kobo)}</Text>
      <Text style={styles.muted}>You keep the full fare. The customer pays you at delivery.</Text>
      <Text style={styles.body}>
        Pickup in {offer.area_name}, {distanceFromYou(offer.distance_to_pickup_m, offer.direction)}
      </Text>
      {offer.trip_distance_m ? <Text style={styles.body}>Trip: {formatDistance(offer.trip_distance_m)}</Text> : null}
      <Text style={styles.muted}>You will see the exact addresses after you accept.</Text>
      {error ? <Text style={styles.error}>{error}</Text> : null}
      <View style={styles.actions}>
        <View style={styles.action}>
          <Button title="Decline" variant="secondary" onPress={onDecline} loading={busy === 'decline'} disabled={busy !== null} />
        </View>
        <View style={styles.action}>
          <Button title="Accept" onPress={onAccept} loading={busy === 'accept'} disabled={busy !== null || secondsLeft === 0} />
        </View>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  card: { backgroundColor: '#ecfdf5', borderWidth: 2, borderColor: colors.success, borderRadius: 12, padding: spacing.md, gap: spacing.sm },
  header: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  eyebrow: { fontSize: 13, fontWeight: '700', color: colors.success, textTransform: 'uppercase' },
  countdown: { fontSize: 22, fontWeight: '700', color: colors.text, fontVariant: ['tabular-nums'] },
  urgent: { color: colors.danger },
  price: { fontSize: 30, fontWeight: '700', color: colors.text },
  body: { fontSize: 16, color: colors.text },
  muted: { fontSize: 13, color: colors.muted },
  error: { fontSize: 14, color: colors.danger },
  actions: { flexDirection: 'row', gap: spacing.sm },
  action: { flex: 1 },
});
