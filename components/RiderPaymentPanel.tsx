import { useCallback, useEffect, useState } from 'react';
import { Alert, StyleSheet, Text, View } from 'react-native';

import { Button } from '@/components/Button';
import { DisputeForm } from '@/components/DisputeForm';
import { TextField } from '@/components/TextField';
import { colors, spacing } from '@/constants/theme';
import { formatNaira } from '@/lib/commission';
import {
  formatClock,
  formatWait,
  normalizePin,
  pinError,
  pinResultMessage,
  riderDeliveryStep,
  secondsUntil,
  type PaymentStatus,
} from '@/lib/delivery';
import {
  completeDelivery,
  confirmPaymentReceived,
  getJobPaymentInfo,
  markArrivedAtDropoff,
  markPaymentRefused,
  type JobPaymentInfo,
} from '@/lib/deliveryApi';
import type { OrderStatus } from '@/lib/orders';

type RiderPaymentPanelProps = {
  orderId: string;
  status: OrderStatus;
  paymentStatus: PaymentStatus;
  reportedPaidAt: string | null;
  priceKobo: number;
  paymentReference: string | null;
  onChanged: () => void;
};

/** After pickup: arrive at the drop-off, confirm payment (or mark unpaid), hand over with the PIN. */
export function RiderPaymentPanel(props: RiderPaymentPanelProps) {
  const { orderId, status, paymentStatus, reportedPaidAt, priceKobo, paymentReference, onChanged } = props;
  const step = riderDeliveryStep(status, paymentStatus);
  const [info, setInfo] = useState<JobPaymentInfo | null>(null);
  const [now, setNow] = useState(Date.now());
  const [pin, setPin] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const loadInfo = useCallback(async () => {
    if (step === 'ended' || step === 'to_dropoff') return;
    const r = await getJobPaymentInfo(orderId);
    if (r.error === null) setInfo(r.data);
  }, [orderId, step]);

  useEffect(() => {
    loadInfo();
  }, [loadInfo, reportedPaidAt]);

  // The refusal countdown ticks every second while payment is due.
  useEffect(() => {
    if (step !== 'awaiting_payment') return;
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [step]);

  if (step === 'ended') return null;

  async function run(kind: string, action: () => Promise<{ error: string | null }>) {
    setBusy(kind);
    setError(null);
    const result = await action();
    setBusy(null);
    if (result.error !== null) setError(result.error);
    onChanged();
    loadInfo();
  }

  function askConfirmPaid() {
    Alert.alert(
      'Is the money in your account?',
      `Check your own bank app or bank SMS for ${formatNaira(priceKobo)}. Never trust a screenshot or a forwarded alert.`,
      [
        { text: 'Not yet', style: 'cancel' },
        { text: "Yes, I've received it", onPress: () => run('confirm', () => confirmPaymentReceived(orderId)) },
      ],
    );
  }

  function askRefuse() {
    Alert.alert(
      'Mark this order unpaid?',
      'Keep the package and take it back to the pickup point. The customer is told the order was not delivered.',
      [
        { text: 'Keep waiting', style: 'cancel' },
        { text: 'Mark unpaid', style: 'destructive', onPress: () => run('refuse', () => markPaymentRefused(orderId)) },
      ],
    );
  }

  async function handOver() {
    const problem = pinError(pin);
    if (problem) {
      setError(problem);
      return;
    }
    setBusy('pin');
    setError(null);
    const result = await completeDelivery(orderId, pin);
    setBusy(null);
    if (result.error !== null) {
      setError(result.error);
    } else {
      setError(pinResultMessage(result.data.result, result.data.attempts_left));
      setPin('');
    }
    onChanged();
    loadInfo();
  }

  const waitLeft = secondsUntil(info?.refuse_available_at ?? null, now);

  return (
    <View style={styles.card}>
      {step === 'to_dropoff' ? (
        <>
          <Text style={styles.eyebrow}>Next</Text>
          <Text style={styles.body}>Take the package to the drop-off. Mark arrival when you are there.</Text>
          <Button
            title="I've arrived at the drop-off"
            onPress={() => run('arrive', () => markArrivedAtDropoff(orderId))}
            loading={busy === 'arrive'}
          />
        </>
      ) : null}

      {step === 'awaiting_payment' ? (
        <>
          <Text style={styles.eyebrow}>Waiting for payment</Text>
          <Text style={styles.amount}>{formatNaira(priceKobo)}</Text>
          <Text style={styles.body}>
            The customer pays this into your bank account
            {paymentReference ? (
              <>
                , with <Text style={styles.strong}>{paymentReference}</Text> in the note
              </>
            ) : null}
            . Keep the package until you see the money.
          </Text>
          <Text style={styles.warning}>Check your own bank app or bank SMS. Never trust a screenshot.</Text>
          {reportedPaidAt ? (
            <Text style={styles.body}>The customer says they paid at {formatClock(reportedPaidAt)}.</Text>
          ) : null}
          <Button title="I've received the payment" onPress={askConfirmPaid} loading={busy === 'confirm'} />
          {reportedPaidAt ? (
            <Text style={styles.muted}>
              If the money hasn't arrived, report a payment problem. Dispatch will decide; you can't mark it unpaid now.
            </Text>
          ) : (
            <Button
              title={waitLeft && waitLeft > 0 ? `Customer didn't pay (in ${formatWait(waitLeft)})` : "Customer didn't pay"}
              variant="secondary"
              onPress={askRefuse}
              disabled={waitLeft === null || waitLeft > 0}
              loading={busy === 'refuse'}
            />
          )}
        </>
      ) : null}

      {step === 'handover' ? (
        <>
          <Text style={styles.eyebrow}>Payment confirmed</Text>
          {info?.pin_locked ? (
            <Text style={styles.warning}>Too many wrong PINs. Handover is locked: contact Dispatch support.</Text>
          ) : (
            <>
              <Text style={styles.body}>Ask the receiver for the 4-digit delivery PIN, then hand over the package.</Text>
              <TextField
                label="Delivery PIN"
                value={pin}
                onChangeText={(t) => setPin(normalizePin(t))}
                keyboardType="number-pad"
                maxLength={4}
              />
              <Button title="Hand over and mark delivered" onPress={handOver} loading={busy === 'pin'} />
            </>
          )}
        </>
      ) : null}

      {error ? <Text style={styles.error}>{error}</Text> : null}
      {info?.open_dispute_raised_as ? (
        <Text style={styles.body}>
          {info.open_dispute_raised_as === 'rider' ? 'You' : 'The customer'} reported a payment problem. Dispatch will
          contact you.
        </Text>
      ) : null}
      {step === 'awaiting_payment' && info?.can_raise_dispute ? (
        <DisputeForm
          orderId={orderId}
          role="rider"
          onDone={() => {
            loadInfo();
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
  body: { fontSize: 15, color: colors.text },
  strong: { fontWeight: '700' },
  warning: { fontSize: 15, fontWeight: '600', color: colors.danger },
  muted: { fontSize: 13, color: colors.muted },
  error: { fontSize: 14, color: colors.danger },
});
