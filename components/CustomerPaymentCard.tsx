import { useCallback, useEffect, useState } from 'react';
import { Alert, StyleSheet, Text, View } from 'react-native';

import { Button } from '@/components/Button';
import { DisputeForm } from '@/components/DisputeForm';
import { colors, spacing } from '@/constants/theme';
import { formatNaira } from '@/lib/commission';
import { customerPaymentView, disputeLine, formatClock, type DisputeSummary, type PaymentStatus } from '@/lib/delivery';
import {
  getDeliveryPin,
  getOrderDispute,
  getOrderReceipt,
  reportPaymentSent,
  type Receipt,
} from '@/lib/deliveryApi';
import type { OrderStatus } from '@/lib/orders';

type CustomerPaymentCardProps = {
  orderId: string;
  status: OrderStatus;
  paymentStatus: PaymentStatus;
  reportedPaidAt: string | null;
  priceKobo: number;
  paymentReference: string | null;
  onChanged: () => void;
};

/** Payment due, "I've paid", the delivery PIN, the receipt, and payment problems. */
export function CustomerPaymentCard(props: CustomerPaymentCardProps) {
  const { orderId, status, paymentStatus, reportedPaidAt, priceKobo, paymentReference, onChanged } = props;
  const view = customerPaymentView(status, paymentStatus, reportedPaidAt);
  const [pin, setPin] = useState<string | null>(null);
  const [receipt, setReceipt] = useState<Receipt | null>(null);
  const [dispute, setDispute] = useState<DisputeSummary | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (view === 'none') return;
    const d = await getOrderDispute(orderId);
    setDispute(d.error === null ? d.data : null);
    if (view === 'paid_handover') {
      const p = await getDeliveryPin(orderId);
      setPin(p.error === null ? p.data : null);
    }
    if (view === 'delivered') {
      const r = await getOrderReceipt(orderId);
      setReceipt(r.error === null ? r.data : null);
    }
  }, [orderId, view]);

  // Reload whenever the order moves on (the screen polls the order itself).
  useEffect(() => {
    load();
  }, [load, status, paymentStatus, reportedPaidAt]);

  if (view === 'none') return null;

  function askReportPaid() {
    Alert.alert(
      'Have you paid?',
      `Only tap this after your transfer of ${formatNaira(priceKobo)} has gone through. The rider still checks their own bank before handing over.`,
      [
        { text: 'Not yet', style: 'cancel' },
        {
          text: "I've paid",
          onPress: async () => {
            setBusy(true);
            setError(null);
            const result = await reportPaymentSent(orderId);
            setBusy(false);
            if (result.error !== null) setError(result.error);
            onChanged();
          },
        },
      ],
    );
  }

  const line = disputeLine(dispute, 'customer');

  return (
    <View style={styles.card}>
      {view === 'pay_now' || view === 'reported' ? (
        <>
          <Text style={styles.eyebrow}>Payment due</Text>
          <Text style={styles.amount}>{formatNaira(priceKobo)}</Text>
          <Text style={styles.body}>
            Transfer this amount to the rider's account shown above.
            {paymentReference ? (
              <>
                {' '}Write <Text style={styles.strong}>{paymentReference}</Text> in the transfer note.
              </>
            ) : null}
          </Text>
          {view === 'pay_now' ? (
            <Button title="I've paid" onPress={askReportPaid} loading={busy} />
          ) : (
            <Text style={styles.body}>
              You said you paid at {formatClock(reportedPaidAt!)}. Waiting for the rider to confirm it in their bank app.
            </Text>
          )}
          <Text style={styles.muted}>The rider hands over the package only after they see your payment.</Text>
        </>
      ) : null}

      {view === 'paid_handover' ? (
        <>
          <Text style={styles.eyebrow}>Payment confirmed</Text>
          <Text style={styles.body}>Delivery PIN</Text>
          <Text style={styles.pin} selectable>
            {pin ?? '····'}
          </Text>
          <Text style={styles.muted}>
            Give this PIN to the receiver. The rider needs it to hand over the package. Never share it before your payment
            is confirmed.
          </Text>
        </>
      ) : null}

      {view === 'delivered' ? (
        <>
          <Text style={styles.eyebrow}>Receipt</Text>
          <Text style={styles.amount}>{formatNaira(priceKobo)}</Text>
          {receipt ? (
            <>
              <Text style={styles.body}>
                Paid to {receipt.account_name ?? receipt.rider_name}
                {receipt.bank_name ? ` · ${receipt.bank_name} ${receipt.account_masked ?? ''}` : ''}
              </Text>
              <Text style={styles.body}>
                Rider {receipt.rider_name} · {receipt.plate_number}
              </Text>
              {receipt.payment_confirmed_at ? (
                <Text style={styles.muted}>
                  Payment confirmed at {formatClock(receipt.payment_confirmed_at)}
                  {receipt.payment_confirmed_by === 'admin' ? ' by Dispatch' : ' by the rider'}
                </Text>
              ) : null}
              <Text style={styles.muted}>Reference {receipt.payment_reference}</Text>
            </>
          ) : null}
        </>
      ) : null}

      {view === 'refused' ? (
        <>
          <Text style={styles.eyebrow}>Not delivered</Text>
          <Text style={styles.body}>
            {paymentStatus === 'paid'
              ? 'Dispatch confirmed your payment after the rider marked the order unpaid.'
              : 'The rider marked this order unpaid and kept the package. If you did pay, report a payment problem.'}
          </Text>
        </>
      ) : null}

      {line ? <Text style={styles.body}>{line}</Text> : null}
      {error ? <Text style={styles.error}>{error}</Text> : null}
      {dispute?.can_raise ? (
        <DisputeForm
          orderId={orderId}
          role="customer"
          onDone={() => {
            load();
            onChanged();
          }}
        />
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  card: { backgroundColor: colors.surface, borderRadius: 12, padding: spacing.md, gap: spacing.sm },
  eyebrow: { fontSize: 13, fontWeight: '700', color: colors.muted, textTransform: 'uppercase' },
  amount: { fontSize: 26, fontWeight: '700', color: colors.text },
  pin: { fontSize: 40, fontWeight: '700', letterSpacing: 8, color: colors.text },
  body: { fontSize: 15, color: colors.text },
  strong: { fontWeight: '700' },
  muted: { fontSize: 13, color: colors.muted },
  error: { fontSize: 14, color: colors.danger },
});
