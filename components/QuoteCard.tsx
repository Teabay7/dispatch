import { StyleSheet, Text, View } from 'react-native';

import { PaymentNotice } from '@/components/PaymentNotice';
import { colors, spacing } from '@/constants/theme';
import { formatNaira } from '@/lib/commission';
import { formatDistance } from '@/lib/orders';
import type { Quote } from '@/lib/ordersApi';

type QuoteCardProps = {
  quote: Quote;
  minutesLeft: number;
};

export function QuoteCard({ quote, minutesLeft }: QuoteCardProps) {
  return (
    <View style={styles.card}>
      <Text style={styles.eyebrow}>Delivery price</Text>
      <Text style={styles.price}>{formatNaira(quote.priceKobo)}</Text>
      <Text style={styles.body}>
        {formatDistance(quote.distanceM)}
        {quote.pricedWithFallback ? ' (estimated: we could not get the road distance, so this is based on a straight line)' : ' by road'}
      </Text>
      <View style={styles.route}>
        <Text style={styles.label}>From</Text>
        <Text style={styles.address}>{quote.pickupAddress}</Text>
        <Text style={styles.label}>To</Text>
        <Text style={styles.address}>{quote.dropoffAddress}</Text>
      </View>
      <PaymentNotice />
      <Text style={styles.muted}>
        {minutesLeft > 0 ? `This price is held for ${minutesLeft} more minute${minutesLeft === 1 ? '' : 's'}.` : 'This price has expired.'}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  card: { backgroundColor: colors.surface, borderRadius: 12, padding: spacing.md, gap: spacing.sm },
  eyebrow: { fontSize: 13, fontWeight: '700', color: colors.muted, textTransform: 'uppercase' },
  price: { fontSize: 30, fontWeight: '700', color: colors.text },
  body: { fontSize: 15, color: colors.text },
  route: { gap: 2 },
  label: { fontSize: 12, fontWeight: '700', color: colors.muted, textTransform: 'uppercase', marginTop: spacing.xs },
  address: { fontSize: 15, color: colors.text },
  muted: { fontSize: 13, color: colors.muted },
});
